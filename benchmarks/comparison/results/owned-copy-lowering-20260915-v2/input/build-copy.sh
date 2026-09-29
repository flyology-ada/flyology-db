#!/usr/bin/env bash
set -euo pipefail
retained=/mnt/flyology-bench/experiments/pipelined-adaptive-natural-20260914-v5-x86_64/source
baseline=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v1-x86_64/baseline
root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64
patch_file=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2.patch
diagnostics=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v1-diagnostics.txt
test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
test ! -e "$root"
test ! -L "$root"
for program in perf java alr gprbuild gnat1 gcc cc1 clang cargo rustc tlapm gnatprove gnatdoc flyology_db_ben
do
  if pgrep -a -x "$program"
  then
    printf 'direct-copy build lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
test "$(sha256sum "$patch_file" | cut -d ' ' -f 1)" = \
  7f45e728d66566f6062b832c659ac373c20a44aa3b0722a99cf48780476dbcd2
test "$(sha256sum "$diagnostics" | cut -d ' ' -f 1)" = \
  a1ebc2650db7a65a8c6831b1a48cbd732fb2abe456a3069d71cb1f3f3bfa2061
test "$(sha256sum "$retained/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  46d430be91f2ab987836600490399db784b8330840672b84c9d04bf7d48e97cb
test "$(sha256sum "$baseline/benchmarks/comparison/bin/flyology_db_benchmark" | cut -d ' ' -f 1)" = \
  6bc8b3175ffdaf64a52f059d9fbb329b08c07bf88e46f82229ba2b9f364f76dd
mkdir "$root"
# Retain authoritative terminal status even if the enclosing SSH observer loses
# transport. This is a status receipt, not permission to retry a failed build.
trap 'build_status=$?; printf "{\"exit_status\":%s}\n" "$build_status" >"$root/build.status.json"' EXIT
cp -a "$retained" "$root/candidate"
git -C "$root/candidate" apply --check "$patch_file"
git -C "$root/candidate" apply "$patch_file"
source_root=$root/candidate
benchmark=$source_root/benchmarks/comparison
test "$(sha256sum "$source_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac
cmp "$source_root/flyology_db.gpr" "$retained/flyology_db.gpr"
cmp "$benchmark/flyology_db_benchmark.gpr" "$retained/benchmarks/comparison/flyology_db_benchmark.gpr"
(
  cd "$benchmark"
  alr build --release -- -f
) >"$root/candidate-build.log" 2>&1
grep -F 'flyology-db.adb' "$root/candidate-build.log" >/dev/null
grep -F 'flyology_db_benchmark_flyology.adb' "$root/candidate-build.log" >/dev/null
{ grep -Ei 'warning:|error:|\(style\)' "$root/candidate-build.log" || test "$?" -eq 1; } | \
  LC_ALL=C sort >"$root/candidate-diagnostics.txt"
cmp "$root/candidate-diagnostics.txt" "$diagnostics"
test "$(sha256sum "$source_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3
test "$(sha256sum "$benchmark/alire/alire.lock" | cut -d ' ' -f 1)" = \
  440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc
binary=$benchmark/bin/flyology_db_benchmark
sha256sum "$binary" "$source_root/src/flyology-db.adb" >"$root/candidate-binary.sha256"
nm -n "$binary" | grep 'flyology__db__store_mutation' >"$root/candidate-store-symbol.txt"
objdump -d --disassemble=flyology__db__store_mutation "$binary" >"$root/candidate-store.asm"
test "$(sha256sum "$retained/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  46d430be91f2ab987836600490399db784b8330840672b84c9d04bf7d48e97cb
printf '%s\n' 'DB_DIRECT_COPY_FORCE_BUILD_TERMINAL'
