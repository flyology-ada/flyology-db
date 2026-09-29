#!/usr/bin/env bash
set -euo pipefail

architecture=$1
source_root=$2
experiment_root=$3
input_root=$experiment_root/input
evidence_root=$experiment_root/evidence
scratch_root=$experiment_root/scratch

case "$architecture" in
  x86_64 | arm64) ;;
  *) printf 'unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac
case "$source_root/" in
  /mnt/flyology-bench/experiments/pipelined-adaptive-natural-20260914-v5-*/source/) ;;
  *) printf 'unexpected source root: %s\n' "$source_root" >&2; exit 1 ;;
esac
case "$experiment_root/" in
  /mnt/flyology-bench/experiments/ready-queue-integrated-ceiling-20260914-v1-*/) ;;
  *) printf 'unexpected experiment root: %s\n' "$experiment_root" >&2; exit 1 ;;
esac

test -d "$source_root"
test -f "$input_root/long-wait-driver.py"
test ! -e "$evidence_root"
test ! -e "$scratch_root"
mkdir "$scratch_root"

exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9 || { printf '%s\n' 'another benchmark campaign owns this host' >&2; exit 1; }

source_evidence=${source_root%/source}/input
# shellcheck disable=SC1091
. "$source_evidence/source.env"
test "$(git -C "$source_root" rev-parse HEAD)" = "$SOURCE_HEAD"
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$SOURCE_DIFF_SHA256"
test "$(sha256sum "$source_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  "$ROOT_ALIRE_LOCK_SHA256"

benchmark=$source_root/benchmarks/comparison
panel=$benchmark/bin/flyology_db_benchmark_panel
test -x "$panel"
for marker in \
  FLYOLOGY_DB_BENCH_ADAPTIVE_PREPARATION_CONCURRENCY \
  FLYOLOGY_DB_BENCH_ADAPTIVE_PIPELINE_COHORTS \
  runtime_preparation_concurrency runtime_pipeline_depth \
  flyology.db.benchmark.state_verification.v1
do
  strings "$panel" | grep -F "$marker" >/dev/null
done

export LD_LIBRARY_PATH="$benchmark/slatedb/target/release:\
$source_root/oracles/adapters/tidesdb/build:\
$source_root/oracles/adapters/tidesdb/build/upstream"
export FLYOLOGY_DB_BENCH_SCRATCH_ROOT=$scratch_root
export FLYOLOGY_BENCH_LOCK_PATH=/run/lock/flyology-bench-host-cpu.lock
power_detector=$source_root/.agents/skills/performance-testing/scripts/check-power-profile.sh
"$power_detector" >"$experiment_root/power-before.env" || test "$?" -eq 2
python3 "$input_root/long-wait-driver.py" "$source_root" "$architecture" "$evidence_root"
test -z "$(find "$scratch_root" -mindepth 1 -print -quit)"
"$power_detector" >"$experiment_root/power-after.env" || test "$?" -eq 2

test "$(git -C "$source_root" rev-parse HEAD)" = "$SOURCE_HEAD"
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$SOURCE_DIFF_SHA256"
git -C "$source_root" status --short >"$experiment_root/source-status.txt"
(
  cd "$experiment_root"
  find . -type f ! -name sha256sums.txt -print0 | LC_ALL=C sort -z | \
    xargs -0 sha256sum >sha256sums.txt
)
printf '%s\n' 'Flyology.DB natural long-wait ceiling remote campaign passed'
