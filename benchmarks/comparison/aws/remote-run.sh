#!/usr/bin/env bash
set -euo pipefail

campaign_mode=${AWS_CAMPAIGN_MODE:-launch}
case "$campaign_mode" in
  launch)
    input_root=/tmp
    work_root=/mnt/flyology-bench
    artifact_path=/tmp/flyology-db-aws-artifacts.tar.gz
    log_root=/tmp/flyology-db-aws-logs
    ;;
  rerun)
    campaign_run_id=${AWS_CAMPAIGN_RUN_ID:-}
    case "$campaign_run_id" in
      '' | *[!a-zA-Z0-9._-]*)
        printf '%s\n' "invalid retained-host run ID: $campaign_run_id" >&2
        exit 1
        ;;
    esac
    input_root=${AWS_CAMPAIGN_INPUT_ROOT:-}
    [ "$input_root" = "/tmp/flyology-db-aws-runs/$campaign_run_id" ] || {
      printf '%s\n' "invalid retained-host input root: $input_root" >&2
      exit 1
    }
    work_root=/mnt/flyology-bench/runs/$campaign_run_id
    artifact_path=$input_root/artifacts.tar.gz
    log_root=$input_root/logs
    ;;
  *)
    printf '%s\n' "invalid AWS campaign mode: $campaign_mode" >&2
    exit 1
    ;;
esac
evidence_root=$work_root/evidence
repository=$work_root/flyology-db
scratch_root=$work_root/tmp
mkdir -p "$log_root"
log_pipe=$log_root/campaign.pipe
mkfifo "$log_pipe"
exec 3>&1 4>&2
tee "$log_root/campaign.log" < "$log_pipe" >&3 &
tee_pid=$!
exec > "$log_pipe" 2>&1

finish()
{
  status=$?
  trap - EXIT
  set +e
  if [ -d "$evidence_root" ]; then
    if ! cp -a "$evidence_root" "$log_root/evidence" &&
      [ "$status" -eq 0 ]; then
      status=1
    fi
  fi
  exec 1>&3 2>&4
  if ! wait "$tee_pid" && [ "$status" -eq 0 ]; then
    status=1
  fi
  rm -f -- "$log_pipe"
  printf '%s\n' "$status" > "$log_root/exit-status"
  if ! tar -C "$log_root" -czf "$artifact_path" .; then
    status=1
  fi
  exit "$status"
}
trap finish EXIT

fail()
{
  printf '%s\n' "$*" >&2
  exit 1
}

require_file()
{
  [ -f "$1" ] || fail "required input is missing: $1"
}

clone_exact()
{
  local origin=$1
  local commit=$2
  local target=$3

  [ ! -e "$target" ] || fail "dependency target already exists: $target"
  git clone --no-checkout -- "$origin" "$target"
  git -C "$target" checkout --detach "$commit"
  [ "$(git -C "$target" remote get-url origin)" = "$origin" ] ||
    fail "dependency origin mismatch: $target"
  [ "$(git -C "$target" rev-parse HEAD)" = "$commit" ] ||
    fail "dependency commit mismatch: $target"
  [ -z "$(git -C "$target" status --porcelain --untracked-files=all)" ] ||
    fail "dependency is dirty: $target"
}

require_dependency_exact()
{
  local target=$1
  local origin=$2
  local commit=$3

  [ "$(git -C "$target" remote get-url origin)" = "$origin" ] ||
    fail "dependency origin drift: $target"
  [ "$(git -C "$target" rev-parse HEAD)" = "$commit" ] ||
    fail "dependency commit drift: $target"
  [ -z "$(git -C "$target" status --porcelain --untracked-files=all)" ] ||
    fail "dependency source drift: $target"
}

require_file "$input_root/flyology-db.bundle"
require_file "$input_root/flyology-db.patch"
require_file "$input_root/flyology-db-untracked.tar.gz"
require_file "$input_root/flyology-db-untracked.json"
require_file "$input_root/flyology-db-source.env"
require_file "$input_root/check-power-profile.sh"

# shellcheck disable=SC1091
. "$input_root/flyology-db-source.env"
observed_remote_runner=$(sha256sum "$input_root/remote-run.sh" | cut -d ' ' -f 1)
[ "$observed_remote_runner" = "$SOURCE_REMOTE_RUNNER_SHA256" ] ||
  fail "remote runner does not match the authenticated source snapshot"
observed_untracked_manifest=$(
  sha256sum "$input_root/flyology-db-untracked.json" | cut -d ' ' -f 1
)
[ "$observed_untracked_manifest" = "$SOURCE_UNTRACKED_MANIFEST_SHA256" ] ||
  fail "untracked source manifest mismatch"

