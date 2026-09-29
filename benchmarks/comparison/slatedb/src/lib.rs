use sha2::{Digest, Sha256};
use slatedb::object_store::aws::AmazonS3Builder;
use slatedb::object_store::local::LocalFileSystem;
use slatedb::object_store::path::Path;
use slatedb::object_store::ObjectStore;
use slatedb::{Db, IsolationLevel, Settings};
use std::env;
use std::ffi::{c_char, CStr};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

const MAXIMUM_OPERATIONS: usize = 10_000;
const MAXIMUM_PIPELINE_DEPTH: usize = 63;
const MAXIMUM_KEY_BYTES: usize = 256;
const MAXIMUM_VALUE_BYTES: usize = 64 * 1024;
const MAXIMUM_MUTATIONS: usize = 256;

enum Storage {
    Local {
        root: PathBuf,
    },
    S3 {
        endpoint: String,
        bucket: String,
        access_key: String,
        secret_key: String,
    },
}

struct Arguments {
    storage: Storage,
    database_path: Path,
    warmup: usize,
    measured: usize,
    key_bytes: usize,
    value_bytes: usize,
    mutations: usize,
    flush_interval_ms: Option<u64>,
}

struct Report {
    elapsed_nanoseconds: u64,
    verified_keys: u64,
    state_sha256: [u8; 32],
    preparation: PreparationTiming,
}

#[derive(Default)]
struct PreparationTiming {
    enabled: bool,
    transactions: u64,
    mutations: u64,
    total_ns: u64,
    fixture_generation_ns: u64,
    begin_ns: u64,
    mutation_put_ns: u64,
}

fn record_span(target: &mut u64, started: Instant) -> Result<(), String> {
    let elapsed = u64::try_from(started.elapsed().as_nanos())
        .map_err(|_| "SlateDB preparation diagnostic duration overflow")?;
    *target = target
        .checked_add(elapsed)
        .ok_or("SlateDB preparation diagnostic sum overflow")?;
    Ok(())
}

#[repr(C)]
pub struct BenchmarkReport {
    pub elapsed_nanoseconds: u64,
    pub verified_keys: u64,
    pub state_sha256: [u8; 32],
}

// Separate versioned symbol: an older caller can never receive a larger record.
#[repr(C)]
pub struct PreparationDiagnosticReportV1 {
    pub transactions: u64,
    pub mutations: u64,
    pub total_ns: u64,
    pub fixture_generation_ns: u64,
    pub begin_ns: u64,
    pub mutation_put_ns: u64,
}

const _: [(); 48] = [(); std::mem::size_of::<PreparationDiagnosticReportV1>()];
const _: [(); 8] = [(); std::mem::align_of::<PreparationDiagnosticReportV1>()];
const _: [(); 0] = [(); std::mem::offset_of!(PreparationDiagnosticReportV1, transactions)];
const _: [(); 8] = [(); std::mem::offset_of!(PreparationDiagnosticReportV1, mutations)];
const _: [(); 16] = [(); std::mem::offset_of!(PreparationDiagnosticReportV1, total_ns)];
const _: [(); 24] = [(); std::mem::offset_of!(PreparationDiagnosticReportV1, fixture_generation_ns)];
const _: [(); 32] = [(); std::mem::offset_of!(PreparationDiagnosticReportV1, begin_ns)];
const _: [(); 40] = [(); std::mem::offset_of!(PreparationDiagnosticReportV1, mutation_put_ns)];

static RUNTIME: OnceLock<Result<tokio::runtime::Runtime, String>> = OnceLock::new();

fn runtime() -> Result<&'static tokio::runtime::Runtime, String> {
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .map_err(|error| format!("cannot create Tokio runtime: {error}"))
        })
        .as_ref()
        .map_err(Clone::clone)
}

