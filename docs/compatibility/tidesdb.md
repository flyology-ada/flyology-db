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
| Nonempty binary-key CRUD, arbitrary binary values, read-your-writes, rollback, savepoints | Supported |
| Empty keys | Unsupported by the pinned public transaction API; rejected before effects |
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

The executable adapter is a Python 3 standard-library NDJSON process using `ctypes` opaque pointers against a shared
library built at the exact pin. A narrow C configuration shim avoids mirroring the pin's by-value configuration
structure layout in Python. It selects unified/full-sync/no-compression settings but owns no transaction or outcome
policy.

The outer runner validates the normative workload before effects and rejects missing capabilities before starting
the adapter. Raw protocol tests qualify local cross-family commit/reopen and abrupt `_exit` recovery without
mislabeling either as remote durability. Serializable scans are rejected because the pin records only returned point
keys, not predicates. The adapter preserves raw engine codes. A commit error that is not provably pre-WAL is
conservatively mapped to `Outcome_Unknown`, because even an allocation failure can occur after a full-sync WAL write
but before memtable application. The adapter then fences further operations until close/reopen; it cannot resolve a
Flyology.DB receipt. `TDB_ERR_BUSY` remains conclusive engine backpressure rather than a fabricated timeout, but the
pin installs in-progress write reservations before returning it and rollback does not release them. The adapter
therefore consumes the native transaction, retains a logical rollback marker, and fences the session until close and
reopen so later comparisons cannot observe poisoned reservation state.

Point-get buffers are placed under cleanup immediately after native return and released with `tidesdb_free`, including
on oversized or malformed provider results. Column-family enumeration likewise frees every returned name and its
outer array before reporting count or provider-invariant failures. Iterator key/value pointers are copied before
movement and never freed by the adapter. State enumeration opens one fresh snapshot transaction, sorts live tuples
by numeric family ID and key bytes, and hashes the shared domain-separated length-prefixed encoding. Scans and state
enumeration enforce
both item and aggregate decoded-byte bounds; the outer runner preflights declared workload limits before effects.
Family IDs are canonical nonzero 32-bit decimal values and state ordering is numeric, including across digit-width
boundaries. Family names reject current/parent path components, ASCII separators, and the pin's case-insensitive root
collisions (`LOCK`, `LOG`, `UNIMAP`, `UNIMAP.tmp`, `uwal_*`, and the replica/fencing staging files) before the engine
can create a database. Database and checkpoint paths leave the pin's 32-byte root-suffix allowance plus a
conservative 41-byte family-relative allowance for the longest bounded partitioned SST name. Create reserves the
database directory atomically. Once native open is admitted, later open/create failures report `Corrupt`, never the
pre-admission `Unsupported`, because root metadata or a column-family directory may already exist.
The same conservative mapping applies to admitted close, flush, compaction, and checkpoint failures.

The raw adapter bounds each transaction to 64 live savepoints. Reusing a live name updates its existing position;
release removes only that name; rollback-to removes the target and every later savepoint exactly as the pinned engine
does. The mirror is updated only after native success, so mutation-capacity accounting follows the same rollback.
Ordinary startup always reconfigures and clean-rebuilds, and fails closed unless the dependency checkout is clean and
exactly pinned; it does not trust timestamps or retained shim/library identity claims. The source is MPL-2.0 and
redistributing binaries requires retaining its license plus the bundled xxHash and inih license notices.
