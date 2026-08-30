use slatedb::object_store::aws::AmazonS3Builder;
use slatedb::object_store::local::LocalFileSystem;
use slatedb::object_store::path::Path;
use slatedb::object_store::ObjectStore;
use slatedb::{Db, IsolationLevel};
use std::env;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

const VALUE_BYTES: usize = 1024;
const MAXIMUM_OPERATIONS: usize = 10_000;

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
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("flyology-db-slatedb-benchmark: {error}");
        std::process::exit(2);
    }
}

async fn run() -> Result<(), String> {
    let arguments = arguments()?;
    let total = arguments
        .warmup
        .checked_add(arguments.measured)
        .ok_or("operation count overflow")?;
    if total == 0 || total > MAXIMUM_OPERATIONS {
        return Err("operation count exceeds benchmark fixture limit".to_owned());
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

    let db = Db::open(arguments.database_path.clone(), Arc::clone(&store))
        .await
        .map_err(|error| format!("cannot create database: {error}"))?;
    for index in 1..=arguments.warmup {
        put_one(&db, index).await?;
    }
    let started = Instant::now();
    for index in arguments.warmup + 1..=total {
        put_one(&db, index).await?;
    }
    let elapsed = started.elapsed().as_nanos();
    db.close()
        .await
        .map_err(|error| format!("cannot close database: {error}"))?;

    let reopened = Db::open(arguments.database_path, store)
        .await
        .map_err(|error| format!("cannot reopen database: {error}"))?;
    for index in 1..=total {
        let actual = reopened
            .get(key_for(index))
            .await
            .map_err(|error| format!("cannot read key {index}: {error}"))?
            .ok_or_else(|| format!("key {index} is missing after reopen"))?;
        if actual.as_ref() != value_for(index) {
            return Err(format!("value {index} differs after reopen"));
        }
    }
    reopened
        .close()
        .await
        .map_err(|error| format!("cannot close reopened database: {error}"))?;

    println!("elapsed_nanoseconds={elapsed}");
    println!("verified_keys={total}");
    Ok(())
}

async fn put_one(db: &Db, index: usize) -> Result<(), String> {
    let transaction = db
        .begin(IsolationLevel::Snapshot)
        .await
        .map_err(|error| format!("cannot begin transaction {index}: {error}"))?;
    transaction
        .put(key_for(index), value_for(index))
        .map_err(|error| format!("cannot put transaction {index}: {error}"))?;
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

fn key_for(index: usize) -> [u8; 16] {
    let mut key = [0_u8; 16];
    key[8..].copy_from_slice(&(index as u64).to_be_bytes());
    key
}

fn value_for(index: usize) -> [u8; VALUE_BYTES] {
    let mut value = [0_u8; VALUE_BYTES];
    for (position, byte) in value.iter_mut().enumerate() {
        *byte = ((index + (position + 1) * 31) % 256) as u8;
    }
    value
}

fn arguments() -> Result<Arguments, String> {
    let values: Vec<String> = env::args().skip(1).collect();
    match values.first().map(String::as_str) {
        Some("local") if values.len() == 5 => Ok(Arguments {
            storage: Storage::Local {
                root: PathBuf::from(&values[1]),
            },
            database_path: Path::parse(&values[2]).map_err(|_| "invalid database path")?,
            warmup: nonnegative(&values[3], "warmup operations")?,
            measured: positive(&values[4], "measured operations")?,
        }),
        Some("s3") if values.len() == 8 => Ok(Arguments {
            storage: Storage::S3 {
                endpoint: values[1].clone(),
                bucket: values[2].clone(),
                access_key: values[3].clone(),
                secret_key: values[4].clone(),
            },
            database_path: Path::parse(&values[5]).map_err(|_| "invalid database path")?,
            warmup: nonnegative(&values[6], "warmup operations")?,
            measured: positive(&values[7], "measured operations")?,
        }),
        _ => Err(
            "usage: benchmark local ROOT DATABASE_PATH WARMUP MEASURED\n       benchmark s3 ENDPOINT BUCKET ACCESS SECRET DATABASE_PATH WARMUP MEASURED"
                .to_owned(),
        ),
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
