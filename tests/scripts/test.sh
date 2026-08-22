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
printf '%s\n' "Flyology.DB deterministic test suite passed"
