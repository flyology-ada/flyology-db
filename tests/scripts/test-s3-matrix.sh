#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
OBJECT_STORAGE_SCRIPTS="$PROJECT_ROOT/.deps/flyology-object-storage/tests/scripts"
RUNNER="$SCRIPT_DIR/run-db-s3-server-slice.sh"

# Three repetitions are the established upstream six-provider qualification
# geometry. The environment override changes only campaign repetition, not a
# DB timeout, retry count, connection capacity, or product compatibility rule.
REPEATS=${FLYOLOGY_DB_S3_MATRIX_REPEATS:-3}
case "$REPEATS" in
  ''|*[!0-9]*) echo "FLYOLOGY_DB_S3_MATRIX_REPEATS must be a positive integer" >&2; exit 2 ;;
esac
if [ "$REPEATS" -lt 1 ]; then
  echo "FLYOLOGY_DB_S3_MATRIX_REPEATS must be at least 1" >&2
  exit 2
fi

ALR=$("$PROJECT_ROOT/scripts/find-alr.sh")
"$PROJECT_ROOT/scripts/check-repository.sh"
(cd "$PROJECT_ROOT/tests" && "$ALR" build)

for SERVER in rustfs seaweedfs minio flyology-memory flyology-files flyology-sqlite
do
  RUN=1
  while [ "$RUN" -le "$REPEATS" ]
  do
    echo "Flyology.DB S3 matrix: $SERVER run $RUN/$REPEATS"
    case "$SERVER" in
      flyology-*)
        FLYOLOGY_S3_SERVER_RUNNER="$RUNNER" \
          "$OBJECT_STORAGE_SCRIPTS/test-flyology-server.sh" "${SERVER#flyology-}"
        ;;
      *)
        FLYOLOGY_S3_SERVER_RUNNER="$RUNNER" \
          "$OBJECT_STORAGE_SCRIPTS/test-$SERVER.sh"
        ;;
    esac
    RUN=$((RUN + 1))
  done
done

echo "Flyology.DB S3 matrix: all implementations and repetitions OK"
