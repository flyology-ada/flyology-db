#!/bin/sh
set -eu

adapter_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$adapter_root/../../.." && pwd)
upstream="$repository_root/.deps/tidesdb"
build="$adapter_root/build"
expected=23a67a6531bc6c0b537d3696758c7879586dcfce

if [ "${FLYOLOGY_DB_FORCE_REBUILD:-0}" = 1 ]
then
  expected_build="$repository_root/oracles/adapters/tidesdb/build"
  test "$build" = "$expected_build"
  rm -rf -- "$build"
fi

actual=$(git -C "$upstream" rev-parse HEAD)
if test "$actual" != "$expected"
then
  printf '%s\n' "TidesDB pin mismatch: expected $expected, found $actual" >&2
  exit 1
fi
test -z "$(git -C "$upstream" status --short)"

cmake -S "$upstream" -B "$build/upstream" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DTIDESDB_BUILD_TESTS=OFF \
  -DTIDESDB_WITH_SNAPPY=OFF \
  -DTIDESDB_WITH_LZ4=OFF \
  -DTIDESDB_WITH_ZSTD=OFF \
  -DTIDESDB_WITH_S3=OFF
#  Ordinary startup must not trust timestamps or retained linked artifacts.
#  Reconfigure above, then clean every generated target before compiling the
#  exact clean source pin.
cmake --build "$build/upstream" --clean-first --parallel

case "$(uname -s)" in
  Darwin)
    set --
    tidesdb_library="$build/upstream/libtidesdb.dylib"
    shim_library="$build/libflyology_tidesdb_oracle.dylib"
    shared_flag=-dynamiclib
    ;;
  Linux)
    # TidesDB's CMake target exports this definition for its public headers.
    set -- -D_GNU_SOURCE
    tidesdb_library="$build/upstream/libtidesdb.so"
    shim_library="$build/libflyology_tidesdb_oracle.so"
    shared_flag=-shared
    ;;
  *)
    set --
    tidesdb_library="$build/upstream/libtidesdb.so"
    shim_library="$build/libflyology_tidesdb_oracle.so"
    shared_flag=-shared
    ;;
esac

cc "$@" -std=c11 -O2 -fPIC -Wall -Wextra -Werror "$shared_flag" \
  -I"$upstream/src" -I"$upstream/external" -I"$build/upstream" \
  "$adapter_root/oracle_shim.c" "$tidesdb_library" \
  -Wl,-rpath,"$build/upstream" -o "$shim_library"

printf '%s\n' "$shim_library"
