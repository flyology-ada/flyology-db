#!/usr/bin/env bash
set -euo pipefail

experiment_root=/mnt/flyology-bench/experiments/opaque-batch-etag-ceiling-20260916-v1-x86_64
retained_root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64/candidate
baseline_root=$experiment_root/baseline
benchmark_root=$baseline_root/benchmarks/comparison
receipt_root=$experiment_root/explicit-baseline-build
test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
for program in alr gprbuild gnat1 gcc cc1 cargo rustc perf flyology_db_ben
do
  if pgrep -a -x "$program"
  then
    printf 'opaque-tag baseline build lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
test ! -e "$baseline_root"
test ! -L "$baseline_root"
test ! -e "$receipt_root"
test ! -L "$receipt_root"
test "$(cat "$experiment_root/explicit-root-build/status.json")" = '{"exit_status":0}'
test "$(sha256sum "$retained_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac
test "$(sha256sum "$retained_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" | cut -d ' ' -f 1)" = \
  dae8fd3566ccec9516c109712707f40c2562cd74fafa5ff1a5c9d11994879af4
cp -a "$retained_root" "$baseline_root"
mkdir "$receipt_root"
trap 'build_status=$?; printf "{\"exit_status\":%s}\n" "$build_status" >"$receipt_root/status.json"' EXIT
cmp "$retained_root/src/flyology-db.adb" "$baseline_root/src/flyology-db.adb"
cmp "$retained_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" \
  "$benchmark_root/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb"
(
  cd "$benchmark_root"
  alr exec -- gprls -aP "$baseline_root" -P flyology_db_benchmark.gpr -U -s
) >"$receipt_root/resolved-sources.txt" 2>"$receipt_root/resolution.stderr"
test ! -s "$receipt_root/resolution.stderr"
grep -Fx "$baseline_root/src/flyology-db.adb" "$receipt_root/resolved-sources.txt" >/dev/null
grep -Fx "$benchmark_root/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" \
  "$receipt_root/resolved-sources.txt" >/dev/null
test "$(grep -F '/flyology-db.adb' "$receipt_root/resolved-sources.txt" | wc -l)" -eq 1
(
  cd "$benchmark_root"
  alr exec -- gprbuild -aP "$baseline_root" -s -j0 -p -P flyology_db_benchmark.gpr -f
) >"$receipt_root/build.log" 2>&1
grep -F 'flyology-db.adb' "$receipt_root/build.log" >/dev/null
grep -F 'flyology-object_storage-backends-files.adb' "$receipt_root/build.log" >/dev/null
{ grep -Ei 'warning:|error:|\(style\)' "$receipt_root/build.log" || test "$?" -eq 1; } | \
  LC_ALL=C sort >"$receipt_root/diagnostics.txt"
sha256sum "$benchmark_root/bin/flyology_db_benchmark_panel" >"$receipt_root/panel.sha256"
sha256sum "$baseline_root/src/flyology-db.adb" \
  "$benchmark_root/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" \
  >"$receipt_root/sources.sha256"
test "$(sha256sum "$retained_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac
printf '%s\n' 'OPAQUE_BATCH_ETAG_EXPLICIT_BASELINE_BUILD_TERMINAL'