async fn run(arguments: Arguments) -> Result<Report, String> {
    let total = arguments
        .warmup
        .checked_add(arguments.measured)
        .ok_or("operation count overflow")?;
    if total == 0 || total > MAXIMUM_OPERATIONS {
        return Err("operation count exceeds benchmark fixture limit".to_owned());
    }
    if !(8..=MAXIMUM_KEY_BYTES).contains(&arguments.key_bytes)
        || arguments.value_bytes > MAXIMUM_VALUE_BYTES
        || !(1..=MAXIMUM_MUTATIONS).contains(&arguments.mutations)
    {
        return Err("workload geometry exceeds benchmark fixture limits".to_owned());
    }

    let store: Arc<dyn ObjectStore> = match &arguments.storage {
        Storage::Local { root } => {
            std::fs::create_dir(root)
                .map_err(|error| format!("cannot create local store root: {error}"))?;
            Arc::new(
                LocalFileSystem::new_with_prefix(root)
                    .map_err(|error| format!("cannot open local store: {error}"))?
                    .with_fsync(true),
            )
        }
        Storage::S3 {
            endpoint,
            bucket,
            access_key,
            secret_key,
        } => Arc::new(
            AmazonS3Builder::new()
                .with_allow_http(true)
                .with_endpoint(endpoint)
                .with_access_key_id(access_key)
                .with_secret_access_key(secret_key)
                .with_bucket_name(bucket)
                .with_region("us-east-1")
                .with_virtual_hosted_style_request(false)
                .build()
                .map_err(|error| format!("cannot build S3 store: {error}"))?,
        ),
    };

    let settings = settings(arguments.flush_interval_ms);
    let db = Db::builder(arguments.database_path.clone(), Arc::clone(&store))
        .with_settings(settings.clone())
        .build()
        .await
        .map_err(|error| format!("cannot create database: {error}"))?;
    let pipeline_depth = requested_pipeline_depth()?;
    let preparation_width = requested_preparation_width()?;
    let collect_preparation = requested_preparation_diagnostics()?;
    if preparation_width > pipeline_depth {
        return Err("SlateDB preparation width must fit the pipeline depth".to_owned());
    }
    if collect_preparation && preparation_width != 1 {
        return Err("SlateDB preparation diagnostics require width one".to_owned());
    }
    let mut warmup_preparation = PreparationTiming::default();
    if arguments.warmup > 0 {
        put_transactions_pipelined(
            &db,
            1,
            arguments.warmup,
            pipeline_depth,
            preparation_width,
            &arguments,
            &mut warmup_preparation,
        )
        .await?;
    }
    let mut preparation = PreparationTiming {
        enabled: collect_preparation,
        ..PreparationTiming::default()
    };
    let started = Instant::now();
    put_transactions_pipelined(
        &db,
        arguments.warmup + 1,
        arguments.measured,
        pipeline_depth,
        preparation_width,
        &arguments,
        &mut preparation,
    )
    .await?;
    let elapsed_nanoseconds = u64::try_from(started.elapsed().as_nanos())
        .map_err(|_| "elapsed time exceeds the report representation")?;
    if preparation.enabled {
        let attributed = preparation
            .fixture_generation_ns
            .checked_add(preparation.begin_ns)
            .and_then(|value| value.checked_add(preparation.mutation_put_ns))
            .ok_or("SlateDB preparation diagnostic sum overflow")?;
        if preparation.transactions != arguments.measured as u64
            || preparation.mutations != (arguments.measured * arguments.mutations) as u64
            || attributed > preparation.total_ns
            || preparation.total_ns > elapsed_nanoseconds
        {
            return Err("SlateDB preparation diagnostic geometry is inconsistent".to_owned());
        }
    }
    db.close()
        .await
        .map_err(|error| format!("cannot close database: {error}"))?;

    let reopened = Db::builder(arguments.database_path, store)
        .with_settings(settings)
        .build()
        .await
        .map_err(|error| format!("cannot reopen database: {error}"))?;
    let mut state = Sha256::new();
    let total_keys = total
        .checked_mul(arguments.mutations)
        .ok_or("verified-key count overflow")?;
    for index in 1..=total_keys {
        let key = key_for(index, arguments.key_bytes);
        let actual = reopened
            .get(&key)
            .await
            .map_err(|error| format!("cannot read key {index}: {error}"))?
            .ok_or_else(|| format!("key {index} is missing after reopen"))?;
        if actual.as_ref() != value_for(index, arguments.value_bytes) {
            return Err(format!("value {index} differs after reopen"));
        }
        state.update(&key);
        state.update(actual.as_ref());
    }
    reopened
        .close()
        .await
        .map_err(|error| format!("cannot close reopened database: {error}"))?;

    Ok(Report {
        elapsed_nanoseconds,
        verified_keys: u64::try_from(total_keys)
            .map_err(|_| "verified-key count exceeds the report representation")?,
        state_sha256: state.finalize().into(),
        preparation,
    })
}

