#!/usr/bin/env bash
set -euo pipefail

experiment_root=/mnt/flyology-bench/experiments/opaque-batch-etag-ceiling-20260916-v1-x86_64
candidate_root=$experiment_root/candidate
baseline_root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64/candidate
patch_file=$experiment_root/input/experiment.patch

test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
test "$(sha256sum "$patch_file" | cut -d ' ' -f 1)" = \
  e360a4e143e50e1c172602a9ff8a09e2d4abc804d155a1161cee48a5baa0189a
test "$(sha256sum "$candidate_root/benchmarks/comparison/bin/flyology_db_benchmark_panel" | cut -d ' ' -f 1)" = \
  4226f2149562ef803caedf8107f1332da83b1bdd9295ddd937d411e78aabf70a
cmp "$baseline_root/src/flyology-db.adb" "$candidate_root/src/flyology-db.adb"
cmp "$baseline_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" \
    "$candidate_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb"
git -C "$candidate_root" apply --check "$patch_file"
git -C "$candidate_root" apply "$patch_file"
git -C "$candidate_root" diff --check
sha256sum \
  "$candidate_root/src/flyology-db.adb" \
  "$candidate_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb" \
  "$baseline_root/src/flyology-db.adb" \
  "$baseline_root/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/flyology-object_storage-backends-files.adb"
printf '%s\n' 'OPAQUE_BATCH_ETAG_EXPERIMENT_PATCH_APPLIED'
