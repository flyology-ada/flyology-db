use flyology_db_slatedb_adapter::{parse_request, Adapter, AdapterLimits};
use serde_json::json;
use slatedb::object_store::local::LocalFileSystem;
use slatedb::object_store::path::Path;
use slatedb::object_store::ObjectStore;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;

const MAX_REQUEST_BYTES: usize = 32 * 1024 * 1024;

struct Arguments {
    root: PathBuf,
    database_path: Path,
    limits: AdapterLimits,
}

#[derive(Debug, PartialEq, Eq)]
enum Line {
    Eof,
    TooLong,
    Value(String),
}

#[tokio::main]
async fn main() {
    if let Err(message) = run().await {
        eprintln!("flyology-db-slatedb-adapter: {message}");
        std::process::exit(2);
    }
}

async fn run() -> Result<(), String> {
    let arguments = arguments()?;
    let store = LocalFileSystem::new_with_prefix(&arguments.root)
        .map_err(|_| "cannot open the local object-store root")?
        .with_fsync(true);
    let store: Arc<dyn ObjectStore> = Arc::new(store);
    let mut adapter = Adapter::new(store, arguments.database_path, arguments.limits);
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let stdout = io::stdout();
    let mut output = stdout.lock();

    loop {
        match next_line(&mut input, MAX_REQUEST_BYTES).map_err(|_| "cannot read stdin")? {
            Line::Eof => break,
            Line::TooLong => write_response(
                &mut output,
                &json!({
                    "request_id": "",
                    "outcome": "Unsupported",
                    "reason": "request_byte_limit"
                }),
            )?,
            Line::Value(line) => match parse_request(&line) {
                Ok(flyology_db_slatedb_adapter::Request::Crash { .. }) => crash_now(),
                Ok(request) => {
                    let response = adapter.execute(request).await;
                    write_response(&mut output, &response)?;
                }
                Err(response) => write_response(&mut output, &response)?,
            },
        }
    }
    adapter.shutdown().await
}

fn arguments() -> Result<Arguments, String> {
    let mut values = std::env::args().skip(1);
    let mut root = None;
    let mut database_path = None;
    let mut limits = AdapterLimits::default();
    while let Some(argument) = values.next() {
        let value = values
            .next()
            .ok_or_else(|| format!("missing value for {argument}"))?;
        match argument.as_str() {
            "--root" => root = Some(PathBuf::from(value)),
            "--database-path" => {
                database_path = Some(Path::parse(value).map_err(|_| "invalid database path")?)
            }
            "--max-transactions" => limits.transactions = positive(&value, &argument)?,
            "--max-receipt-ids" => limits.receipt_ids = positive(&value, &argument)?,
            "--max-mutations-per-transaction" => {
                limits.mutations_per_transaction = positive(&value, &argument)?
            }
            "--max-key-bytes" => limits.key_bytes = nonnegative(&value, &argument)?,
            "--max-value-bytes" => limits.value_bytes = nonnegative(&value, &argument)?,
            "--max-scan-items" => limits.scan_items = positive(&value, &argument)?,
            "--max-scan-bytes" => limits.scan_bytes = positive(&value, &argument)?,
            "--max-state-items" => limits.state_items = positive(&value, &argument)?,
            "--max-state-bytes" => limits.state_bytes = positive(&value, &argument)?,
            _ => return Err(format!("unknown argument {argument}")),
        }
    }
    Ok(Arguments {
        root: root.ok_or("--root is required")?,
        database_path: database_path.ok_or("--database-path is required")?,
        limits,
    })
}

fn positive(value: &str, argument: &str) -> Result<usize, String> {
    let value = nonnegative(value, argument)?;
    if value == 0 {
        Err(format!("{argument} must be positive"))
    } else {
        Ok(value)
    }
}

fn nonnegative(value: &str, argument: &str) -> Result<usize, String> {
    value
        .parse::<usize>()
        .map_err(|_| format!("invalid value for {argument}"))
}

fn write_response(output: &mut impl Write, value: &serde_json::Value) -> Result<(), String> {
    serde_json::to_writer(&mut *output, value).map_err(|_| "cannot serialize response")?;
    output
        .write_all(b"\n")
        .and_then(|()| output.flush())
        .map_err(|_| "cannot write stdout".to_owned())
}

fn next_line(input: &mut impl BufRead, maximum: usize) -> io::Result<Line> {
    let mut bytes = Vec::new();
    let mut too_long = false;
    loop {
        let available = input.fill_buf()?;
        if available.is_empty() {
            return if bytes.is_empty() && !too_long {
                Ok(Line::Eof)
            } else if too_long {
                Ok(Line::TooLong)
            } else {
                String::from_utf8(bytes)
                    .map(Line::Value)
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "request is not UTF-8"))
            };
        }
        let take = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |position| position + 1);
        if !too_long {
            let content = &available[..take];
            let content = content.strip_suffix(b"\n").unwrap_or(content);
            let content = content.strip_suffix(b"\r").unwrap_or(content);
            if bytes.len().saturating_add(content.len()) > maximum {
                too_long = true;
                bytes.clear();
            } else {
                bytes.extend_from_slice(content);
            }
        }
        let ended = available[take - 1] == b'\n';
        input.consume(take);
        if ended {
            return if too_long {
                Ok(Line::TooLong)
            } else {
                String::from_utf8(bytes)
                    .map(Line::Value)
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "request is not UTF-8"))
            };
        }
    }
}

fn crash_now() -> ! {
    // Abort is deliberately used instead of unwinding: no Rust destructors run, so SlateDB
    // cannot close or flush cleanly. The workload runner uses SIGKILL for normative crash
    // records; this command exists for direct protocol qualification.
    std::process::abort()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn line_reader_enforces_limit_and_resynchronizes() {
        let mut input = Cursor::new(b"12345\nok\n".to_vec());
        assert_eq!(next_line(&mut input, 4).unwrap(), Line::TooLong);
        assert_eq!(
            next_line(&mut input, 4).unwrap(),
            Line::Value("ok".to_owned())
        );
        assert_eq!(next_line(&mut input, 4).unwrap(), Line::Eof);
    }
}
