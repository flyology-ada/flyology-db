#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/admission-attribution-20260916-v1-x86_64
prior=/mnt/flyology-bench/experiments/admission-ceiling-20260916-v1-x86_64
source=$root/source
benchmark=$source/benchmarks/comparison
nested=$benchmark/.deps/flyology_db-fca74780
expected_diff=b4850b89330e9489d84e63c166410c6da9ffb2f515b0cda43dff0e794df902a3

test "$(id -u)" -eq 0
test -f "$root/adapter.adb"
test ! -e "$source"
test ! -e "$root/evidence"
test -d "$prior/source/.git"
test -f "$prior/nested-alire.toml"
test -f "$prior/source/config/flyology_db_config.gpr"
test -f "$prior/source/benchmarks/comparison/alire/alire.lock"
test -f "$prior/source/benchmarks/comparison/slatedb/target/release/\
libflyology_db_slatedb_benchmark.so"
test -f "$prior/source/oracles/adapters/tidesdb/build/libflyology_tidesdb_oracle.so"

exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
mkdir "$root/evidence" "$root/scratch"
export TMPDIR=$root/scratch
export PATH="/home/ubuntu/.cargo/bin:/root/.cargo/bin:$PATH"

git clone --quiet --no-local "$prior/source" "$source"
git -C "$prior/source" diff --binary HEAD -- | git -C "$source" apply --binary
cp "$root/adapter.adb" "$benchmark/src/flyology_db_benchmark_flyology.adb"
test "$(git -C "$source" rev-parse HEAD)" = 613ad2b054725e99b73117f03ae38e213fdfaef7
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"

cp -a "$prior/source/config" "$source/config"
cp -a "$prior/source/alire" "$source/alire"
cp -a "$prior/source/.deps" "$source/.deps"
cp -a "$prior/source/benchmarks/comparison/alire" "$benchmark/alire"
mkdir -p "$benchmark/.deps" "$benchmark/slatedb/target/release"
cp -a "$prior/source/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf" \
  "$benchmark/.deps/flyology_object_storage_0.1.0_5eaf79cf"
cp -a "$prior/source/benchmarks/comparison/slatedb/target/release/\
libflyology_db_slatedb_benchmark.so" "$benchmark/slatedb/target/release/"
cp -a "$prior/source/oracles/adapters/tidesdb/build" \
  "$source/oracles/adapters/tidesdb/build"
git clone --quiet --no-local "$source" "$nested"
git -C "$source" diff --binary HEAD -- | git -C "$nested" apply --binary
cp "$prior/nested-alire.toml" "$nested/alire.toml"
cp -a "$prior/source/config" "$nested/config"
cp -a "$prior/source/alire" "$nested/alire"
cmp "$source/src/flyology-db.adb" "$nested/src/flyology-db.adb"
cmp "$source/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$nested/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb"

(
  cd "$benchmark"
  alr build --release -- -f
) >"$root/evidence/ada-build.log" 2>&1
grep -F 'flyology_db_benchmark_flyology.adb' "$root/evidence/ada-build.log" >/dev/null
test -x "$benchmark/bin/flyology_db_benchmark_panel"
(
  cd "$benchmark"
  alr exec -- gprls -U -s -P flyology_db_benchmark.gpr
) >"$root/evidence/gpr-source-map.txt" 2>&1
grep -F "$source/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$root/evidence/gpr-source-map.txt" >/dev/null
if grep -F "$prior/source/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$root/evidence/gpr-source-map.txt" >/dev/null
then
  printf '%s\n' 'GPR selected the preceding experiment adapter' >&2
  exit 1
fi
strings "$benchmark/bin/flyology_db_benchmark_panel" | \
  grep -F preparation_cpu_ns >/dev/null
sha256sum "$benchmark/bin/flyology_db_benchmark_panel" \
  "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  >"$root/evidence/binaries.sha256"
cmp "$prior/source/config/flyology_db_config.gpr" "$source/config/flyology_db_config.gpr"
cmp "$prior/source/alire/alire.lock" "$source/alire/alire.lock"
cmp "$prior/source/benchmarks/comparison/alire/alire.lock" "$benchmark/alire/alire.lock"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
printf '%s\n' 'Flyology.DB isolated preparation attribution x86 build passed' \
  >"$root/evidence/build-sentinel.txt"
printf '%s\n' 'Flyology.DB isolated preparation attribution x86 build passed'
