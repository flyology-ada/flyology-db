#!/bin/sh
set -eu

adapter_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$adapter_root/../../.." && pwd)

if test "$#" -ne 2
then
  printf '%s\n' "usage: $0 OBJECT_ROOT DATABASE_PATH" >&2
  exit 2
fi

object_root=$1
database_path=$2
mkdir -p "$object_root"
"$adapter_root/scripts/build.sh" >/dev/null
exec "$project_root/build/oracles/slatedb-adapter/debug/flyology-db-slatedb-adapter" \
  --root "$object_root" \
  --database-path "$database_path"
