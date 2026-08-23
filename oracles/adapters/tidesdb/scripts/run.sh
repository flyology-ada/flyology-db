#!/bin/sh
set -eu

adapter_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$adapter_root/../../.." && pwd)
upstream="$repository_root/.deps/tidesdb"
expected=23a67a6531bc6c0b537d3696758c7879586dcfce

test "$(git -C "$upstream" rev-parse HEAD)" = "$expected"
test -z "$(git -C "$upstream" status --short)"

case "$(uname -s)" in
  Darwin) library="$adapter_root/build/libflyology_tidesdb_oracle.dylib" ;;
  *) library="$adapter_root/build/libflyology_tidesdb_oracle.so" ;;
esac

"$adapter_root/scripts/build.sh" >/dev/null

exec python3 "$adapter_root/adapter.py" --library "$library"
