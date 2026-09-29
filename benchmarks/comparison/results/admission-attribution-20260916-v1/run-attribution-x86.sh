#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/admission-attribution-20260916-v1-x86_64
source=$root/source
benchmark=$source/benchmarks/comparison
evidence=$root/evidence
expected_diff=b4850b89330e9489d84e63c166410c6da9ffb2f515b0cda43dff0e794df902a3

test "$(id -u)" -eq 0
test -x "$benchmark/bin/flyology_db_benchmark_panel"
grep -F 'Success: Build finished successfully' "$evidence/ada-build.log" >/dev/null
grep -F 'flyology_db_benchmark_flyology.adb' "$evidence/ada-build.log" >/dev/null
grep -F "$source/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$evidence/gpr-source-map.txt" >/dev/null
if grep -F '/admission-ceiling-20260916-v1-x86_64/source/benchmarks/comparison/src/' \
  "$evidence/gpr-source-map.txt" >/dev/null
then
  printf '%s\n' 'GPR selected the preceding experiment source' >&2
  exit 1
fi
test ! -e "$evidence/attribution-v1"
test ! -e "$evidence/attribution-analysis-v1.json"
test -z "$(find "$root/scratch" -mindepth 1 -print -quit)"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
sha256sum "$benchmark/bin/flyology_db_benchmark_panel" \
  "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  >"$evidence/binaries.sha256"
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
python3 "$root/run-attribution-x86.py" "$source" "$evidence/attribution-v1" \
  >"$evidence/attribution-v1.log" 2>&1
test -z "$(find "$root/scratch" -mindepth 1 -print -quit)"
"$root/check-power-profile.sh" >"$evidence/power-after.env" || test "$?" -eq 2
cmp "$evidence/power-before.env" "$evidence/power-after.env"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
sha256sum -c "$evidence/binaries.sha256" >"$evidence/post-run-binaries-check.log"
test "$(find "$evidence/attribution-v1/diagnostic" -name '*.metrics.ndjson' -type f | wc -l)" -eq 1
test "$(find "$evidence/attribution-v1/control" -name '*.metrics.ndjson' -type f | wc -l)" -eq 1
metrics=$(find "$evidence/attribution-v1/diagnostic" -name '*.metrics.ndjson' -type f)
python3 "$root/analyze-attribution.py" "$metrics" \
  >"$evidence/attribution-analysis-v1.json"
printf '%s\n' 'Flyology.DB isolated preparation attribution x86 run passed' \
  >"$evidence/run-sentinel.txt"
printf '%s\n' 'Flyology.DB isolated preparation attribution x86 run passed'