// website-benchmark:start slatedb-durable-transaction
async fn put_transaction(
    db: &Db,
    index: usize,
    arguments: &Arguments,
    preparation: &mut PreparationTiming,
) -> Result<(), String> {
    let transaction = prepare_transaction(
        db,
        index,
        arguments.mutations,
        arguments.key_bytes,
        arguments.value_bytes,
        preparation,
    )
    .await?;
    let handle = transaction
        .commit()
        .await
        .map_err(|error| format!("cannot commit transaction {index}: {error}"))?
        .ok_or_else(|| format!("transaction {index} produced no durable write handle"))?;
    handle
        .await_durable()
        .await
        .map_err(|error| format!("transaction {index} did not become durable: {error}"))
}

async fn prepare_transaction(
    db: &Db,
    index: usize,
    mutations: usize,
    key_bytes: usize,
    value_bytes: usize,
    diagnostics: &mut PreparationTiming,
) -> Result<slatedb::DbTransaction, String> {
    let total_started = diagnostics.enabled.then(Instant::now);
    let begin_started = diagnostics.enabled.then(Instant::now);
    let transaction = db
        .begin(IsolationLevel::Snapshot)
        .await
        .map_err(|error| format!("cannot begin transaction {index}: {error}"))?;
    if let Some(started) = begin_started {
        record_span(&mut diagnostics.begin_ns, started)?;
    }
    for mutation in 1..=mutations {
        let key_index = (index - 1) * mutations + mutation;
        if diagnostics.enabled {
            let generated = Instant::now();
            let key = key_for(key_index, key_bytes);
            let value = value_for(key_index, value_bytes);
            record_span(&mut diagnostics.fixture_generation_ns, generated)?;
            let put_started = Instant::now();
            transaction
                .put(key, value)
                .map_err(|error| format!("cannot put transaction {index}: {error}"))?;
            // This call span includes any owned Vec teardown performed by SlateDB.
            record_span(&mut diagnostics.mutation_put_ns, put_started)?;
            diagnostics.mutations = diagnostics
                .mutations
                .checked_add(1)
                .ok_or("SlateDB diagnostic mutation count overflow")?;
        } else {
            transaction
                .put(
                    key_for(key_index, key_bytes),
                    value_for(key_index, value_bytes),
                )
                .map_err(|error| format!("cannot put transaction {index}: {error}"))?;
        }
    }
    if let Some(started) = total_started {
        record_span(&mut diagnostics.total_ns, started)?;
        diagnostics.transactions = diagnostics
            .transactions
            .checked_add(1)
            .ok_or("SlateDB diagnostic transaction count overflow")?;
    }
    Ok(transaction)
}
// website-benchmark:end slatedb-durable-transaction

