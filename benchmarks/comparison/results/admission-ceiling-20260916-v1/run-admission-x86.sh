#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/admission-ceiling-20260916-v1-x86_64
source=$root/source
benchmark=$source/benchmarks/comparison
evidence=$root/evidence
expected_diff=9882967037fe38e83b08c0e151b829dfbb600e54ea9708a255ee2d7ad27127c2

test "$(id -u)" -eq 0
test "$(cat "$evidence/build-sentinel.txt")" = \
  'Flyology.DB isolated admission diagnostic x86 build passed'
test ! -e "$evidence/admission-v2"
test ! -e "$evidence/admission-analysis-v2.json"
test -z "$(find "$root/scratch" -mindepth 1 -print -quit)"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
sha256sum -c "$evidence/binaries.sha256" >"$evidence/pre-run-binaries-check.log"
if pgrep -x 'alr|gprbuild|gnat1|cargo|rustc' \
  >"$evidence/pre-run-process-conflicts.txt" \
  || pgrep -f '/bin/flyology_db_benchmark_panel' \
  >"$evidence/pre-run-process-conflicts.txt"
then
  printf '%s\n' 'benchmark or compiler process already active' >&2
  exit 1
fi
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9

export TMPDIR=$root/scratch
export FLYOLOGY_DB_BENCH_SCRATCH_ROOT=$root/scratch
export FLYOLOGY_BENCH_LOCK_PATH=/run/lock/flyology-bench-host-cpu.lock
export LD_LIBRARY_PATH="$benchmark/slatedb/target/release:\
$source/oracles/adapters/tidesdb/build:\
$source/oracles/adapters/tidesdb/build/upstream"
"$root/check-power-profile.sh" >"$evidence/power-before.env" || test "$?" -eq 2
python3 "$root/run-admission-x86.py" "$source" "$evidence/admission-v2" \
  >"$evidence/admission-v2.log" 2>&1
test -z "$(find "$root/scratch" -mindepth 1 -print -quit)"
"$root/check-power-profile.sh" >"$evidence/power-after.env" || test "$?" -eq 2
cmp "$evidence/power-before.env" "$evidence/power-after.env"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
sha256sum -c "$evidence/binaries.sha256" >"$evidence/post-run-binaries-check.log"
test "$(find "$evidence/admission-v2" -name '*.metrics.ndjson' -type f | wc -l)" -eq 1
metrics=$(find "$evidence/admission-v2" -name '*.metrics.ndjson' -type f)
python3 "$root/analyze-admission.py" "$metrics" >"$evidence/admission-analysis-v2.json"
printf '%s\n' 'Flyology.DB isolated admission diagnostic x86 run passed' \
  >"$evidence/run-sentinel.txt"
printf '%s\n' 'Flyology.DB isolated admission diagnostic x86 run passed'
