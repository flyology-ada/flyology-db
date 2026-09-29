#!/usr/bin/env bash
set -euo pipefail

architecture=$1
experiment_root=$2
input_root=$experiment_root/input
source_root=$experiment_root/source
evidence_root=$experiment_root/evidence
scratch_root=$experiment_root/scratch-depth32

case "$architecture" in
  x86_64)
    expected_benchmark_lock=440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc
    ;;
  arm64)
    expected_benchmark_lock=d7b7a12db435e5d2e441ef5e9fa80332a85ef502e819d712072c402aeb3c797d
    ;;
  *) printf 'unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac
case "$experiment_root/" in
  /mnt/flyology-bench/experiments/pipelined-adaptive-natural-20260914-v5-*/ ) ;;
  *) printf 'invalid experiment root: %s\n' "$experiment_root" >&2; exit 1 ;;
esac

test -d "$input_root"
test -d "$source_root"
test -d "$evidence_root"
test ! -e "$scratch_root"
test ! -e "$evidence_root/matrix-depth32"
mkdir "$scratch_root"
test -f "$evidence_root/ada-build.log"
test -f "$evidence_root/tidesdb-build.log"
test -f "$evidence_root/panel-ldd.txt"
test ! -e "$evidence_root/sentinel.txt"

exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9 || { printf '%s\n' 'another benchmark campaign owns this host' >&2; exit 1; }

# shellcheck disable=SC1091
. "$input_root/source.env"
(cd "$input_root" && sha256sum -c inputs.sha256)
test "$(git -C "$source_root" rev-parse HEAD)" = "$SOURCE_HEAD"
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$SOURCE_DIFF_SHA256"
test "$(sha256sum "$source_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  "$ROOT_ALIRE_LOCK_SHA256"

benchmark=$source_root/benchmarks/comparison
test "$(sha256sum "$benchmark/alire/alire.lock" | cut -d ' ' -f 1)" = \
  "$expected_benchmark_lock"
grep -F 'Success: Build finished successfully' "$evidence_root/ada-build.log" >/dev/null
grep -F 'Built target tidesdb' "$evidence_root/tidesdb-build.log" >/dev/null

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

loaded_oracle=$(awk '$1 == "libflyology_tidesdb_oracle.so" { print $3 }' \
  "$evidence_root/panel-ldd.txt")
loaded_tides=$(awk '$1 ~ /^libtidesdb[.]so/ { print $3 }' \
  "$evidence_root/panel-ldd.txt")
test "$(printf '%s\n' "$loaded_oracle" | wc -l)" -eq 1
test "$(printf '%s\n' "$loaded_tides" | wc -l)" -eq 1
test "$(readlink -f "$loaded_oracle")" = \
  "$source_root/oracles/adapters/tidesdb/build/libflyology_tidesdb_oracle.so"
test "$(readlink -f "$loaded_tides")" = \
  "$(readlink -f \
    "$source_root/oracles/adapters/tidesdb/build/upstream/libtidesdb.so.9")"

export LD_LIBRARY_PATH="$benchmark/slatedb/target/release:\
$source_root/oracles/adapters/tidesdb/build:\
$source_root/oracles/adapters/tidesdb/build/upstream"
export FLYOLOGY_DB_BENCH_SCRATCH_ROOT=$scratch_root
export FLYOLOGY_BENCH_LOCK_PATH=/run/lock/flyology-bench-host-cpu.lock
power_detector=$source_root/.agents/skills/performance-testing/scripts/check-power-profile.sh
"$power_detector" >"$evidence_root/power-before-measurement.env" || test "$?" -eq 2
python3 "$input_root/natural-pipeline-driver.py" "$source_root" "$architecture" \
  "$evidence_root/matrix-depth32"
test -z "$(find "$scratch_root" -mindepth 1 -print -quit)"
"$power_detector" >"$evidence_root/power-after.env" || test "$?" -eq 2
test "$(git -C "$source_root" rev-parse HEAD)" = "$SOURCE_HEAD"
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$SOURCE_DIFF_SHA256"
git -C "$source_root" status --short >"$evidence_root/source-status.txt"
cp "$input_root/source.env" "$evidence_root/source.env"
cp "$input_root/inputs.sha256" "$evidence_root/inputs.sha256"
cp "$input_root/resume-natural-pipeline.sh" "$evidence_root/resume-natural-pipeline.sh"
printf '%s\n' 'Flyology.DB natural adaptive-pipeline remote campaign passed' \
  >"$evidence_root/sentinel.txt"
(
  cd "$evidence_root"
  find . -type f ! -name sha256sums.txt -print0 | LC_ALL=C sort -z | \
    xargs -0 sha256sum >sha256sums.txt
)
tar -C "$evidence_root" -czf "$experiment_root/artifacts.tar.gz" .
printf '%s\n' 'Flyology.DB natural adaptive-pipeline remote campaign passed'
