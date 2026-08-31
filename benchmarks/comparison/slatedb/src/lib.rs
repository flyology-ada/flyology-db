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
}

#[repr(C)]
pub struct BenchmarkReport {
    pub elapsed_nanoseconds: u64,
    pub verified_keys: u64,
    pub state_sha256: [u8; 32],
}

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
    for index in 1..=arguments.warmup {
        put_transaction(&db, index, &arguments).await?;
    }
    let started = Instant::now();
    for index in arguments.warmup + 1..=total {
        put_transaction(&db, index, &arguments).await?;
    }
    let elapsed_nanoseconds = u64::try_from(started.elapsed().as_nanos())
        .map_err(|_| "elapsed time exceeds the report representation")?;
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
    })
}

// website-benchmark:start slatedb-durable-transaction
async fn put_transaction(db: &Db, index: usize, arguments: &Arguments) -> Result<(), String> {
    let transaction = db
        .begin(IsolationLevel::Snapshot)
        .await
        .map_err(|error| format!("cannot begin transaction {index}: {error}"))?;
    for mutation in 1..=arguments.mutations {
        let key_index = (index - 1) * arguments.mutations + mutation;
        transaction
            .put(
                key_for(key_index, arguments.key_bytes),
                value_for(key_index, arguments.value_bytes),
            )
            .map_err(|error| format!("cannot put transaction {index}: {error}"))?;
    }
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
// website-benchmark:end slatedb-durable-transaction

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
        error: *mut c_char,
        error_capacity: usize,
    ) -> i32 {
        let result = std::panic::catch_unwind(|| -> Result<Report, String> {
            if output.is_null() {
                return Err("report output is null".to_owned());
            }
            runtime()?.block_on(run(arguments?))
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
            (|| {
                Ok(Arguments {
                    storage: Storage::Local {
                        root: PathBuf::from(required_string(root, "root")?),
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
            error,
            error_capacity,
        )
    }
}
