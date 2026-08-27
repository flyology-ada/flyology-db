#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "usage: $0 ENDPOINT EXISTING_BUCKET FRESH_PREFIX REGION path|virtual-hosted TIMEOUT_SECONDS" >&2
  exit 2
fi

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ALR=$("$PROJECT_ROOT/scripts/find-alr.sh")

case "$5" in
  path|virtual-hosted) ;;
  *) echo "addressing style must be path or virtual-hosted" >&2; exit 2 ;;
esac

"$ALR" exec -- gprbuild -p -P "$SCRIPT_DIR/object_storage_e2e.gpr"
"$SCRIPT_DIR/bin/flyology_db_object_storage_e2e" "$@"
