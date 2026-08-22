# SlateDB adapter

Pin upstream to `e0161973d8d7ffdede7c44725729838811674e99`. The adapter is a Rust NDJSON process and accepts
only the `default` family. Unsupported column-family, savepoint, receipt, or outcome-resolution semantics are rejected
before effects rather than emulated. See `docs/compatibility/slatedb.md` for the audited matrix.
