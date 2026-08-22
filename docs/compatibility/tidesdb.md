# TidesDB oracle capability report

TidesDB is a comparative logical/local-durability oracle, not the normative remote publication contract.

## Provenance

- Repository: `https://github.com/tidesdb/tidesdb.git`
- Commit: `23a67a6531bc6c0b537d3696758c7879586dcfce`
- Tag label: `v9.3.15`
- Commit subject: merge rejecting incomplete transaction batch applies
- Audited: 2026-08-22

The SHA is authoritative: `CMakeLists.txt` still reports 9.3.14 at the tagged commit. A dependency-minimal adapter
build disables Snappy, LZ4, Zstd, and S3 and uses `TDB_COMPRESS_NONE`.

Selected upstream tests passed for snapshot isolation, the upstream serializable phantom case, abrupt recovery, and
unified multi-column-family flush/recovery. The phantom test is not evidence of range-phantom prevention: it uses
read-committed transactions and permits either success or conflict.

## Required configuration

Cross-family crash atomicity and local durable success require unified memtable/WAL mode and full unified-WAL sync.
Per-family mode may recover a partial multi-family prefix, and `tidesdb_sync_wal` syncs only a per-family active WAL.
The adapter must override defaults, which otherwise select per-family buffering, no sync, and read committed.

## Capability boundary

| Contract area | Treatment |
| --- | --- |
| Binary CRUD, read-your-writes, rollback, savepoints | Supported |
| Cross-family transactions and local crash recovery | Supported only with unified mode plus full sync |
| Snapshot write/write conflicts | Supported comparatively |
| Serializable point conflicts/write skew | Comparable; map the single conflict code by requested isolation |
| Serializable scan phantoms | Unsupported; iterators record returned keys, not predicates/ranges |
| Stable persisted Flyology.DB family IDs | Unsupported through the public API |
| Remote durable commit | Unsupported; object-store WAL upload failures are ignored by commit at this pin |
| Receipt, idempotency resolution, head CAS, writer fencing | Unsupported/non-equivalent |
| Injected semantic clock and deterministic TTL | Unsupported |
| Deadlines and cancellation | Unsupported; busy is backpressure, not a timeout |
| Logical compaction/checkpoint/recovery | Supported locally under the qualified configuration |

A clean close flushes and waits and therefore is not a crash. Crash workloads kill or `_exit` the adapter and reopen
the same path in a new process. Canonical state contains live tuples only; public APIs do not enumerate tombstones.

## Adapter shape

The smallest adapter is a Python 3 standard-library NDJSON process using `ctypes` against a shared library built at
the exact pin. It rejects unavailable required capabilities before executing a trace, retains raw error codes, frees
point-get buffers with `tidesdb_free`, and treats iterator key/value pointers as borrowed until movement or free.
Startup fails closed if the expected SHA/tag/library identity does not match. The source is MPL-2.0 and redistributing
binaries requires retaining its and bundled dependencies' license provenance.
