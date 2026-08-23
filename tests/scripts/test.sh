#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
alr=$($project_root/scripts/find-alr.sh)

cd "$project_root"
"$alr" build
"$project_root/scripts/check-repository.sh"
cd "$project_root/tests"
"$alr" build
./bin/flyology-db-tests
crash_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-group-crash.XXXXXX")
manifest_orphan_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-manifest-orphan.XXXXXX")
manifest_head_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-manifest-head.XXXXXX")
trap 'rm -rf "$crash_root" "$manifest_orphan_root" "$manifest_head_root"' EXIT HUP INT TERM
set +e
./bin/flyology-db-files_crash_probe crash "$crash_root"
crash_status=$?
set -e
test "$crash_status" -eq 137
./bin/flyology-db-files_crash_probe verify "$crash_root"
rm -rf "$crash_root"
set +e
./bin/flyology-db-files_crash_probe manifest-orphan-crash "$manifest_orphan_root"
manifest_orphan_status=$?
set -e
test "$manifest_orphan_status" -eq 137
./bin/flyology-db-files_crash_probe manifest-orphan-verify "$manifest_orphan_root"
rm -rf "$manifest_orphan_root"
set +e
./bin/flyology-db-files_crash_probe manifest-head-crash "$manifest_head_root"
manifest_head_status=$?
set -e
test "$manifest_head_status" -eq 137
./bin/flyology-db-files_crash_probe manifest-head-verify "$manifest_head_root"
rm -rf "$manifest_head_root"
trap - EXIT HUP INT TERM
printf '%s\n' "Flyology.DB files subprocess group and manifest crash/recovery passed"
cd "$project_root"
./oracles/adapters/tidesdb/scripts/test.sh
printf '%s\n' "Flyology.DB deterministic test suite passed"
