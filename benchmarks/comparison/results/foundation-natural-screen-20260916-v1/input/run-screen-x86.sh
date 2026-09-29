#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/foundation-natural-20260916-v1-x86_64
source=$root/source
benchmark=$source/benchmarks/comparison
evidence=$root/evidence
expected_diff=8c7e040fb3c56fb415f2acf8b7bd1063dbe692cea893ca497697bae02ff66c9c
expected_panel=01a211adb39213e6d6b20896e1f4c7579456bb33e02e6ee028539fb75115f8c6
expected_slate=acdfe30461b2c3b4f8704056682becadf4fd255dc08f1c80a4ae571e8afa1606

test "$(id -u)" -eq 0
(cd "$root/input" && sha256sum -c screen-inputs.sha256) \
  >"$evidence/screen-input-checks.log"
test "$(cat "$evidence/build-sentinel.txt")" = \
  'Flyology.DB foundation exact-source x86 build passed'
test ! -e "$evidence/screen"
test -z "$(find "$root/scratch" -mindepth 1 -print -quit)"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
test "$(sha256sum "$benchmark/bin/flyology_db_benchmark_panel" | cut -d ' ' -f 1)" = \
  "$expected_panel"
test "$(sha256sum "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  | cut -d ' ' -f 1)" = "$expected_slate"
if pgrep -x 'alr|gprbuild|gnat1|cargo|rustc' \
  >"$evidence/pre-screen-process-conflicts.txt" \
  || pgrep -f '/bin/flyology_db_benchmark_panel' \
  >"$evidence/pre-screen-process-conflicts.txt"
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
"$source/.agents/skills/performance-testing/scripts/check-power-profile.sh" \
  >"$evidence/power-before-screen.env" || test "$?" -eq 2
python3 "$root/input/foundation-screen-driver.py" "$source" x86_64 \
  "$evidence/screen" >"$evidence/screen.log" 2>&1
test -z "$(find "$root/scratch" -mindepth 1 -print -quit)"
"$source/.agents/skills/performance-testing/scripts/check-power-profile.sh" \
  >"$evidence/power-after-screen.env" || test "$?" -eq 2
cmp "$evidence/power-before-screen.env" "$evidence/power-after-screen.env"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
test "$(sha256sum "$benchmark/bin/flyology_db_benchmark_panel" | cut -d ' ' -f 1)" = \
  "$expected_panel"
test "$(sha256sum "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  | cut -d ' ' -f 1)" = "$expected_slate"
printf '%s\n' 'Flyology.DB exploratory foundation x86 screen passed' \
  >"$evidence/screen-sentinel.txt"
printf '%s\n' 'Flyology.DB exploratory foundation x86 screen passed'
