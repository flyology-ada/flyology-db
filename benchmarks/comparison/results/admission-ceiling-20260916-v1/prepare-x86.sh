#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/admission-ceiling-20260916-v1-x86_64
reuse=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64/candidate
source=$root/source
benchmark=$source/benchmarks/comparison
nested=$benchmark/.deps/flyology_db-fca74780
expected_diff=9882967037fe38e83b08c0e151b829dfbb600e54ea9708a255ee2d7ad27127c2

test "$(id -u)" -eq 0
test -d "$source/.git"
test ! -e "$source/.deps"
test ! -e "$source/config"
test ! -e "$source/alire"
test ! -e "$benchmark/.deps"
test ! -e "$benchmark/alire"
test ! -e "$root/evidence"
test -f "$root/nested-alire.toml"
test "$(git -C "$source" rev-parse HEAD)" = \
  613ad2b054725e99b73117f03ae38e213fdfaef7
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
test -d "$reuse/.deps/flyology-object-storage"
test -f "$reuse/config/flyology_db_config.gpr"
test -f "$reuse/alire/alire.lock"
test -f "$reuse/benchmarks/comparison/alire/alire.lock"

exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
mkdir "$root/evidence" "$root/scratch"
export TMPDIR=$root/scratch
export PATH="/home/ubuntu/.cargo/bin:/root/.cargo/bin:$PATH"

cp -a "$reuse/config" "$source/config"
cp -a "$reuse/alire" "$source/alire"
cp -a "$reuse/.deps" "$source/.deps"
mkdir -p "$benchmark/.deps"
cp -a "$reuse/benchmarks/comparison/alire" "$benchmark/alire"
cp -a "$reuse/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf" \
  "$benchmark/.deps/flyology_object_storage_0.1.0_5eaf79cf"
git clone --quiet --no-local "$source" "$nested"
git -C "$source" diff --binary HEAD -- | git -C "$nested" apply --binary
cp "$root/nested-alire.toml" "$nested/alire.toml"
cp -a "$reuse/config" "$nested/config"
cp -a "$reuse/alire" "$nested/alire"
cmp "$source/src/flyology-db.adb" "$nested/src/flyology-db.adb"
cmp "$source/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$nested/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb"

cargo build --manifest-path "$benchmark/slatedb/Cargo.toml" --release --locked \
  >"$root/evidence/cargo-build.log" 2>&1
(
  cd "$source"
  FLYOLOGY_DB_FORCE_REBUILD=1 ./oracles/adapters/tidesdb/scripts/build.sh
) >"$root/evidence/tidesdb-build.log" 2>&1
(
  cd "$benchmark"
  alr build --release -- -f
) >"$root/evidence/ada-build.log" 2>&1
grep -F 'flyology_db_benchmark_flyology.adb' "$root/evidence/ada-build.log" >/dev/null
grep -F 'flyology_db_benchmark_panel.adb' "$root/evidence/ada-build.log" >/dev/null
test -x "$benchmark/bin/flyology_db_benchmark_panel"
(
  cd "$benchmark"
  alr exec -- gprls -U -s -P flyology_db_benchmark.gpr
) >"$root/evidence/gpr-source-map.txt" 2>&1
grep -F "$source/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$root/evidence/gpr-source-map.txt" >/dev/null
if grep -F "$reuse/benchmarks/comparison/src/flyology_db_benchmark_flyology.adb" \
  "$root/evidence/gpr-source-map.txt" >/dev/null
then
  printf '%s\n' 'GPR selected an old benchmark adapter' >&2
  exit 1
fi
strings "$benchmark/bin/flyology_db_benchmark_panel" | grep -F admission_trace.v1 >/dev/null
sha256sum "$benchmark/bin/flyology_db_benchmark_panel" \
  "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  >"$root/evidence/binaries.sha256"
cmp "$reuse/config/flyology_db_config.gpr" "$source/config/flyology_db_config.gpr"
cmp "$reuse/alire/alire.lock" "$source/alire/alire.lock"
cmp "$reuse/benchmarks/comparison/alire/alire.lock" "$benchmark/alire/alire.lock"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
printf '%s\n' 'Flyology.DB isolated admission diagnostic x86 build passed' \
  >"$root/evidence/build-sentinel.txt"
printf '%s\n' 'Flyology.DB isolated admission diagnostic x86 build passed'
