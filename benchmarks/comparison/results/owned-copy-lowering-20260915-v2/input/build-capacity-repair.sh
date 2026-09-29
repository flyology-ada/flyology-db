#!/usr/bin/env bash
set -euo pipefail
root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64
source_root=$root/candidate
previous=$root/correctness
output=$root/capacity-repair-build
patch_file=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-capacity-repair.patch
test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
for program in perf java alr gprbuild gprbind gnat1 gnatbind gnatlink gcc cc1 clang cargo rustc \
  tlapm gnatprove gnatdoc flyology_db_ben flyology-db-tes
do
  if pgrep -a -x "$program"
  then
    printf 'capacity-repair build lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
test ! -e "$output"
test ! -L "$output"
test "$(cat "$root/engine-corrected/status.json")" = '{"exit_status":1}'
test "$(sha256sum "$root/engine-corrected/engine-tests.log" | cut -d ' ' -f 1)" = \
  2a4e377076dff58c641867cbd5122372e3541f448a256d12849eca35fc399d54
test "$(sha256sum "$source_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac
test "$(sha256sum "$source_root/tests/src/flyology-db-engine_tests.adb" | cut -d ' ' -f 1)" = \
  7a79552480d5939c0805a7a411e0bf123e5722d4534e66c9d7dcf670d98ad0d7
test "$(sha256sum "$source_root/tests/bin/flyology-db-tests" | cut -d ' ' -f 1)" = \
  f576a0a7461cea0bf86ef9084fd77b8e92c09f409791e597d0efa9af69d8adf8
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  cddc957b5bdfe5404ab96fc9d6ca0b7f4ee46f87c0d4af5baf446d5cce8b30d9
test "$(sha256sum "$patch_file" | cut -d ' ' -f 1)" = \
  d7b494878da32034853cb142ac5778e139f6f2da95aaed879168d4a44ea47654
test "$(sha256sum "$previous/tests-diagnostics.txt" | cut -d ' ' -f 1)" = \
  5e937300a9ff027dd4f61d0bedb60e6389f1500e808173a82a61d3b61924a6be
sha256sum -c "$previous/config-before.sha256"
sha256sum -c "$previous/locks-before.sha256"
mkdir "$output"
trap 'status=$?; printf "{\"exit_status\":%s}\n" "$status" >"$output/status.json"' EXIT
mkdir "$output/scratch"
export TMPDIR=$output/scratch
cp -p "$source_root/tests/bin/flyology-db-tests" "$output/rejected-capacity-tests-binary"
git -C "$source_root" apply --check "$patch_file"
git -C "$source_root" apply "$patch_file"
test "$(sha256sum "$source_root/tests/src/flyology-db-engine_tests.adb" | cut -d ' ' -f 1)" = \
  bbae4a2d17c5f7eac908f7045c684a7e57f820ee3c48f22713da661fa719ef9e
git -C "$source_root" diff --binary HEAD -- | sha256sum >"$output/source-before.sha256"
(
  cd "$source_root/benchmarks/comparison"
  alr exec -- gprls -aP "$source_root" -P ../../tests/flyology_db_tests.gpr -U -s
) >"$output/resolved-sources.txt" 2>"$output/resolution.stderr"
test ! -s "$output/resolution.stderr"
cmp "$root/corrected-build/resolved-sources.txt" "$output/resolved-sources.txt"
# Recompile the changed test body only. The once-forced runtime and dependency
# closure already passed the compiled-source gate; this is not a release gate.
(
  cd "$source_root/benchmarks/comparison"
  alr exec -- gprbuild -aP "$source_root" -s -j0 -p -P ../../tests/flyology_db_tests.gpr
) >"$output/tests-build.log" 2>&1
grep -F 'flyology-db-engine_tests.adb' "$output/tests-build.log" >/dev/null
{ grep -Ei 'warning:|error:|\(style\)' "$output/tests-build.log" || test "$?" -eq 1; } | \
  LC_ALL=C sort >"$output/tests-diagnostics.txt"
LC_ALL=C comm -23 "$output/tests-diagnostics.txt" "$previous/tests-diagnostics.txt" \
  >"$output/new-diagnostics.txt"
test ! -s "$output/new-diagnostics.txt"
git -C "$source_root" diff --binary HEAD -- | sha256sum >"$output/source-after.sha256"
cmp "$output/source-before.sha256" "$output/source-after.sha256"
sha256sum -c "$previous/config-before.sha256" >"$output/config-check.txt"
sha256sum -c "$previous/locks-before.sha256" >"$output/locks-check.txt"
binary=$source_root/tests/bin/flyology-db-tests
sha256sum "$binary" >"$output/tests-binary.sha256"
objdump -d --disassemble=flyology__db__store_mutation "$binary" >"$output/store.asm"
nm -S "$binary" | grep -F 'copy_into_candidate' >"$output/copy-symbols.txt"
test "$(sha256sum "$source_root/benchmarks/comparison/bin/flyology_db_benchmark" | \
  cut -d ' ' -f 1)" = f20f73cbfc9ab606c2f9a1463d6831b9bebe90fa550ed4895149e6088878477e
printf '%s\n' 'DB_DIRECT_COPY_CAPACITY_REPAIR_BUILD_TERMINAL'
