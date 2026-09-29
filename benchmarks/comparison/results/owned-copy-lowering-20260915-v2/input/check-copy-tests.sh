#!/usr/bin/env bash
set -euo pipefail
root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64
source_root=$root/candidate
benchmark=$source_root/benchmarks/comparison
output=$root/correctness
patch_file=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-tests.patch
diagnostics=$root/candidate-diagnostics.txt
test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
exec 8>/run/lock/flyology-bench-host-cpu.lock
flock -n 8
test ! -e "$output"
test ! -L "$output"
for program in perf java alr gprbuild gnat1 gcc cc1 clang cargo rustc tlapm gnatprove gnatdoc \
  flyology_db_ben flyology-db-tes
do
  if pgrep -a -x "$program"
  then
    printf 'direct-copy correctness lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
test "$(sha256sum "$patch_file" | cut -d ' ' -f 1)" = \
  006fa5e11801c95229a6b9b0cc8700a15f0c02e5b94251cb1cca77300c383076
test "$(sha256sum "$source_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac
test "$(sha256sum "$source_root/tests/src/flyology-db-engine_tests.adb" | cut -d ' ' -f 1)" = \
  a44d5693d2dbb79a95d536e145e76bd844a86be6748df22e8b0dd757d588dbf1
test "$(sha256sum "$benchmark/bin/flyology_db_benchmark" | cut -d ' ' -f 1)" = \
  f20f73cbfc9ab606c2f9a1463d6831b9bebe90fa550ed4895149e6088878477e
mkdir "$output"
trap 'test_status=$?; printf "{\"exit_status\":%s}\n" "$test_status" >"$output/test.status.json"' EXIT
mkdir "$output/scratch"
export TMPDIR=$output/scratch
git -C "$source_root" apply --check "$patch_file"
git -C "$source_root" apply "$patch_file"
test "$(sha256sum "$source_root/tests/src/flyology-db-engine_tests.adb" | cut -d ' ' -f 1)" = \
  7a79552480d5939c0805a7a411e0bf123e5722d4534e66c9d7dcf670d98ad0d7
git -C "$source_root" diff --binary HEAD -- | sha256sum >"$output/source-before.sha256"
sha256sum "$source_root"/config/* >"$output/config-before.sha256"
sha256sum "$source_root/alire/alire.lock" "$benchmark/alire/alire.lock" >"$output/locks-before.sha256"
# The maintained test project runs under the already-resolved release
# environment. Do not create a new nested Alire solution or select revisions.
(
  cd "$benchmark"
  alr exec -- gprbuild -s -j0 -p -P ../../tests/flyology_db_tests.gpr -f
) >"$output/tests-build.log" 2>&1
grep -F 'flyology-db-engine_tests.adb' "$output/tests-build.log" >/dev/null
grep -F 'flyology-db.adb' "$output/tests-build.log" >/dev/null
{ grep -Ei 'warning:|error:|\(style\)' "$output/tests-build.log" || test "$?" -eq 1; } | \
  LC_ALL=C sort >"$output/tests-diagnostics.txt"
LC_ALL=C comm -23 "$output/tests-diagnostics.txt" "$diagnostics" >"$output/new-diagnostics.txt"
test ! -s "$output/new-diagnostics.txt"
(
  cd "$source_root/tests"
  ./bin/flyology-db-tests
) >"$output/engine-tests.log" 2>&1
grep -Fx 'Flyology.DB formats, policy, model, and local log engine: OK' "$output/engine-tests.log" >/dev/null
git -C "$source_root" diff --binary HEAD -- | sha256sum >"$output/source-after.sha256"
sha256sum "$source_root"/config/* >"$output/config-after.sha256"
sha256sum "$source_root/alire/alire.lock" "$benchmark/alire/alire.lock" >"$output/locks-after.sha256"
cmp "$output/source-before.sha256" "$output/source-after.sha256"
cmp "$output/config-before.sha256" "$output/config-after.sha256"
cmp "$output/locks-before.sha256" "$output/locks-after.sha256"
sha256sum "$source_root/tests/bin/flyology-db-tests" >"$output/tests-binary.sha256"
test "$(sha256sum "$benchmark/bin/flyology_db_benchmark" | cut -d ' ' -f 1)" = \
  f20f73cbfc9ab606c2f9a1463d6831b9bebe90fa550ed4895149e6088878477e
printf '%s\n' 'DB_DIRECT_COPY_ENGINE_CORRECTNESS_TERMINAL'
