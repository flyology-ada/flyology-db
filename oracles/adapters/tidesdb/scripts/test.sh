#!/bin/sh
set -eu

adapter_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$adapter_root/../../.." && pwd)

"$adapter_root/scripts/build.sh" >/dev/null
case "$(uname -s)" in
  Darwin) retained_library="$adapter_root/build/upstream/libtidesdb.dylib" ;;
  *) retained_library="$adapter_root/build/upstream/libtidesdb.so" ;;
esac
#  A future-dated retained binary must not survive the ordinary clean build.
printf '%s\n' "deliberately stale linked artifact" >"$retained_library"
touch -t 209901010000 "$retained_library"
"$adapter_root/scripts/build.sh" >/dev/null
PYTHONPYCACHEPREFIX=/tmp/flyology-db-tidesdb-pycache PYTHONWARNINGS=error \
  python3 -m unittest discover -s "$adapter_root/tests" -p 'test_*.py'
"$adapter_root/scripts/test-upstream.sh"
"$repository_root/oracles/contract/validate_workload.py" \
  "$repository_root/oracles/contract/workload.schema.json" \
  "$adapter_root/tests/fixtures/"*.ndjson

printf '%s\n' "TidesDB pinned adapter tests passed"
