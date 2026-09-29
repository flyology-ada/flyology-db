#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/put-cpu-profile-20260916-v1-x86_64
prior=/mnt/flyology-bench/experiments/admission-attribution-20260916-v1-x86_64
source=$prior/source
benchmark=$source/benchmarks/comparison
panel=$benchmark/bin/flyology_db_benchmark_panel
evidence=$root/evidence
expected_diff=b4850b89330e9489d84e63c166410c6da9ffb2f515b0cda43dff0e794df902a3
expected_panel=c3541db1a5ed46836ad1d1b03502f2682460b7f99cf483a2b1fc80d3f695af65
expected_slate=11e19eb0a904bfd56f82f2010d45a3de79a6ba866680d1c03fa5eff63178409e
expected_state=090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb

test "$(id -u)" -eq 0
test -d "$root"
test ! -e "$evidence"
test ! -e "$root/scratch"
test -x "$panel"
test "$(git -C "$source" rev-parse HEAD)" = 613ad2b054725e99b73117f03ae38e213fdfaef7
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
test "$(sha256sum "$panel" | cut -d ' ' -f 1)" = "$expected_panel"
test "$(sha256sum "$benchmark/slatedb/target/release/\
libflyology_db_slatedb_benchmark.so" | cut -d ' ' -f 1)" = "$expected_slate"
test -f "$prior/evidence/run-sentinel.txt"
test "$(cat "$prior/evidence/run-sentinel.txt")" = \
  'Flyology.DB isolated preparation attribution x86 run passed'
test "$(perf --version)" = 'perf version 7.0.14'
nm -an "$panel" | grep -F 'flyology__db__store_mutation' >/dev/null
if pgrep -x 'alr|gprbuild|gnat1|cargo|rustc|perf' >/dev/null; then
  printf '%s\n' 'compiler process is active' >&2
  exit 1
fi
flock -n /run/lock/flyology-bench-host-cpu.lock true
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9

mkdir "$evidence" "$root/scratch"
export TMPDIR=$root/scratch
export FLYOLOGY_DB_BENCH_SCRATCH_ROOT=$root/scratch
export FLYOLOGY_DB_BENCH_NAMESPACE=put-cpu-profile-20260916-v1-x86_64
export FLYOLOGY_DB_BENCH_WARMUP=8
export FLYOLOGY_DB_BENCH_COMMIT_DIAGNOSTICS=0
export FLYOLOGY_BENCH_LOCK_PATH=/run/lock/flyology-bench-host-cpu.lock
export LD_LIBRARY_PATH="$benchmark/slatedb/target/release:\
$source/oracles/adapters/tidesdb/build:\
$source/oracles/adapters/tidesdb/build/upstream"
"$prior/check-power-profile.sh" >"$evidence/power-before.env" || test "$?" -eq 2
printf '%s\n' "$expected_panel" >"$evidence/panel-sha256.txt"
printf '%s\n' "$expected_diff" >"$evidence/source-diff-sha256.txt"
python3 "$root/run-owned.py" "$evidence/panel.stdout" "$evidence/perf.stderr" \
  "$evidence/record-argv.json" perf record --clockid mono \
  -e cpu-clock/period=250000/u --call-graph dwarf,8192 \
  -o "$evidence/perf.data" -- "$panel" \
  slatedb-1ms-depth32 \
  flyology-db-files-adaptive-cohort-members8-bytes2159008-wait-us1000-depth32-workers1-cohorts1 \
  16 1024 256 35 "$evidence/pair.json" "$evidence/metrics.ndjson"
test -s "$evidence/perf.data"
test -s "$evidence/metrics.ndjson"
python3 - "$evidence/perf.stderr" <<'PY'
import re
import sys
lines = open(sys.argv[1]).read().splitlines()
allowed = (
    r"\[ perf record: Woken up [0-9]+ times to write data \]",
    r"\[ perf record: Captured and wrote [0-9]+\.[0-9]+ MB .+ \([0-9]+ samples\) \]",
)
assert lines and all(any(re.fullmatch(pattern, line) for pattern in allowed)
                     for line in lines), lines
PY
test -z "$(find "$root/scratch" -mindepth 1 -print -quit)"
"$prior/check-power-profile.sh" >"$evidence/power-after.env" || test "$?" -eq 2
cmp "$evidence/power-before.env" "$evidence/power-after.env"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
test "$(sha256sum "$panel" | cut -d ' ' -f 1)" = "$expected_panel"
test "$(sha256sum "$benchmark/slatedb/target/release/\
libflyology_db_slatedb_benchmark.so" | cut -d ' ' -f 1)" = "$expected_slate"
perf script --show-lost-events --ns -i "$evidence/perf.data" -F +pid,+tid,+period \
  >"$evidence/samples.txt" 2>"$evidence/perf-script.stderr"
test -s "$evidence/samples.txt"
test ! -s "$evidence/perf-script.stderr"
if grep -E 'PERF_RECORD_LOST|LOST [1-9][0-9]* events' "$evidence/samples.txt"; then
  printf '%s\n' 'profiler lost samples' >&2
  exit 1
fi
put_frames=$(grep -c -F 'flyology__db__store_mutation' "$evidence/samples.txt" || true)
printf '%s\n' "$put_frames" >"$evidence/store-mutation-frame-count.txt"
test "$put_frames" -ge 10
python3 - "$evidence/pair.json" "$evidence/metrics.ndjson" "$expected_state" \
  "$benchmark/run_realistic_campaign.py" >"$evidence/validated.json" <<'PY'
import importlib.util
import json
import statistics
import sys
from pathlib import Path

module_spec = importlib.util.spec_from_file_location("campaign", sys.argv[4])
assert module_spec is not None and module_spec.loader is not None
campaign = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(campaign)
reference = "slatedb-1ms-depth32"
contender = ("flyology-db-files-adaptive-cohort-members8-bytes2159008-"
             "wait-us1000-depth32-workers1-cohorts1")
_, rows = campaign.load_pair(Path(sys.argv[1]), Path(sys.argv[2]), reference, contender)
state = [r for r in rows if r.get("schema") == "flyology.db.benchmark.state_verification.v1"]
pairs = [r for r in rows if r.get("schema") == "flyology.db.benchmark.paired_primary_sample.v1"]
assert len(state) == 22 and len(pairs) == 10
assert all(r.get("state_sha256") == sys.argv[3]
           and r.get("expected_state_sha256") == sys.argv[3]
           and r.get("verified_keys") == 11008 for r in state)
assert sum(r["first"] == "reference" for r in pairs) == 5
assert all(r["transactions_per_operation"] == 35 for r in pairs)
assert not any(r.get("schema") == "flyology.db.benchmark.admission_trace.v1" for r in rows)
print(json.dumps({"schema": "flyology.db.benchmark.put_cpu_profile_validation.v1",
                  "classification": "diagnostic_cpu_sample_not_promotion_timing",
                  "profile_scope": "whole_process_including_warmup_and_both_participants",
                  "state_sha256": sys.argv[3], "state_count": len(state),
                  "pair_count": len(pairs),
                  "reference_median_ns": statistics.median(
                      r["reference_primary_ns_per_operation"] for r in pairs),
                  "contender_median_ns": statistics.median(
                      r["contender_primary_ns_per_operation"] for r in pairs)},
                 sort_keys=True, indent=2))
PY
test -z "$(find "$root/scratch" -mindepth 1 -print -quit)"
printf '%s\n' 'Flyology.DB x86 Put CPU sample profile passed' >"$evidence/sentinel.txt"
printf '%s\n' 'Flyology.DB x86 Put CPU sample profile passed'
