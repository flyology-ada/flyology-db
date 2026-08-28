#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)

if [[ $# -ne 1 ]]; then
  echo "usage: bash examples/run-files-getting-started.sh /absolute/fresh/files-root" >&2
  exit 2
fi

FILES_ROOT=$1
if printf '%s' "$FILES_ROOT" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  echo "Files root must not contain ASCII control characters" >&2
  exit 2
fi

case "$FILES_ROOT" in
  /)
    echo "refusing to use the filesystem root" >&2
    exit 2
    ;;
  /*)
    ;;
  *)
    echo "Files root must be an explicit absolute path" >&2
    exit 2
    ;;
esac

case "$FILES_ROOT" in
  */|*/../*|*/..|*/./*|*/.|*//*)
    echo "Files root must not contain empty, dot, or parent path components" >&2
    exit 2
    ;;
esac

ROOT_PARENT=${FILES_ROOT%/*}
ROOT_LEAF=${FILES_ROOT##*/}
if [[ -z "$ROOT_PARENT" || -z "$ROOT_LEAF" || ! -d "$ROOT_PARENT" ]]; then
  echo "Files root must have an existing parent directory" >&2
  exit 2
fi

PHYSICAL_PARENT=$(CDPATH= cd -- "$ROOT_PARENT" && pwd -P)
if [[ "$FILES_ROOT" != "$PHYSICAL_PARENT/$ROOT_LEAF" ]]; then
  echo "Files root must use its physical parent path without symlink ambiguity" >&2
  exit 2
fi

if [[ -e "$FILES_ROOT" || -L "$FILES_ROOT" ]]; then
  echo "Files root must not already exist: $FILES_ROOT" >&2
  exit 2
fi

report_root() {
  echo "Flyology.DB Files root (never removed by this runner): $FILES_ROOT"
}
trap report_root EXIT

ALR=$("$PROJECT_ROOT/scripts/find-alr.sh")
"$ALR" exec -- gprbuild -p -P "$SCRIPT_DIR/files_getting_started.gpr"

if [[ -e "$FILES_ROOT" || -L "$FILES_ROOT" ]]; then
  echo "fresh Files root appeared during the build: $FILES_ROOT" >&2
  exit 1
fi

"$PROJECT_ROOT/obj/examples/bin/flyology_db_files_getting_started" "$FILES_ROOT"

if [[ ! -d "$FILES_ROOT" || -L "$FILES_ROOT" ]]; then
  echo "Files backend did not leave the expected retained directory" >&2
  exit 1
fi

echo "Flyology.DB Files getting started passed"
