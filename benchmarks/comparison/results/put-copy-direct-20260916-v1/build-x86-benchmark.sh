#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/put-copy-direct-20260916-v1-x86_64
prior=/mnt/flyology-bench/experiments/admission-attribution-20260916-v1-x86_64
source=$root/source
benchmark=$source/benchmarks/comparison
nested=$benchmark/.deps/flyology_db-fca74780
expected_diff=5e9b4cf6e1b41e51b80daa34d9108d6d32e45f9b0fb782c225064d7067267df2

test "$(id -un)" = ubuntu
test -d "$source/.git"
test "$(git -C "$source" rev-parse HEAD)" = 613ad2b054725e99b73117f03ae38e213fdfaef7
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = "$expected_diff"
test ! -e "$nested"
test ! -e "$benchmark/alire"
test -f "$prior/source/benchmarks/comparison/alire/alire.lock"
test -f "$prior/source/benchmarks/comparison/slatedb/target/release/\
libflyology_db_slatedb_benchmark.so"
test -f "$prior/source/oracles/adapters/tidesdb/build/libflyology_tidesdb_oracle.so"
test -f /mnt/flyology-bench/experiments/admission-ceiling-20260916-v1-x86_64/nested-alire.toml
if pgrep -x alr >/dev/null || pgrep -x gprbuild >/dev/null || pgrep -x gnat1 >/dev/null; then
  printf '%s\n' 'compiler lane occupied' >&2
  exit 1
fi

mkdir -p "$root/evidence" "$benchmark/.deps" "$benchmark/slatedb/target/release"
cp -a "$prior/source/benchmarks/comparison/alire" "$benchmark/alire"
cp -a "$prior/source/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf" \
  "$benchmark/.deps/flyology_object_storage_0.1.0_5eaf79cf"
cp -a "$prior/source/benchmarks/comparison/slatedb/target/release/\
libflyology_db_slatedb_benchmark.so" "$benchmark/slatedb/target/release/"
cp -a "$prior/source/oracles/adapters/tidesdb/build" "$source/oracles/adapters/tidesdb/build"
git clone --quiet --no-local "$source" "$nested"
git -C "$source" diff --binary HEAD -- | git -C "$nested" apply --binary
cp /mnt/flyology-bench/experiments/admission-ceiling-20260916-v1-x86_64/nested-alire.toml \
  "$nested/alire.toml"
cp -a "$source/config" "$nested/config"
cp -a "$source/alire" "$nested/alire"
cmp "$source/src/flyology-db.adb" "$nested/src/flyology-db.adb"
cmp "$source/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$nested/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb"

(
  cd "$benchmark"
  alr build --release -- -f
) >"$root/evidence/benchmark-build.log" 2>&1
test -x "$benchmark/bin/flyology_db_benchmark_panel"
(
  cd "$benchmark"
  alr exec -- gprls -U -s -P flyology_db_benchmark.gpr
) >"$root/evidence/gpr-source-map.txt" 2>&1
grep -F "$source/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$root/evidence/gpr-source-map.txt" >/dev/null
grep -F "$nested/src/flyology-db.adb" "$root/evidence/gpr-source-map.txt" >/dev/null
if grep -F "$prior/source/src/flyology-db.adb" "$root/evidence/gpr-source-map.txt" >/dev/null; then
  printf '%s\n' 'benchmark selected the preceding experiment source' >&2
  exit 1
fi
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = "$expected_diff"
cmp "$source/src/flyology-db.adb" "$nested/src/flyology-db.adb"
sha256sum "$benchmark/bin/flyology_db_benchmark_panel" \
  "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  "$nested/src/flyology-db.adb" >"$root/evidence/binaries-and-source.sha256"
printf '%s\n' 'Flyology.DB direct-copy x86 benchmark build passed'
