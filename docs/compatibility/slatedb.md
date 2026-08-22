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
| Complete local-cache loss | Unqualified; the current executable proves process-loss recovery, not cache deletion |
| Outcome receipt/reconciliation | Unsupported; write handles are process-local |
| Writer fencing | Comparable but not normative multi-writer semantics |
| Logical compaction transparency | Supported; internal failpoints remain non-normative |

SlateDB commit success alone is submission/visibility, not durable success. A remote lane must await durability and
must not enable WAL disabling. An interrupted submitted mutation is conservatively `Outcome_Unknown`; no persistent
receipt can resolve it. Canonical state includes live tuples only because public scans hide tombstones.

## Executable adapter

`oracles/adapters/slatedb` is a Rust NDJSON process compiled directly against the ignored clean checkout at the exact
Git revision. Its first request is an adapter-specific, request-ID-bearing capability/provenance preflight. It retains
transaction handles, rejects every family configuration except one family named `default` before effects, validates
declared and concrete bounds before engine calls, requires canonical receipts before commit admission, and maps only
SlateDB's stable public error kinds. Admitted `Data` failures remain receipt-bound `Outcome_Unknown`; pre-admission
`Data` is `Corrupt`. One phase-tagged process-session registry bounds successful and unknown receipt identities;
reuse or its independent 4,096-entry hard-cap exhaustion applies pre-admission backpressure. Successful identities
survive an in-process reopen and permit clean shutdown. Unknown transaction identities additionally block reopen and
clean shutdown because SlateDB cannot resolve them persistently; neither identity is reconstructible after process
loss, so raw callers need a durable authority while validated crash traces prohibit replay. State digests scan
bounded live keys in byte order and hash the shared `oracles/contract/canonical-state.md` encoding and golden vectors.
The outer workload runner uses
`SIGKILL` for crash points; a direct crash command aborts without running destructors.

The checked default build uses a filesystem-synchronized local object store and advertises only `snapshot`,
`serializable`, and `crash_recovery`. It never calls that profile remote durable. The runner derives
`remote_durable` from every normative remote commit not explicitly expected to be `Unsupported`, even when a malformed
capability declaration omitted it, causing preflight to return `Unsupported` before database creation. A later real
remote provider profile requires its own credentials-safe configuration and executable campaign rather than a
documentation-only capability change.

The separate `slatedb-benchmark` workload source was audited at
`9cc10da634789f26cf3a0db2106b4b8fe8c802b0`. Its workload shapes inform performance dimensions, but its OS-seeded
generators are not the deterministic cross-engine authority.
