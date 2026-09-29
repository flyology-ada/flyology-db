#!/usr/bin/env bash
set -euo pipefail

experiment_root=/mnt/flyology-bench/experiments/opaque-batch-etag-ceiling-20260916-v1-x86_64
candidate_root=$experiment_root/candidate
benchmark_root=$candidate_root/benchmarks/comparison
baseline_root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64/candidate

test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
for program in alr gprbuild gnat1 gcc cc1 cargo rustc perf flyology_db_ben
do
  if pgrep -a -x "$program"
  then
    printf 'opaque-tag build lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
test "$(sha256sum "$candidate_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  2fdbe17943c10d74b86baa2b0669090de0525728d7cc0a6d0019ba868d1a0f97
test "$(sha256sum "$benchmark_root/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" | cut -d ' ' -f 1)" = \
  1877168fcf63a47abf4e530ea49ad14754287f862d9faa100bb54f5cfcc35115
test "$(sha256sum "$candidate_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3
test "$(sha256sum "$benchmark_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc
test ! -e "$experiment_root/build.status.json"
trap 'build_status=$?; printf "{\"exit_status\":%s}\n" "$build_status" >"$experiment_root/build.status.json"' EXIT

(
  cd "$benchmark_root"
  alr -n build --release -- -f
) >"$experiment_root/build.log" 2>&1
grep -F 'flyology-db.adb' "$experiment_root/build.log" >/dev/null
grep -F 'flyology-object_storage-backends-files.adb' "$experiment_root/build.log" >/dev/null
{ grep -Ei 'warning:|error:|\(style\)' "$experiment_root/build.log" || test "$?" -eq 1; } | \
  LC_ALL=C sort >"$experiment_root/diagnostics.txt"
cmp "$experiment_root/diagnostics.txt" \
  /mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64/candidate-diagnostics.txt
test "$(sha256sum "$candidate_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3
test "$(sha256sum "$benchmark_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc
sha256sum "$benchmark_root/bin/flyology_db_benchmark_panel" >"$experiment_root/panel.sha256"
test "$(sha256sum "$baseline_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac
test "$(sha256sum "$baseline_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" | cut -d ' ' -f 1)" = \
  dae8fd3566ccec9516c109712707f40c2562cd74fafa5ff1a5c9d11994879af4
printf '%s\n' 'OPAQUE_BATCH_ETAG_FORCE_BUILD_TERMINAL'