async fn put_transactions_pipelined(
    db: &Db,
    first_index: usize,
    count: usize,
    pipeline_depth: usize,
    preparation_width: usize,
    arguments: &Arguments,
    diagnostics: &mut PreparationTiming,
) -> Result<(), String> {
    if pipeline_depth == 1 && preparation_width == 1 {
        for index in first_index..first_index + count {
            put_transaction(db, index, arguments, diagnostics).await?;
        }
        return Ok(());
    }

    let end = first_index
        .checked_add(count)
        .ok_or("pipeline transaction range overflow")?;
    let mut next = first_index;
    while next < end {
        let cohort_end = next.saturating_add(pipeline_depth).min(end);
        let mut handles = Vec::with_capacity(cohort_end - next);
        let mut submission_error = None;
        if preparation_width == 1 {
            for index in next..cohort_end {
                let transaction = prepare_transaction(
                    db,
                    index,
                    arguments.mutations,
                    arguments.key_bytes,
                    arguments.value_bytes,
                    diagnostics,
                )
                .await?;
                let submission = match transaction.commit().await {
                    Ok(Some(handle)) => Ok(handle),
                    Ok(None) => Err(format!(
                        "transaction {index} produced no durable write handle"
                    )),
                    Err(error) => Err(format!("cannot commit transaction {index}: {error}")),
                };
                match submission {
                    Ok(handle) => handles.push((index, handle)),
                    Err(error) => {
                        submission_error = Some(error);
                        break;
                    }
                }
            }
        } else {
            let mut prepared = Vec::with_capacity(cohort_end - next);
            let mut workers = Vec::with_capacity(preparation_width);
            let mut preparation_error = None;
            for worker in 0..preparation_width {
                let worker_db = db.clone();
                let mutations = arguments.mutations;
                let key_bytes = arguments.key_bytes;
                let value_bytes = arguments.value_bytes;
                workers.push(tokio::spawn(async move {
                    let mut worker_prepared = Vec::new();
                    let mut unused_diagnostics = PreparationTiming::default();
                    for index in (next + worker..cohort_end).step_by(preparation_width) {
                        worker_prepared.push((
                            index,
                            prepare_transaction(
                                &worker_db,
                                index,
                                mutations,
                                key_bytes,
                                value_bytes,
                                &mut unused_diagnostics,
                            )
                            .await?,
                        ));
                    }
                    Ok::<_, String>(worker_prepared)
                }));
            }
            for worker in workers {
                match worker.await {
                    Ok(Ok(worker_prepared)) => prepared.extend(worker_prepared),
                    Ok(Err(error)) => {
                        if preparation_error.is_none() {
                            preparation_error = Some(error);
                        }
                    }
                    Err(error) => {
                        if preparation_error.is_none() {
                            preparation_error =
                                Some(format!("SlateDB preparation worker failed: {error}"));
                        }
                    }
                }
            }
            if let Some(error) = preparation_error {
                return Err(error);
            }
            prepared.sort_unstable_by_key(|(index, _)| *index);
            for (index, transaction) in prepared {
                let submission = match transaction.commit().await {
                    Ok(Some(handle)) => Ok(handle),
                    Ok(None) => Err(format!(
                        "transaction {index} produced no durable write handle"
                    )),
                    Err(error) => Err(format!("cannot commit transaction {index}: {error}")),
                };
                match submission {
                    Ok(handle) => handles.push((index, handle)),
                    Err(error) => {
                        submission_error = Some(error);
                        break;
                    }
                }
            }
        }
        let mut durability_error = None;
        for (index, handle) in handles {
            if let Err(error) = handle.await_durable().await {
                if durability_error.is_none() {
                    durability_error = Some(format!(
                        "transaction {index} did not become durable: {error}"
                    ));
                }
            }
        }
        if let Some(error) = submission_error.or(durability_error) {
            return Err(error);
        }
        next = cohort_end;
    }
    Ok(())
}

fn key_for(index: usize, bytes: usize) -> Vec<u8> {
    let mut key = vec![0_u8; bytes];
    key[bytes - 8..].copy_from_slice(&(index as u64).to_be_bytes());
    key
}

fn value_for(index: usize, bytes: usize) -> Vec<u8> {
    let mut value = vec![0_u8; bytes];
    for (position, byte) in value.iter_mut().enumerate() {
        *byte = ((index + (position + 1) * 31) % 256) as u8;
    }
    value
}

