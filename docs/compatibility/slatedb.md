# SlateDB oracle capability report

SlateDB is a comparative oracle, not the normative contract.

## Provenance

- Repository: `https://github.com/slatedb/slatedb`
- Commit: `e0161973d8d7ffdede7c44725729838811674e99`
- Commit subject: `configure sst iterator read ahead using bytes (#2037)`
- Source description: `v0.15.0-38-ge016197`; the workspace version remains `0.15.0`
- Rust toolchain: 1.91.1
- Audited: 2026-08-22

The source SHA is authoritative. Verified upstream commands at this pin were:

```sh
cargo check --locked -p slatedb --no-default-features
cargo test --locked -p slatedb --no-default-features --lib db_transaction::tests
cargo test --locked -p slatedb --no-default-features --lib test_should_recover_imm_from_wal
```

The audit observed 43 passing transaction tests and two passing selected WAL recovery tests.

## Capability boundary

| Contract area | Treatment |
| --- | --- |
| Binary CRUD, missing keys, atomic batch, read-your-writes, rollback | Supported for one default keyspace |
| Snapshot and serializable-snapshot transactions | Supported comparatively; public errors do not identify conflict subtype |
| Point and range/phantom validation | Supported comparatively by serializable-snapshot tests |
| Column families and cross-family atomicity | Unsupported; accept only `default`, never prefix-emulate families |
| Ordered scans and in-process snapshots | Supported; snapshots are not reopenable application IDs |
| Savepoints | Unsupported |
| TTL and merge | Deferred until the shared injected clock/operator contract exists |
| Remote durability | Await the returned write handle or flush barrier against a real remote provider |
| Complete local-cache loss | Unqualified until an adapter-level delete-cache/reopen case passes |
| Outcome receipt/reconciliation | Unsupported; write handles are process-local |
| Writer fencing | Comparable but not normative multi-writer semantics |
| Logical compaction transparency | Supported; internal failpoints remain non-normative |

SlateDB commit success alone is submission/visibility, not durable success. A remote lane must await durability and
must not enable WAL disabling. An interrupted submitted mutation is conservatively `Outcome_Unknown`; no persistent
receipt can resolve it. Canonical state includes live tuples only because public scans hide tombstones.

## Adapter shape

The smallest adapter is a Rust NDJSON process pinned to the exact Git revision. It emits its capability/provenance
record at startup, retains transaction and snapshot handles, rejects non-default families before effects, validates
key/value bounds before calling APIs that may panic, and maps only stable public error kinds. State digests scan live
keys in byte order and hash the contract's length-prefixed encoding. The outer runner kills the process for crash
points.

The separate `slatedb-benchmark` workload source was audited at
`9cc10da634789f26cf3a0db2106b4b8fe8c802b0`. Its workload shapes inform performance dimensions, but its OS-seeded
generators are not the deterministic cross-engine authority.
