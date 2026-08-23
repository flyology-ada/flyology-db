#!/bin/sh
set -eu

adapter_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$adapter_root/../../.." && pwd)
upstream="$repository_root/.deps/tidesdb"
build="$adapter_root/build/upstream-tests"
expected=23a67a6531bc6c0b537d3696758c7879586dcfce

test "$(git -C "$upstream" rev-parse HEAD)" = "$expected"
test -z "$(git -C "$upstream" status --short)"
cmake -S "$upstream" -B "$build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DTIDESDB_BUILD_TESTS=ON \
  -DTIDESDB_WITH_SNAPPY=OFF \
  -DTIDESDB_WITH_LZ4=OFF \
  -DTIDESDB_WITH_ZSTD=OFF \
  -DTIDESDB_WITH_S3=OFF >/dev/null
cmake --build "$build" --parallel >/dev/null

test_log=$(mktemp /tmp/flyology-tidesdb-upstream-tests.XXXXXX)
trap 'rm -f "$test_log"' EXIT HUP INT TERM
for test_name in \
  test_isolation_snapshot \
  test_serializable_phantom_prevention \
  test_crash_recovery_no_clean_close \
  test_unified_multi_cf_flush_and_recovery
do
  if ! "$build/tidesdb_tests" "$test_name" >>"$test_log" 2>&1
  then
    cat "$test_log" >&2
    exit 1
  fi
done
printf '%s\n' "Selected pinned TidesDB upstream tests passed (4/4)"