fn settings(flush_interval_ms: Option<u64>) -> Settings {
    let mut settings = Settings::default();
    if let Some(milliseconds) = flush_interval_ms {
        settings.flush_interval = Some(Duration::from_millis(milliseconds));
    }
    settings
}

fn requested_pipeline_depth() -> Result<usize, String> {
    let value = env::var("FLYOLOGY_DB_SLATE_PIPELINE_DEPTH").unwrap_or_else(|_| "1".to_owned());
    let parsed = positive(&value, "SlateDB pipeline depth")?;
    if parsed <= MAXIMUM_PIPELINE_DEPTH {
        Ok(parsed)
    } else {
        Err("SlateDB pipeline depth exceeds the benchmark fixture limit".to_owned())
    }
}

fn requested_preparation_width() -> Result<usize, String> {
    let value = env::var("FLYOLOGY_DB_SLATE_PREPARATION_WIDTH").unwrap_or_else(|_| "1".to_owned());
    let parsed = positive(&value, "SlateDB preparation width")?;
    if parsed <= 8 {
        Ok(parsed)
    } else {
        Err("SlateDB preparation width must fit the eight-slot benchmark fixture".to_owned())
    }
}

fn requested_preparation_diagnostics() -> Result<bool, String> {
    match env::var("FLYOLOGY_DB_SLATE_PREPARATION_DIAGNOSTICS") {
        Ok(value) if value == "1" => Ok(true),
        Ok(value) if value == "0" => Ok(false),
        Err(env::VarError::NotPresent) => Ok(false),
        _ => Err("FLYOLOGY_DB_SLATE_PREPARATION_DIAGNOSTICS must be 0 or 1".to_owned()),
    }
}

fn arguments() -> Result<Arguments, String> {
    let values: Vec<String> = env::args().skip(1).collect();
    match values.first().map(String::as_str) {
        Some("local") if values.len() == 9 => Ok(Arguments {
            storage: Storage::Local {
                root: PathBuf::from(&values[1]),
            },
            database_path: Path::parse(&values[2]).map_err(|_| "invalid database path")?,
            warmup: nonnegative(&values[3], "warmup operations")?,
            measured: positive(&values[4], "measured operations")?,
            key_bytes: positive(&values[5], "key bytes")?,
            value_bytes: positive(&values[6], "value bytes")?,
            mutations: positive(&values[7], "mutations per transaction")?,
            flush_interval_ms: flush_interval(&values[8])?,
        }),
        Some("s3") if values.len() == 12 => Ok(Arguments {
            storage: Storage::S3 {
                endpoint: values[1].clone(),
                bucket: values[2].clone(),
                access_key: values[3].clone(),
                secret_key: values[4].clone(),
            },
            database_path: Path::parse(&values[5]).map_err(|_| "invalid database path")?,
            warmup: nonnegative(&values[6], "warmup operations")?,
            measured: positive(&values[7], "measured operations")?,
            key_bytes: positive(&values[8], "key bytes")?,
            value_bytes: positive(&values[9], "value bytes")?,
            mutations: positive(&values[10], "mutations per transaction")?,
            flush_interval_ms: flush_interval(&values[11])?,
        }),
        _ => Err(
            "usage: benchmark local ROOT DATABASE_PATH WARMUP MEASURED KEY_BYTES VALUE_BYTES MUTATIONS FLUSH_MS|default\n       benchmark s3 ENDPOINT BUCKET ACCESS SECRET DATABASE_PATH WARMUP MEASURED KEY_BYTES VALUE_BYTES MUTATIONS FLUSH_MS|default"
                .to_owned(),
        ),
    }
}

fn flush_interval(value: &str) -> Result<Option<u64>, String> {
    if value == "default" {
        Ok(None)
    } else {
        value
            .parse::<u64>()
            .map(Some)
            .map_err(|_| "flush interval must be default or a nonnegative integer".to_owned())
    }
}

