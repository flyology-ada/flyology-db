# TidesDB adapter

Pin upstream to `23a67a6531bc6c0b537d3696758c7879586dcfce`. The adapter is a Python standard-library NDJSON
process over opaque `ctypes` handles. A narrow C shim calls the pin's by-value configuration functions so Python
does not duplicate private structure layouts; the shim contains no transaction, retry, scheduling, or outcome policy.

Build and test:

```sh
oracles/adapters/tidesdb/scripts/build.sh
oracles/adapters/tidesdb/scripts/test.sh
```

Run the raw adapter:

```sh
oracles/adapters/tidesdb/scripts/run.sh
```

Every input command and output result is one JSON line with the same required `request_id`. Binary keys and values are
canonical base64 on this transport; the workload runner translates the normative contract's lowercase hexadecimal.
The initial commands cover capabilities, open/create-family verification, snapshot/serializable transactions, point
CRUD, bounded scans, savepoints, commit/rollback, flush, compaction, checkpoint, logical state, close, and abrupt
`_exit` crash. The crash command deliberately emits no response.

The pinned transaction API rejects zero-length keys. The raw adapter reports them as `Unsupported`, and the workload
runner rejects any empty-key trace during preflight before starting the adapter. Empty values remain supported.
Column-family IDs are canonical nonzero `u32` decimal strings. Names reject `.` and `..`, ASCII slash and backslash,
and every exact root-file or `uwal_*` collision in the pin before any engine call. Shared raw/workload path validation
also reserves space for root suffixes and the longest bounded partitioned SST path under every family and checkpoint.
Native open/create failures after admission are `Corrupt`, not the pre-effect `Unsupported`, because the engine may
already have created metadata. Raw transactions retain at most 64 savepoints and mirror the pin's rollback-to rule:
the named savepoint and every later savepoint are invalidated after native success.
Native point-get and family-list allocations enter cleanup immediately on return, including when provider bounds or
invariants are rejected.

Every ordinary adapter startup reconfigures and clean-rebuilds the shared library from a clean, exact
`.deps/tidesdb` pin rather than trusting timestamps or a retained binary. The build forces unified WAL/memtable mode, full
sync, bounded memory/cache/thread configuration, and no compression or S3. The adapter is never labeled remotely
durable, never supplies receipt resolution, and rejects serializable scan-phantom workloads before effects. A local
commit/reopen/crash result is comparative local-durability evidence only. See `docs/compatibility/tidesdb.md` for the
audited matrix.

Run a validated workload with:

```sh
oracles/adapters/tidesdb/run_workload.py WORKLOAD DATABASE_DIRECTORY
```

Capability preflight occurs before the adapter process starts, so a normative remote-durable workload cannot create
local state. Declared transaction, mutation, family, path-layout, key, value, scan, and result bounds are checked at
the same boundary. An explicitly expected `Unsupported` remote commit remains executable for capability-comparison
traces.

Pinned TidesDB can return `TDB_ERR_BUSY` only after installing an in-progress sequence and write reservations that
its rollback API does not release. The adapter therefore reports the commit as conclusive `Unsupported`, consumes
the native transaction, permits one logical rollback for contract cleanup, and fences the session until close and
reopen. It never treats engine backpressure as a timeout or as possible WAL publication.
