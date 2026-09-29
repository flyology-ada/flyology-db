#!/usr/bin/env bash
set -euo pipefail
retained=/mnt/flyology-bench/experiments/pipelined-adaptive-natural-20260914-v5-x86_64/source
root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v1-x86_64
patch_file=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v1.patch
test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
test ! -e "$root"
test ! -L "$root"
test "$(sha256sum "$retained/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  46d430be91f2ab987836600490399db784b8330840672b84c9d04bf7d48e97cb
test "$(sha256sum "$patch_file" | cut -d ' ' -f 1)" = \
  d9fae00dc4a013871b08f1411189a2c11b5fbe40aa39d32de33d4161be05859b
test "$(sha256sum /mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v1-diagnostics.txt \
  | cut -d ' ' -f 1)" = a1ebc2650db7a65a8c6831b1a48cbd732fb2abe456a3069d71cb1f3f3bfa2061
for program in perf alr gprbuild tlapm gnatprove flyology_db_ben
do
  if pgrep -a -x "$program"
  then
    printf 'build lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
mkdir "$root"
cp -a "$retained" "$root/baseline"
cp -a "$retained" "$root/candidate"
git -C "$root/candidate" apply --check "$patch_file"
git -C "$root/candidate" apply "$patch_file"
test "$(sha256sum "$root/candidate/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  4b3ba41ba407426baa4f301f296339dd59bdbe905c7c2adc188fcebd45965023
for role in baseline candidate
do
  source_root=$root/$role
  benchmark=$source_root/benchmarks/comparison
  # Preserve the actual owning GPRs, never an inherited preceding absolute root.
  cmp "$source_root/flyology_db.gpr" "$retained/flyology_db.gpr"
  cmp "$benchmark/flyology_db_benchmark.gpr" "$retained/benchmarks/comparison/flyology_db_benchmark.gpr"
  (
    cd "$benchmark"
    alr build --release -- -f
  ) >"$root/$role-build.log" 2>&1
  grep -F 'flyology-db.adb' "$root/$role-build.log" >/dev/null
  grep -F 'flyology_db_benchmark_flyology.adb' "$root/$role-build.log" >/dev/null
  # Diagnostic codegen comparison only: retain and reject drift from the exact
  # existing dependency warnings, never silently suppress a new warning family.
  { grep -Ei 'warning:|error:|\(style\)' "$root/$role-build.log" || test "$?" -eq 1; } | \
    LC_ALL=C sort >"$root/$role-diagnostics.txt"
  cmp "$root/$role-diagnostics.txt" \
    /mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v1-diagnostics.txt
  test "$(sha256sum "$source_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
    5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3
  test "$(sha256sum "$benchmark/alire/alire.lock" | cut -d ' ' -f 1)" = \
    440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc
  binary=$benchmark/bin/flyology_db_benchmark
  sha256sum "$binary" "$source_root/src/flyology-db.adb" >"$root/$role-binary.sha256"
  nm -n "$binary" | grep 'flyology__db__store_mutation' >"$root/$role-store-symbol.txt"
  objdump -d --disassemble=flyology__db__store_mutation "$binary" >"$root/$role-store.asm"
done
test "$(sha256sum "$retained/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  46d430be91f2ab987836600490399db784b8330840672b84c9d04bf7d48e97cb
printf '%s\n' 'DB_OWNED_COPY_FORCE_BUILD_TERMINAL'
