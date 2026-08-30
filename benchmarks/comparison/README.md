# Cross-engine benchmark panel

This directory defines the benchmark contract for the public Flyology.DB
comparison panel. It is benchmark-only. No adapter, source checkout, server,
or benchmark dependency becomes part of the production crate.

The panel has two independent lanes:

1. `local_durable` compares Flyology.DB Files, SlateDB with filesystem sync,
   and TidesDB with unified WAL plus full sync.
2. `remote_durable_rustfs` compares database operations whose successful
   result includes the participant's documented remote-durability barrier on
   the exact pinned RustFS server.

The lanes are not pooled or ranked together. TidesDB is explicitly
unsupported in the remote lane because the pinned implementation can ignore
object-store WAL upload failures. SlateDB is eligible only when the benchmark
awaits its durable write handle and keeps WAL enabled. Flyology.DB uses the
indexed `flyology_object_storage=0.1.0-dev` release. The benchmark materializes
that release from Alire, pins the fetched source only inside the benchmark
crate, and records its exact source and Alire-index commits for every campaign.
The production crate's dependency pin is unchanged.

`panel.json` is the machine-readable participant and lane manifest.
`workload.json` fixes the cross-engine operation semantics without turning its
fixture geometry into product policy. `result.schema.json` is the retained
result shape. `validate_result.py` binds results to all three files and rejects
unsupported or incomplete lanes, mixed durability, mismatched power metadata,
missing provenance, malformed samples, divergent state checksums, and
summaries that do not match their retained samples.

The executable campaign sources live beside the contract:

- `flyology_db_benchmark.gpr` and `src/flyology_db_benchmark.adb` drive the
  Files and authenticated S3 paths through the public Flyology.DB API;
- `slatedb/` drives the same transaction shape directly through the pinned
  SlateDB API and waits on every returned durable write handle;
- `tidesdb_benchmark.py` calls the pinned checked TidesDB shim directly, using
  the same full-sync configuration as the comparative oracle; and
- `run_local_campaign.py` and `run_rustfs_campaign.py` retain complete lane
  artifacts and invoke the maintained power-profile detector immediately
  before each participant's samples.

The common workload uses one writer, one mutation per transaction, 16-byte
sequential unique keys, and 1,024-byte values. The timed operation is
begin, put, and durable commit. Database creation, close, reopen, full key
verification, and SHA-256 state calculation remain outside the timed region.
Every repetition starts from a fresh database. Warmup and measured operation
counts are campaign inputs, but the retained key count must equal their sum.
The current harness limits their sum to 63 because manifest-v1 admits 64
batch-history entries; this fixture limit is not a library default.
The state checksum is SHA-256 over each key followed immediately by its value,
in ascending key order. Keys are the operation number as one unsigned 16-byte
big-endian value. Value byte `p`, for one-based position `p`, is
`(operation + 31 * p) mod 256`. The fixed extents make the stream unambiguous.

No result belongs on the website until:

- every participant passes its correctness preflight;
- the power-profile detector reports a comparable profile immediately before
  each participant measurement and the artifact retains that participant's
  exact detector result;
- all participants in one comparison use the same host, power source,
  workload identity, seed, operation geometry, and repetition count;
- raw samples, errors, checksums, source identities, build flags, and storage
  configuration are retained; and
- `validate_result.py` accepts the complete campaign artifact.

A laptop campaign is directional. It is not a portable performance claim or
a production qualification. A formal baseline additionally requires the
isolated-host protocol in the repository performance rules.

## Maintained commands

Build the participant executables before measurement:

```sh
mkdir -p benchmarks/comparison/.deps
(staging=$(mktemp -d) && cd "$staging" && \
  alr get -o flyology_object_storage=0.1.0-dev && \
  mv flyology_object_storage_0.1.0_5eaf79cf \
    "$OLDPWD/benchmarks/comparison/.deps/")
(cd benchmarks/comparison && alr build)
cargo build --manifest-path benchmarks/comparison/slatedb/Cargo.toml \
  --release --locked
./oracles/adapters/tidesdb/scripts/build.sh
```

Run the local lane with explicit geometry:

```sh
python3 benchmarks/comparison/run_local_campaign.py \
  --output benchmarks/comparison/results/local-durable.json \
  --warmup 5 --measured 30 --repetitions 5
python3 benchmarks/comparison/validate_result.py \
  benchmarks/comparison/results/local-durable.json
```

Run the remote lane through the exact pinned RustFS harness:

```sh
FLYOLOGY_DB_BENCHMARK_OUTPUT="$PWD/benchmarks/comparison/results/remote-rustfs.json" \
FLYOLOGY_DB_BENCHMARK_WARMUP=5 \
FLYOLOGY_DB_BENCHMARK_MEASURED=30 \
FLYOLOGY_DB_BENCHMARK_REPETITIONS=5 \
FLYOLOGY_S3_SERVER_RUNNER="$PWD/benchmarks/comparison/run_rustfs_campaign.py" \
  ./.deps/flyology-object-storage/tests/scripts/test-rustfs.sh
python3 benchmarks/comparison/validate_result.py \
  benchmarks/comparison/results/remote-rustfs.json
```

The runners reject a detected reduced-performance profile. The explicit
`--allow-reduced-performance` local option or
`FLYOLOGY_DB_BENCHMARK_ALLOW_REDUCED=1` remote setting is reserved for a user-
approved directional campaign and records that profile in every result.