fn positive(value: &str, name: &str) -> Result<usize, String> {
    let parsed = nonnegative(value, name)?;
    if parsed == 0 {
        Err(format!("{name} must be positive"))
    } else {
        Ok(parsed)
    }
}

fn nonnegative(value: &str, name: &str) -> Result<usize, String> {
    value
        .parse::<usize>()
        .map_err(|_| format!("{name} must be a nonnegative integer"))
}

pub fn run_cli() -> Result<(), String> {
    let report = runtime()?.block_on(run(arguments()?))?;
    println!("elapsed_nanoseconds={}", report.elapsed_nanoseconds);
    println!("verified_keys={}", report.verified_keys);
    let digest = report
        .state_sha256
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    println!("state_sha256={digest}");
    Ok(())
}

#[allow(unsafe_code)]
mod ffi {
    use super::*;

    fn required_string(value: *const c_char, name: &str) -> Result<String, String> {
        if value.is_null() {
            return Err(format!("{name} is null"));
        }
        // SAFETY: the caller contract requires a live NUL-terminated string for this call.
        let value = unsafe { CStr::from_ptr(value) };
        value
            .to_str()
            .map(str::to_owned)
            .map_err(|_| format!("{name} is not UTF-8"))
    }

    fn write_error(message: &str, output: *mut c_char, capacity: usize) {
        if output.is_null() || capacity == 0 {
            return;
        }
        let bytes = message.as_bytes();
        let length = bytes.len().min(capacity - 1);
        // SAFETY: the caller provides capacity writable bytes for the duration of this call.
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), output.cast::<u8>(), length);
            *output.add(length) = 0;
        }
    }

    fn execute(
        arguments: Result<Arguments, String>,
        output: *mut BenchmarkReport,
        diagnostic_output: Option<*mut PreparationDiagnosticReportV1>,
        error: *mut c_char,
        error_capacity: usize,
    ) -> i32 {
        let result = std::panic::catch_unwind(|| -> Result<Report, String> {
            if output.is_null() {
                return Err("report output is null".to_owned());
            }
            if diagnostic_output.is_some_and(|pointer| pointer.is_null()) {
                return Err("diagnostic report output is null".to_owned());
            }
            let report = runtime()?.block_on(run(arguments?))?;
            if diagnostic_output.is_some() && !report.preparation.enabled {
                return Err("SlateDB diagnostic report was not enabled".to_owned());
            }
            Ok(report)
        });
        match result {
            Ok(Ok(report)) => {
                // SAFETY: output was checked for null and the caller contract supplies one record.
                unsafe {
                    output.write(BenchmarkReport {
                        elapsed_nanoseconds: report.elapsed_nanoseconds,
                        verified_keys: report.verified_keys,
                        state_sha256: report.state_sha256,
                    });
                    if let Some(pointer) = diagnostic_output {
                        pointer.write(PreparationDiagnosticReportV1 {
                            transactions: report.preparation.transactions,
                            mutations: report.preparation.mutations,
                            total_ns: report.preparation.total_ns,
                            fixture_generation_ns: report.preparation.fixture_generation_ns,
                            begin_ns: report.preparation.begin_ns,
                            mutation_put_ns: report.preparation.mutation_put_ns,
                        });
                    }
                }
                0
            }
            Ok(Err(message)) => {
                write_error(&message, error, error_capacity);
                1
            }
            Err(_) => {
                write_error("SlateDB benchmark panicked", error, error_capacity);
                2
            }
        }
    }

    fn local_arguments(
        root: *const c_char,
        database_path: *const c_char,
        warmup: u64,
        measured: u64,
        key_bytes: u64,
        value_bytes: u64,
        mutations: u64,
        flush_interval_ms: u64,
        use_default_flush: u8,
    ) -> Result<Arguments, String> {
        Ok(Arguments {
            storage: Storage::Local {
                root: PathBuf::from(required_string(root, "root")?),
            },
            database_path: Path::parse(required_string(database_path, "database path")?)
                .map_err(|_| "invalid database path".to_owned())?,
            warmup: usize::try_from(warmup).map_err(|_| "warmup is too large")?,
            measured: usize::try_from(measured).map_err(|_| "measured is too large")?,
            key_bytes: usize::try_from(key_bytes).map_err(|_| "key size is too large")?,
            value_bytes: usize::try_from(value_bytes).map_err(|_| "value size is too large")?,
            mutations: usize::try_from(mutations).map_err(|_| "mutation count is too large")?,
            flush_interval_ms: (use_default_flush == 0).then_some(flush_interval_ms),
        })
    }

    #[no_mangle]
    pub extern "C" fn flyology_slatedb_benchmark_local(
        root: *const c_char,
        database_path: *const c_char,
        warmup: u64,
        measured: u64,
        key_bytes: u64,
        value_bytes: u64,
        mutations: u64,
        flush_interval_ms: u64,
        use_default_flush: u8,
        output: *mut BenchmarkReport,
        error: *mut c_char,
        error_capacity: usize,
    ) -> i32 {
        execute(
            local_arguments(
                root,
                database_path,
                warmup,
                measured,
                key_bytes,
                value_bytes,
                mutations,
                flush_interval_ms,
                use_default_flush,
            ),
            output,
            None,
            error,
            error_capacity,
        )
    }

    #[no_mangle]
    pub extern "C" fn flyology_slatedb_benchmark_local_diagnostics_v1(
        root: *const c_char,
        database_path: *const c_char,
        warmup: u64,
        measured: u64,
        key_bytes: u64,
        value_bytes: u64,
        mutations: u64,
        flush_interval_ms: u64,
        use_default_flush: u8,
        output: *mut BenchmarkReport,
        diagnostic_output: *mut PreparationDiagnosticReportV1,
        error: *mut c_char,
        error_capacity: usize,
    ) -> i32 {
        execute(
            local_arguments(
                root,
                database_path,
                warmup,
                measured,
                key_bytes,
                value_bytes,
                mutations,
                flush_interval_ms,
                use_default_flush,
            ),
            output,
            Some(diagnostic_output),
            error,
            error_capacity,
        )
    }

    #[no_mangle]
    pub extern "C" fn flyology_slatedb_benchmark_s3(
        endpoint: *const c_char,
        bucket: *const c_char,
        access_key: *const c_char,
        secret_key: *const c_char,
        database_path: *const c_char,
        warmup: u64,
        measured: u64,
        key_bytes: u64,
        value_bytes: u64,
        mutations: u64,
        flush_interval_ms: u64,
        use_default_flush: u8,
        output: *mut BenchmarkReport,
        error: *mut c_char,
        error_capacity: usize,
    ) -> i32 {
        execute(
            (|| {
                Ok(Arguments {
                    storage: Storage::S3 {
                        endpoint: required_string(endpoint, "endpoint")?,
                        bucket: required_string(bucket, "bucket")?,
                        access_key: required_string(access_key, "access key")?,
                        secret_key: required_string(secret_key, "secret key")?,
                    },
                    database_path: Path::parse(required_string(database_path, "database path")?)
                        .map_err(|_| "invalid database path".to_owned())?,
                    warmup: usize::try_from(warmup).map_err(|_| "warmup is too large")?,
                    measured: usize::try_from(measured).map_err(|_| "measured is too large")?,
                    key_bytes: usize::try_from(key_bytes).map_err(|_| "key size is too large")?,
                    value_bytes: usize::try_from(value_bytes)
                        .map_err(|_| "value size is too large")?,
                    mutations: usize::try_from(mutations)
                        .map_err(|_| "mutation count is too large")?,
                    flush_interval_ms: (use_default_flush == 0).then_some(flush_interval_ms),
                })
            })(),
            output,
            None,
            error,
            error_capacity,
        )
    }
}
