#!/usr/bin/env bash
set -euo pipefail

baseline_root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64/candidate
experiment_root=/mnt/flyology-bench/experiments/opaque-batch-etag-ceiling-20260916-v1-x86_64
candidate_root=$experiment_root/candidate

test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
for program in alr gprbuild gnat1 gcc cc1 cargo rustc perf flyology_db_ben
do
  if pgrep -a -x "$program"
  then
    printf 'opaque-tag experiment lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
test "$(git -C "$baseline_root" rev-parse HEAD)" = 613ad2b054725e99b73117f03ae38e213fdfaef7
test "$(sha256sum "$baseline_root/benchmarks/comparison/bin/flyology_db_benchmark_panel" | cut -d ' ' -f 1)" = \
  4226f2149562ef803caedf8107f1332da83b1bdd9295ddd937d411e78aabf70a
test "$(sha256sum "$baseline_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" | cut -d ' ' -f 1)" = \
  dae8fd3566ccec9516c109712707f40c2562cd74fafa5ff1a5c9d11994879af4
test ! -e "$experiment_root"
test ! -L "$experiment_root"
mkdir "$experiment_root"
mkdir "$experiment_root/input"
chown ubuntu:ubuntu "$experiment_root/input"
cp -a "$baseline_root" "$candidate_root"
cmp "$baseline_root/src/flyology-db.adb" "$candidate_root/src/flyology-db.adb"
cmp "$baseline_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" \
    "$candidate_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb"
printf '%s\n' 'OPAQUE_BATCH_ETAG_EXPERIMENT_COPY_READY'
