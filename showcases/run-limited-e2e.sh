#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ALR=$("$PROJECT_ROOT/scripts/find-alr.sh")
CAMPAIGN_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-e2e.XXXXXX")

cleanup() {
  case "$CAMPAIGN_ROOT" in
    */flyology-db-e2e.*) rm -rf -- "$CAMPAIGN_ROOT" ;;
    *) echo "refusing to remove unexpected showcase root: $CAMPAIGN_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

"$ALR" exec -- gprbuild -p -P "$SCRIPT_DIR/limited_e2e.gpr"
"$SCRIPT_DIR/bin/flyology_db_limited_e2e" "$CAMPAIGN_ROOT"
