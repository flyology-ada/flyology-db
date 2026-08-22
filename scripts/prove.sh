#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$($project_root/scripts/find-alr.sh)
log=$(mktemp "${TMPDIR:-/tmp}/flyology-db-proof.XXXXXX")

cleanup_log()
{
  rm -f "$log"
}
trap cleanup_log EXIT HUP INT TERM

cd "$project_root/proof"
if ! "$alr" gnatprove -P flyology_db_proof.gpr --mode=all --level=1 -j0 \
  --output=oneline --output-header --report=all --warnings=error -f -u \
  flyology-db-head_policy.adb flyology-db-formats.adb flyology-db-batch_formats.adb \
  flyology-db-reference_model.adb >"$log" 2>&1
then
  cat "$log"
  exit 1
fi
cat "$log"
if grep -Eq ':[[:space:]]+(low|medium|high|warning):' "$log"; then
  printf '%s\n' "GNATprove reported an unproved check or warning" >&2
  exit 1
fi
printf '%s\n' "Flyology.DB SPARK proof suite passed"
