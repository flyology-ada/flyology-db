#!/usr/bin/env bash
set -euo pipefail
root=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64
source_root=$root/candidate
build=$root/corrected-build
previous=$root/correctness
output=$root/engine-corrected
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
    printf 'direct-copy engine lane occupied: %s\n' "$program" >&2
    exit 1
  fi
done
test ! -e "$output"
test ! -L "$output"
test ! -e "$root/engine-first"
test ! -e "$previous/engine-tests.log"
test ! -e "$source_root/tests/obj/files-engine"
test ! -L "$source_root/tests/obj/files-engine"
test "$(cat "$build/status.json")" = '{"exit_status":0}'
test "$(sha256sum "$source_root/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac
test "$(sha256sum "$source_root/tests/src/flyology-db-engine_tests.adb" | cut -d ' ' -f 1)" = \
  7a79552480d5939c0805a7a411e0bf123e5722d4534e66c9d7dcf670d98ad0d7
test "$(sha256sum "$source_root/tests/bin/flyology-db-tests" | cut -d ' ' -f 1)" = \
  f576a0a7461cea0bf86ef9084fd77b8e92c09f409791e597d0efa9af69d8adf8
test "$(sha256sum "$build/tests-diagnostics.txt" | cut -d ' ' -f 1)" = \
  5e937300a9ff027dd4f61d0bedb60e6389f1500e808173a82a61d3b61924a6be
test "$(sha256sum "$build/copy-helper.asm" | cut -d ' ' -f 1)" = \
  92ad50458414c69120acefbba70141d5e28af2eeb4ebc3933b6847ea7688f75e
test "$(sha256sum "$build/resolved-sources.txt" | cut -d ' ' -f 1)" = \
  b723bb004b0dab2315c57f313ae88bea09dcfcf0da41e5b642573672d7f46fcc
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  cddc957b5bdfe5404ab96fc9d6ca0b7f4ee46f87c0d4af5baf446d5cce8b30d9
sha256sum -c "$previous/config-before.sha256"
sha256sum -c "$previous/locks-before.sha256"
mkdir "$output"
trap 'status=$?; printf "{\"exit_status\":%s}\n" "$status" >"$output/status.json"' EXIT
mkdir "$output/scratch"
export TMPDIR=$output/scratch
(
  cd "$source_root/tests"
  ./bin/flyology-db-tests
) >"$output/engine-tests.log" 2>&1
grep -Fx 'Flyology.DB formats, policy, model, and local log engine: OK' \
  "$output/engine-tests.log" >/dev/null
git -C "$source_root" diff --binary HEAD -- | sha256sum >"$output/source-after.sha256"
cmp "$previous/source-before.sha256" "$output/source-after.sha256"
sha256sum -c "$previous/config-before.sha256" >"$output/config-check.txt"
sha256sum -c "$previous/locks-before.sha256" >"$output/locks-check.txt"
sha256sum "$source_root/tests/bin/flyology-db-tests" >"$output/tests-binary.sha256"
test "$(cut -d ' ' -f 1 "$output/tests-binary.sha256")" = \
  f576a0a7461cea0bf86ef9084fd77b8e92c09f409791e597d0efa9af69d8adf8
test "$(sha256sum "$source_root/benchmarks/comparison/bin/flyology_db_benchmark" | \
  cut -d ' ' -f 1)" = f20f73cbfc9ab606c2f9a1463d6831b9bebe90fa550ed4895149e6088878477e
test ! -e "$source_root/tests/obj/files-engine"
printf '%s\n' 'DB_DIRECT_COPY_CORRECTED_ENGINE_TERMINAL'
