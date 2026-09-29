#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/freeze-first-cohort-20260916-v1-x86_64
source=$root/source
benchmark=$source/benchmarks/comparison
evidence=$root/evidence
expected_diff=ef9171ee9b7869609c25039eb8c8c43e427c568cb92e9b05ca103e692879b132
expected_panel=e9df7c025824396d0a3e5653ade175a51539490781322a199c7bc5a9d33bf225
expected_slate=5bd568c6e6d2f50abe492d5a10c479aea54c0d5d06876d71a2f4b90ffca448ef

test "$(id -u)" -eq 0
(cd "$root/input" && sha256sum -c screen-inputs.sha256) \
  >"$evidence/screen-input-checks.log"
test "$(cat "$evidence/build-sentinel.txt")" = \
  'Flyology.DB raw-freeze exact-source x86 build passed'
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
python3 "$root/input/raw-freeze-screen-driver.py" "$source" x86_64 \
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
printf '%s\n' 'Flyology.DB exploratory raw-freeze x86 screen passed' \
  >"$evidence/screen-sentinel.txt"
printf '%s\n' 'Flyology.DB exploratory raw-freeze x86 screen passed'
