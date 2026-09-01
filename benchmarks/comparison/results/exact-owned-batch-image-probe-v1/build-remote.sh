#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/exact-owned-batch-image-probe-v1
baseline=/mnt/flyology-bench/experiments/files-batch-etag-crc32c-probe-v1/candidate
config=/mnt/flyology-bench/experiments/files-batch-etag-crc32c-probe-v1/evidence/flyology-ubuntu.cgpr

test ! -e "$root/control"
test ! -e "$root/candidate"
mkdir -p "$root/evidence" "$root/logs"
cp -a "$baseline" "$root/control"
cp -a "$baseline" "$root/candidate"

for variant in control candidate; do
  cp "$root/incoming/flyology_db_benchmark_flyology.adb" \
    "$root/$variant/db/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb"
done
cp "$root/incoming/flyology-db.adb" "$root/candidate/db/src/flyology-db.adb"
cp "$root/incoming/flyology-db.ads" "$root/candidate/db/src/flyology-db.ads"
cp "$root/incoming/flyology-bytes.adb" "$root/candidate/flyology/src/flyology-bytes.adb"
cp "$root/incoming/flyology-bytes.ads" "$root/candidate/flyology/src/flyology-bytes.ads"
cp "$root/incoming/control_benchmark.gpr" "$root/control_benchmark.gpr"
cp "$root/incoming/candidate_benchmark.gpr" "$root/candidate_benchmark.gpr"

build_variant () {
  local variant=$1
  local project=$2
  cd "$root/$variant/db"
  FLYOLOGY_CRC_ARCH=x86_64 FLYOLOGY_CRC_HOST_OS=linux \
    alr exec -- /bin/sh -c \
    'FLYOLOGY_ROOT=$3; export FLYOLOGY_ROOT; \
     GPR_PROJECT_PATH=$3:$3/flyology_bench:$GPR_PROJECT_PATH; export GPR_PROJECT_PATH; \
     exec gprbuild --config="$1" -f -p -P "$2"' \
    sh "$config" "$project" "$root/$variant/flyology" \
    >"$root/logs/$variant-build.log" 2>&1
}

build_variant control "$root/control_benchmark.gpr"
build_variant candidate "$root/candidate_benchmark.gpr"

for variant in control candidate; do
  test -x "$root/$variant/binaries/flyology_db_benchmark"
  strings "$root/$variant/binaries/flyology_db_benchmark" \
    | grep -F 'group member receipt batch mismatch' >/dev/null
done
test -n "$(find "$root/candidate/db/obj" "$root/candidate/benchmark-obj" \
  -type f -name 'flyology-db.ali' -print -quit)"

sha256sum \
  "$root/control/binaries/flyology_db_benchmark" \
  "$root/candidate/binaries/flyology_db_benchmark" \
  "$root/control/db/src/flyology-db.adb" \
  "$root/candidate/db/src/flyology-db.adb" \
  "$root/candidate/db/src/flyology-db.ads" \
  "$root/candidate/flyology/src/flyology-bytes.adb" \
  "$root/candidate/flyology/src/flyology-bytes.ads" \
  "$root/control/db/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$root/candidate/db/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  >"$root/evidence/build.sha256"
printf '%s\n' EXACT_OWNED_BATCH_IMAGE_BUILD_COMPLETE
