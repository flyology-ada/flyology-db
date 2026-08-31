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

Provision a disposable AWS Nitro host, run the deterministic suite and local
realistic matrix, download all evidence, and terminate the host:

```sh
benchmarks/comparison/run-aws-nitro-campaign.sh yrashk-inferal i4i.xlarge
```

The AWS profile and instance type are mandatory. The wrapper defaults to
`us-west-2`, accepts `--region` and `--output`, uses native Ubuntu 24.04
x86-64 or ARM64 images, and requires a Nitro instance with exactly one local
NVMe instance-store device. For example, `i4i.xlarge` and `i4g.xlarge` provide
matching 4-vCPU, 32-GiB, single-937-GB-instance-store shapes on x86-64 and
ARM64 respectively.
Dirty tracked bytes are authenticated automatically. Each intentional
untracked source path must be named with a separate `--include-untracked`;
unexpected untracked work fails closed and result directories are never sent.
It permits SSH only from the caller's current public IPv4 address. Alire,
GNAT, GPRbuild, Rust, GCC, the exact indexed Object Storage source and Alire
index, source, and dependencies are pinned or recorded in the downloaded
evidence. Workload scratch data is routed to the admitted local NVMe device.
The wrapper reports failure if evidence download or resource cleanup fails.
The EC2 instance, key pair, and security group are removed unless
`--keep-instance` is explicit; if termination fails, access resources are
retained and identified for manual recovery.

Rerun a new authenticated source snapshot on a retained host without
reprovisioning the instance or reformatting its local NVMe disk:

```sh
benchmarks/comparison/run-aws-nitro-campaign.sh rerun \
  yrashk-inferal \
  benchmarks/comparison/results/aws-nitro-20260831T035005Z \
  --include-untracked path/to/intentional-source
```

The original evidence directory, its caller identity and instance inventory,
and its mode-0600 PEM remain the host identity anchor. Current campaigns also
retain the AWS key-pair identity and an AWS-console-authenticated SSH host key.
For an older retained campaign, rerun resolves the unique live key by the
evidenced name and PEM fingerprint and obtains the host key from authenticated
EC2 console output. The AWS profile therefore needs `ec2:GetConsoleOutput` in
addition to the documented launch and inspection permissions. Rerun
reauthenticates the AWS account, instance, AMI, type, zone, public address,
key, complete security-group shape, and evidenced tags. It never changes
ingress, formats or mounts a disk, or mutates EC2 resources. Each invocation
uses a unique source/evidence/scratch root under the mounted instance-store
volume and takes a host-wide nonblocking campaign lock, so old evidence is not
overwritten and concurrent measurements fail closed. Use `--include-untracked`
once for each intentional untracked source path, just as for a new host.

After a retained campaign is no longer needed, tear down its EC2 host and
public IPv4 allocation using the authenticated `instance.json` in that
campaign's evidence directory:

```sh
benchmarks/comparison/run-aws-nitro-campaign.sh teardown \
  yrashk-inferal \
  benchmarks/comparison/results/aws-nitro-20260831T035005Z
```

Teardown requires the retained instance inventory, caller identity, and PEM;
current evidence also supplies the exact key-pair ID. It reauthenticates the
instance, key pair, security group, campaign tags, and public IPv4 address
before mutation. For legacy evidence it resolves the unique key by its
evidenced name and PEM fingerprint. Terminating the instance releases an
automatically assigned address; an evidenced Elastic IP is also released
explicitly. The AWS key pair and security group are deleted after termination.
Local evidence, including any retained PEM file, is preserved.

The runners reject a detected reduced-performance profile. The explicit
`--allow-reduced-performance` local option or
`FLYOLOGY_DB_BENCHMARK_ALLOW_REDUCED=1` remote setting is reserved for a user-
approved directional campaign and records that profile in every result.
An unclassifiable Linux profile is likewise recorded as exploratory evidence;
it does not establish a publishable comparison under the maintained power-
profile rule.