export PATH=/root/.cargo/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin
if [ "$campaign_mode" = launch ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential ca-certificates cmake curl git jq libssl-dev nvme-cli \
    pkg-config python3 python3-venv unzip util-linux xz-utils

  # The instance is disposable. Format only the single unmounted EC2 instance-
  # store disk; never select the EBS boot volume.
  mapfile -t instance_disks < <(
    lsblk -J -d -o PATH,TYPE,MODEL,MOUNTPOINT |
      jq -r '.blockdevices[] | select(
        .type == "disk" and
        .model == "Amazon EC2 NVMe Instance Storage" and
        .mountpoint == null
      ) | .path'
  )
  [ "${#instance_disks[@]}" -eq 1 ] ||
    fail "expected exactly one unmounted EC2 NVMe instance-store disk"
  benchmark_disk=${instance_disks[0]}
  [ "$(lsblk -dn -o TYPE "$benchmark_disk")" = disk ] ||
    fail "instance-store candidate is not a whole disk"
  [ "$(lsblk -nr -o PATH "$benchmark_disk" | wc -l | tr -d '[:space:]')" -eq 1 ] ||
    fail "instance-store candidate has child partitions"
  [ -z "$(lsblk -nr -o MOUNTPOINTS "$benchmark_disk" | tr -d '[:space:]')" ] ||
    fail "instance-store candidate or child is mounted"
  [ -z "$(findmnt -rn -S "$benchmark_disk")" ] ||
    fail "instance-store candidate is present in the mount table"
  [ -z "$(swapon --show=NAME --noheadings | grep -Fx "$benchmark_disk" || true)" ] ||
    fail "instance-store candidate is active swap"
  [ -z "$(find "/sys/class/block/${benchmark_disk##*/}/holders" \
    -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    fail "instance-store candidate has kernel holders"
  [ -z "$(wipefs -n "$benchmark_disk")" ] ||
    fail "instance-store candidate contains an existing signature"
  mkfs.ext4 -F -L flyology-bench "$benchmark_disk"
  mkdir -p /mnt/flyology-bench
  mount -o noatime "$benchmark_disk" /mnt/flyology-bench

  alire_url=https://github.com/alire-project/alire/releases/download/v2.1.1/\
alr-2.1.1-bin-x86_64-linux.zip
  alire_sha=09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7
  curl -fsSL "$alire_url" -o /tmp/alire.zip
  printf '%s  %s\n' "$alire_sha" /tmp/alire.zip | sha256sum -c -
  unzip -q /tmp/alire.zip -d /tmp/alire
  install -m 0755 /tmp/alire/bin/alr /usr/local/bin/alr

  rustup_url=https://static.rust-lang.org/rustup/archive/1.28.2/\
x86_64-unknown-linux-gnu/rustup-init
  rustup_sha=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
  curl --proto '=https' --tlsv1.2 -fsSL "$rustup_url" -o /tmp/rustup-init
  printf '%s  %s\n' "$rustup_sha" /tmp/rustup-init | sha256sum -c -
  chmod 0755 /tmp/rustup-init
  /tmp/rustup-init -y --profile minimal --default-toolchain 1.91.1
else
  for command in alr cargo cmake curl findmnt flock gcc git jq lsblk python3 rustc tar; do
    command -v "$command" >/dev/null 2>&1 || fail "retained host is missing command: $command"
  done
  mountpoint -q /mnt/flyology-bench || fail 'retained benchmark volume is not mounted'
  benchmark_disk=$(findmnt -rn -o SOURCE --target /mnt/flyology-bench)
  [ "$(lsblk -dn -o TYPE "$benchmark_disk")" = disk ] ||
    fail 'retained benchmark volume is not backed by a whole disk'
  [ "$(lsblk -dn -o MODEL "$benchmark_disk" | sed 's/[[:space:]]*$//')" = \
    'Amazon EC2 NVMe Instance Storage' ] ||
    fail 'retained benchmark volume is not backed by EC2 instance storage'
  exec 9>/run/lock/flyology-db-aws-campaign.lock
  flock -n 9 || fail 'another Flyology.DB AWS campaign owns the retained host'
  [ ! -e "$work_root" ] || fail "retained-host run root already exists: $work_root"
fi
[ ! -e "$repository" ] || fail "campaign repository already exists: $repository"
mkdir -p "$evidence_root" "$scratch_root"
[ "$(alr --version)" = "alr 2.1.1" ] || fail "unexpected Alire version"
rustc --version | grep -F 'rustc 1.91.1 '
gcc --version | sed -n '1p'

git clone "$input_root/flyology-db.bundle" "$repository"
git -C "$repository" apply --binary "$input_root/flyology-db.patch"

observed_untracked=$(
  sha256sum "$input_root/flyology-db-untracked.tar.gz" | cut -d ' ' -f 1
)
[ "$observed_untracked" = "$SOURCE_UNTRACKED_SHA256" ] ||
  fail "untracked source archive mismatch"
observed_power_detector=$(sha256sum "$input_root/check-power-profile.sh" | cut -d ' ' -f 1)
[ "$observed_power_detector" = "$SOURCE_POWER_PROFILE_SHA256" ] ||
  fail "power-profile detector mismatch"
tar -C "$repository" -xzf "$input_root/flyology-db-untracked.tar.gz"
power_detector=$repository/.agents/skills/performance-testing/scripts/check-power-profile.sh
mkdir -p "$(dirname -- "$power_detector")"
install -m 0755 "$input_root/check-power-profile.sh" "$power_detector"
[ "$(git -C "$repository" rev-parse HEAD)" = "$SOURCE_HEAD" ] ||
  fail "source HEAD mismatch"
observed_diff=$(
  git -C "$repository" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1
)
[ "$observed_diff" = "$SOURCE_DIFF_SHA256" ] || fail "source diff mismatch"

cd "$repository"
alr index --reset-community
alr index --add=git+https://github.com/flyology-ada/alire-index.git \
  --name=flyology --before=community
alr --non-interactive toolchain --select \
  gnat_native=16.1.0 gprbuild=26.0.1

mkdir -p .deps
clone_exact https://github.com/flyology-ada/flyology-object-storage.git \
  f65afbf28108bb9d81fac6dc15496857dc710796 .deps/flyology-object-storage
clone_exact https://github.com/slatedb/slatedb.git \
  e0161973d8d7ffdede7c44725729838811674e99 .deps/slatedb
clone_exact https://github.com/tidesdb/tidesdb.git \
  23a67a6531bc6c0b537d3696758c7879586dcfce .deps/tidesdb

{
  printf 'source_head=%s\n' "$SOURCE_HEAD"
  printf 'source_diff_sha256=%s\n' "$SOURCE_DIFF_SHA256"
  printf 'instance_type=%s\n' "$AWS_INSTANCE_TYPE"
  printf 'region=%s\n' "$AWS_REGION"
  printf 'availability_zone=%s\n' "$AWS_AVAILABILITY_ZONE"
  printf 'ami_id=%s\n' "$AWS_AMI_ID"
  printf 'instance_id=%s\n' "$AWS_INSTANCE_ID"
  printf 'nvme_device=%s\n' "$benchmark_disk"
  printf 'alire=%s\n' "$(alr --version)"
  printf 'rust=%s\n' "$(rustc --version)"
  printf 'gcc=%s\n' "$(gcc --version | sed -n '1p')"
  printf 'kernel=%s\n' "$(uname -srvmo)"
  printf 'cpu=%s\n' "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
  printf 'object_storage_author_origin=%s\n' \
    "$(git -C .deps/flyology-object-storage remote get-url origin)"
  printf 'object_storage_author_commit=%s\n' \
    "$(git -C .deps/flyology-object-storage rev-parse HEAD)"
  printf 'slatedb_origin=%s\n' "$(git -C .deps/slatedb remote get-url origin)"
  printf 'slatedb_commit=%s\n' "$(git -C .deps/slatedb rev-parse HEAD)"
  printf 'tidesdb_origin=%s\n' "$(git -C .deps/tidesdb remote get-url origin)"
  printf 'tidesdb_commit=%s\n' "$(git -C .deps/tidesdb rev-parse HEAD)"
} > "$evidence_root/host.env"
cp "$input_root/flyology-db-source.env" "$evidence_root/source.env"
cp "$input_root/flyology-db-untracked.json" "$evidence_root/untracked-source.json"
sha256sum "$power_detector" > "$evidence_root/power-profile-detector.sha256"
lsblk -O -J > "$evidence_root/lsblk.json"
lscpu -J > "$evidence_root/lscpu.json"

./tests/scripts/test.sh
printf '%s\n' 'Flyology.DB AWS deterministic suite passed' |
  tee "$evidence_root/deterministic-sentinel.txt"

benchmark=$repository/benchmarks/comparison
mkdir -p "$benchmark/.deps"
benchmark_db="$benchmark/.deps/flyology_db-fca74780"
post_test_diff=$(
  git -C "$repository" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1
)
[ "$post_test_diff" = "$SOURCE_DIFF_SHA256" ] || fail "source diff changed during tests"
post_test_untracked=$(
  sha256sum "$input_root/flyology-db-untracked.tar.gz" | cut -d ' ' -f 1
)
[ "$post_test_untracked" = "$SOURCE_UNTRACKED_SHA256" ] ||
  fail "retained untracked source archive changed during tests"
python3 "$repository/benchmarks/comparison/aws/package-source.py" "$repository" \
  "$input_root/flyology-db-post-test-untracked.json" \
  "$input_root/flyology-db-post-test-untracked.tar.gz" \
  --allow-manifest "$input_root/flyology-db-untracked.json"
cmp -s "$input_root/flyology-db-untracked.json" \
  "$input_root/flyology-db-post-test-untracked.json" ||
  fail "untracked source changed during tests"
git clone "$input_root/flyology-db.bundle" "$benchmark_db"
git -C "$benchmark_db" apply --binary "$input_root/flyology-db.patch"
tar -C "$benchmark_db" -xzf "$input_root/flyology-db-untracked.tar.gz"
benchmark_power_detector=$benchmark_db/.agents/skills/performance-testing/scripts/check-power-profile.sh
mkdir -p "$(dirname -- "$benchmark_power_detector")"
install -m 0755 "$input_root/check-power-profile.sh" "$benchmark_power_detector"

# The benchmark owns one indexed Object Storage pin. Remove only the author-
# checkout pin from its isolated DB copy, matching the published crate shape.
expected_db_pin=$(printf '%s\n%s' '[[pins]]' \
  "flyology_object_storage = { path='.deps/flyology-object-storage' }")
[ "$(tail -n 2 "$benchmark_db/alire.toml")" = "$expected_db_pin" ] ||
  fail "unexpected Flyology.DB author-checkout pin"
sed -i '/^\[\[pins\]\]$/,$d' "$benchmark_db/alire.toml"
sed -i '${/^$/d;}' "$benchmark_db/alire.toml"

staging=$(mktemp -d)
(
  cd "$staging"
  alr get -o flyology_object_storage=0.1.0-dev
)
indexed_fos=$staging/flyology_object_storage_0.1.0_5eaf79cf
[ -d "$indexed_fos" ] || fail "indexed Object Storage snapshot was not materialized"
mv "$indexed_fos" "$benchmark/.deps/"

cargo build --manifest-path "$benchmark/slatedb/Cargo.toml" \
  --release --locked
./oracles/adapters/tidesdb/scripts/build.sh
(
  cd "$benchmark"
  alr build --release
)

export LD_LIBRARY_PATH="$benchmark/slatedb/target/release:\
$repository/oracles/adapters/tidesdb/build:\
$repository/oracles/adapters/tidesdb/build/upstream"
export FLYOLOGY_DB_BENCH_SCRATCH_ROOT=$scratch_root
campaign=$evidence_root/aws-nitro-local.json
python3 "$benchmark/run_realistic_campaign.py" --lane local --output "$campaign"
sha256sum "$campaign" > "$evidence_root/aws-nitro-local.sha256"
printf '%s\n' 'Flyology.DB AWS Nitro benchmark campaign passed' |
  tee "$evidence_root/benchmark-sentinel.txt"

[ "$(git -C "$repository" rev-parse HEAD)" = "$SOURCE_HEAD" ] ||
  fail "source HEAD changed during campaign"
final_diff=$(git -C "$repository" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)
[ "$final_diff" = "$SOURCE_DIFF_SHA256" ] || fail "source diff changed during campaign"
python3 "$repository/benchmarks/comparison/aws/package-source.py" "$repository" \
  "$input_root/flyology-db-final-untracked.json" \
  "$input_root/flyology-db-final-untracked.tar.gz" \
  --allow-manifest "$input_root/flyology-db-untracked.json"
cmp -s "$input_root/flyology-db-untracked.json" \
  "$input_root/flyology-db-final-untracked.json" ||
  fail "untracked source changed during campaign"
require_dependency_exact .deps/flyology-object-storage \
  https://github.com/flyology-ada/flyology-object-storage.git \
  f65afbf28108bb9d81fac6dc15496857dc710796
require_dependency_exact .deps/slatedb https://github.com/slatedb/slatedb.git \
  e0161973d8d7ffdede7c44725729838811674e99
require_dependency_exact .deps/tidesdb https://github.com/tidesdb/tidesdb.git \
  23a67a6531bc6c0b537d3696758c7879586dcfce
[ -z "$(find "$scratch_root" -mindepth 1 -print -quit)" ] ||
  fail "benchmark scratch residue remains"
