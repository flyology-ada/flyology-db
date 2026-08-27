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

# The local authenticated client gate uses one ephemeral Flyology memory
# server. Fixed credentials, a ten-second readiness window (200 * 50 ms), and
# one fresh process-scoped bucket are test-corpus choices, not DB defaults or
# retry policy.
client_server_dir="$project_root/.deps/flyology-object-storage/server"
client_server_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-client-server.XXXXXX")
client_server_log="$client_server_root/server.log"
client_access_key=FLYOLOGYDBCLIENT
client_secret_key=flyology-db-client-test-secret
client_server_pid=""
cleanup_client_server() {
  if [ -n "$client_server_pid" ] && kill -0 "$client_server_pid" >/dev/null 2>&1; then
    kill -TERM "$client_server_pid" >/dev/null 2>&1 || true
    wait "$client_server_pid" >/dev/null 2>&1 || true
  fi
  case "$client_server_root" in
    "${TMPDIR:-/tmp}"/flyology-db-client-server.*) rm -rf "$client_server_root" ;;
    *) printf '%s\n' "refusing unexpected client-server cleanup path" >&2 ;;
  esac
}
trap cleanup_client_server EXIT HUP INT TERM
(cd "$client_server_dir" && "$alr" build)
env \
  FLYOLOGY_OBJECT_STORAGE_BACKEND=memory \
  FLYOLOGY_ADMIN_CREDENTIALS_FILE="$client_server_root/admin.credentials" \
  FLYOLOGY_ADMIN_ASSET_ROOT="$client_server_dir/assets" \
  FLYOLOGY_S3_PORT=0 \
  FLYOLOGY_ADMIN_PORT=0 \
  AWS_ACCESS_KEY_ID="$client_access_key" \
  AWS_SECRET_ACCESS_KEY="$client_secret_key" \
  AWS_REGION=us-east-1 \
  "$client_server_dir/bin/flyology_object_storage_server" >"$client_server_log" 2>&1 &
client_server_pid=$!
client_port=""
for client_attempt in $(seq 1 200)
do
  client_port=$(sed -n \
    's/^READY s3 http:\/\/[^:]*:\([0-9][0-9]*\) backend=memory$/\1/p' \
    "$client_server_log" | tail -1)
  if [ -n "$client_port" ]; then
    break
  fi
  if ! kill -0 "$client_server_pid" >/dev/null 2>&1; then
    cat "$client_server_log" >&2
    printf '%s\n' "client test server exited before readiness" >&2
    exit 1
  fi
  if [ "$client_attempt" -eq 200 ]; then
    cat "$client_server_log" >&2
    printf '%s\n' "client test server did not become ready" >&2
    exit 1
  fi
  sleep 0.05
done
client_bucket="flyology-db-client-$$"
./bin/flyology-db-client-probe \
  "http://127.0.0.1:$client_port" \
  "$client_bucket" \
  "$client_access_key" \
  "$client_secret_key" \
  "$client_port"
AWS_ACCESS_KEY_ID="$client_access_key" \
AWS_SECRET_ACCESS_KEY="$client_secret_key" \
  "$project_root/showcases/run-object-storage-e2e.sh" \
    "http://127.0.0.1:$client_port" \
    "$client_bucket" \
    "walkthrough" \
    "us-east-1" \
    "path" \
    "10"
kill -TERM "$client_server_pid"
wait "$client_server_pid"
client_server_pid=""
cleanup_client_server
trap - EXIT HUP INT TERM

crash_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-group-crash.XXXXXX")
manifest_orphan_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-manifest-orphan.XXXXXX")
manifest_head_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-manifest-head.XXXXXX")
flush_head_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-flush-head.XXXXXX")
trap 'rm -rf "$crash_root" "$manifest_orphan_root" "$manifest_head_root" "$flush_head_root"' EXIT HUP INT TERM
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
set +e
./bin/flyology-db-files_crash_probe flush-head-crash "$flush_head_root"
flush_head_status=$?
set -e
test "$flush_head_status" -eq 137
./bin/flyology-db-files_crash_probe flush-head-verify "$flush_head_root"
rm -rf "$flush_head_root"
trap - EXIT HUP INT TERM
printf '%s\n' "Flyology.DB files subprocess group, manifest, and Flush crash/recovery passed"
cd "$project_root"
./showcases/run-limited-e2e.sh
./oracles/adapters/tidesdb/scripts/test.sh
printf '%s\n' "Flyology.DB deterministic test suite passed"
