#!/bin/sh
set -eu

adapter_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$adapter_root/../../.." && pwd)
source_root="$project_root/.deps/slatedb"
toolchain=1.91.1
adapter_target="$project_root/build/oracles/slatedb-adapter"
upstream_target="$project_root/build/oracles/slatedb-upstream"

"$adapter_root/scripts/build.sh" >/dev/null
binary="$adapter_target/debug/flyology-db-slatedb-adapter"
grep -q '"slatedb_commit":"e0161973d8d7ffdede7c44725729838811674e99"' \
  "$adapter_target/provenance.json"
grep -q '"object_store_profile":"local_filesystem_fsync"' \
  "$adapter_target/provenance.json"
grep -q '"receipt_ids":4096' "$adapter_target/provenance.json"
grep -q '"scan_bytes":67108864' "$adapter_target/provenance.json"
grep -q '"state_bytes":67108864' "$adapter_target/provenance.json"
python3 "$project_root/oracles/contract/canonical_state.py" \
  "$project_root/oracles/contract/canonical_state_vectors.json"

rustup run "$toolchain" cargo fmt --manifest-path "$adapter_root/Cargo.toml" -- --check
rustup run "$toolchain" cargo clippy \
  --locked \
  --manifest-path "$adapter_root/Cargo.toml" \
  --target-dir "$adapter_target" \
  --all-targets \
  -- -D warnings
rustup run "$toolchain" cargo test \
  --locked \
  --manifest-path "$adapter_root/Cargo.toml" \
  --target-dir "$adapter_target"
python3 "$adapter_root/tests/test_adapter.py" "$binary"

workload_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-slatedb-workload.XXXXXX")
explicit_unsupported_root=$(mktemp -d \
  "${TMPDIR:-/tmp}/flyology-db-slatedb-explicit-unsupported.XXXXXX")
unsupported_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-slatedb-unsupported.XXXXXX")
trap 'rm -rf "$workload_root" "$explicit_unsupported_root" "$unsupported_root"' \
  EXIT HUP INT TERM

python3 "$adapter_root/run_workload.py" \
  --adapter "$binary" \
  --root "$workload_root" \
  --workload "$adapter_root/tests/fixtures/single_family_read_only_recovery.ndjson"

python3 "$adapter_root/run_workload.py" \
  --adapter "$binary" \
  --root "$explicit_unsupported_root" \
  --workload "$adapter_root/tests/fixtures/unsupported_remote_commit.ndjson"

if python3 "$adapter_root/run_workload.py" \
  --adapter "$binary" \
  --root "$unsupported_root" \
  --workload "$project_root/oracles/workloads/unknown_resolution.ndjson"
then
  printf '%s\n' "unsupported remote workload was accepted" >&2
  exit 1
else
  status=$?
  test "$status" -eq 2
fi
test -z "$(find "$unsupported_root" -mindepth 1 -print -quit)"

(
  cd "$source_root"
  CARGO_TARGET_DIR="$upstream_target" rustup run "$toolchain" cargo check \
    --locked -p slatedb --no-default-features
  CARGO_TARGET_DIR="$upstream_target" rustup run "$toolchain" cargo test \
    --locked -p slatedb --no-default-features --lib db_transaction::tests
  CARGO_TARGET_DIR="$upstream_target" rustup run "$toolchain" cargo test \
    --locked -p slatedb --no-default-features --lib test_should_recover_imm_from_wal
)

printf '%s\n' "SlateDB adapter and pinned upstream gates passed"
