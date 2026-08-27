#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 ENDPOINT BUCKET ACCESS_KEY SECRET_KEY" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
ENDPOINT=$1
BUCKET=$2
ACCESS_KEY=$3
SECRET_KEY=$4

case "$ENDPOINT" in
  http://host.docker.internal:*)
    # The upstream provider harness supplies this address for runners that
    # execute in a container. This DB runner executes on the host and reaches
    # the same published port through loopback.
    ENDPOINT="http://127.0.0.1:${ENDPOINT##*:}"
    ;;
  http://127.0.0.1:*) ;;
  *) echo "unsupported matrix endpoint: $ENDPOINT" >&2; exit 2 ;;
esac

IMPLEMENTATION=${FLYOLOGY_S3_IMPLEMENTATION:-}
REVISION=${FLYOLOGY_S3_SERVER_REVISION:-}
if [ -z "$IMPLEMENTATION" ] || [ -z "$REVISION" ]; then
  echo "provider implementation and immutable revision evidence are required" >&2
  exit 2
fi

# Provider health endpoints can become live before the signed S3 router has
# completed initialization. Poll only the read-only ListBuckets operation.
# The maintained 200 x 50 ms window matches the repository's authenticated
# test readiness geometry; it is not DB mutation retry or deadline policy.
READY_STATUS=""
for READY_ATTEMPT in $(seq 1 200)
do
  READY_STATUS=$(curl --silent --show-error \
    --output /dev/null --write-out '%{http_code}' \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    --user "$ACCESS_KEY:$SECRET_KEY" \
    --request GET "$ENDPOINT/" || true)
  if [ "$READY_STATUS" = 200 ]; then
    break
  fi
  if [ "$READY_ATTEMPT" -eq 200 ]; then
    echo "signed S3 readiness did not reach HTTP 200 (last=$READY_STATUS)" >&2
    exit 1
  fi
  sleep 0.05
done

echo "Flyology.DB S3 provider slice: $IMPLEMENTATION bucket=$BUCKET-db"
"$PROJECT_ROOT/tests/bin/flyology-db-client-probe" \
  "$ENDPOINT" "$BUCKET-db" "$ACCESS_KEY" "$SECRET_KEY"
AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  "$PROJECT_ROOT/showcases/bin/flyology_db_object_storage_e2e" \
    "$ENDPOINT" "$BUCKET-db" "walkthrough" "us-east-1" "path" "10"

echo "Flyology.DB S3 provider slice: $IMPLEMENTATION at $REVISION: OK"
