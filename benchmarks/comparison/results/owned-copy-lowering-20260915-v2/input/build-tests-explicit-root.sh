#!/usr/bin/env bash
set -euo pipefail
root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64
source_root=$root/candidate
previous=$root/correctness
output=$root/corrected-build
test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
for program in perf java alr gprbuild gnat1 gcc cc1 clang cargo rustc tlapm gnatprove gnatdoc \
  flyology_db_ben flyology-db-tes
do
  if pgrep -a -x "$program"
  then
    printf 'direct-copy corrected build lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
test ! -e "$output"
test ! -L "$output"
test ! -e "$root/engine-first"
test ! -e "$previous/engine-tests.log"
test "$(sha256sum "$source_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac
test "$(sha256sum "$source_root/tests/src/flyology-db-engine_tests.adb" | cut -d ' ' -f 1)" = \
  7a79552480d5939c0805a7a411e0bf123e5722d4534e66c9d7dcf670d98ad0d7
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  cddc957b5bdfe5404ab96fc9d6ca0b7f4ee46f87c0d4af5baf446d5cce8b30d9
test "$(sha256sum "$previous/tests-diagnostics.txt" | cut -d ' ' -f 1)" = \
  5e937300a9ff027dd4f61d0bedb60e6389f1500e808173a82a61d3b61924a6be
test "$(sha256sum "$source_root/tests/bin/flyology-db-tests" | cut -d ' ' -f 1)" = \
  886b4bf752dc170825e81d6bc1e4e8ac047fa91307133fc0546bbef4c8984fa7
sha256sum -c "$previous/config-before.sha256"
sha256sum -c "$previous/locks-before.sha256"
mkdir "$output"
trap 'status=$?; printf "{\"exit_status\":%s}\n" "$status" >"$output/status.json"' EXIT
mkdir "$output/scratch"
export TMPDIR=$output/scratch
cp -p "$source_root/tests/bin/flyology-db-tests" "$output/rejected-tests-binary"
(
  cd "$source_root/benchmarks/comparison"
  alr exec -- gprls -aP "$source_root" -P ../../tests/flyology_db_tests.gpr -U -s
) >"$output/resolved-sources.txt" 2>"$output/resolution.stderr"
test ! -s "$output/resolution.stderr"
grep -Fx "$source_root/src/flyology-db.adb" "$output/resolved-sources.txt" >/dev/null
test "$(grep -F '/flyology-db.adb' "$output/resolved-sources.txt" | wc -l)" -eq 1
grep -Fx "$source_root/tests/src/flyology-db-engine_tests.adb" \
  "$output/resolved-sources.txt" >/dev/null
(
  cd "$source_root/benchmarks/comparison"
  alr exec -- gprbuild -aP "$source_root" -s -j0 -p -P ../../tests/flyology_db_tests.gpr -f
) >"$output/tests-build.log" 2>&1
grep -F 'flyology-db-engine_tests.adb' "$output/tests-build.log" >/dev/null
grep -F 'flyology-db.adb' "$output/tests-build.log" >/dev/null
{ grep -Ei 'warning:|error:|\(style\)' "$output/tests-build.log" || test "$?" -eq 1; } | \
  LC_ALL=C sort >"$output/tests-diagnostics.txt"
cmp "$previous/tests-diagnostics.txt" "$output/tests-diagnostics.txt"
git -C "$source_root" diff --binary HEAD -- | sha256sum >"$output/source-after.sha256"
cmp "$previous/source-before.sha256" "$output/source-after.sha256"
sha256sum -c "$previous/config-before.sha256" >"$output/config-check.txt"
sha256sum -c "$previous/locks-before.sha256" >"$output/locks-check.txt"
binary=$source_root/tests/bin/flyology-db-tests
sha256sum "$binary" >"$output/tests-binary.sha256"
objdump -d --disassemble=flyology__db__store_mutation "$binary" >"$output/store.asm"
nm -S "$binary" | grep -F 'copy_into_candidate' >"$output/copy-symbols.txt"
nm -S "$binary" | grep -F 'test_owned_copy_boundaries' >"$output/boundary-symbols.txt"
test "$(sha256sum "$source_root/benchmarks/comparison/bin/flyology_db_benchmark" | \
  cut -d ' ' -f 1)" = f20f73cbfc9ab606c2f9a1463d6831b9bebe90fa550ed4895149e6088878477e
printf '%s\n' 'DB_DIRECT_COPY_EXPLICIT_ROOT_BUILD_TERMINAL'
