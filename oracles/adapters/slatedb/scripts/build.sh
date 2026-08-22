#!/bin/sh
set -eu

adapter_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$adapter_root/../../.." && pwd)
source_root="$project_root/.deps/slatedb"
expected_commit=e0161973d8d7ffdede7c44725729838811674e99
toolchain=1.91.1
target_root="$project_root/build/oracles/slatedb-adapter"

test "$(git -C "$source_root" rev-parse HEAD)" = "$expected_commit"
test -z "$(git -C "$source_root" status --short)"
test "$(rustup run "$toolchain" rustc --version | awk '{print $2}')" = "$toolchain"

rustup run "$toolchain" cargo build \
  --locked \
  --manifest-path "$adapter_root/Cargo.toml" \
  --target-dir "$target_root"

mkdir -p "$target_root"
SLATEDB_COMMIT="$expected_commit" \
RUSTC_VERSION="$(rustup run "$toolchain" rustc --version)" \
CARGO_VERSION="$(rustup run "$toolchain" cargo --version)" \
TARGET_ROOT="$target_root" \
python3 - <<'PY'
import json
import os
from pathlib import Path

artifact = {
    "adapter_limits": {
        "key_bytes": 1048576,
        "mutations_per_transaction": 4096,
        "receipt_ids": 4096,
        "scan_bytes": 67108864,
        "scan_items": 100000,
        "state_bytes": 67108864,
        "state_items": 100000,
        "transactions": 256,
        "value_bytes": 16777216,
    },
    "adapter_protocol": "flyology.db.oracle.adapter.v1",
    "adapter_profile": "debug",
    "cargo": os.environ["CARGO_VERSION"],
    "cargo_features": [],
    "object_store_profile": "local_filesystem_fsync",
    "rustc": os.environ["RUSTC_VERSION"],
    "slatedb_commit": os.environ["SLATEDB_COMMIT"],
    "slatedb_default_features": False,
    "slatedb_version": "0.15.0",
}
path = Path(os.environ["TARGET_ROOT"]) / "provenance.json"
path.write_text(json.dumps(artifact, sort_keys=True, separators=(",", ":")) + "\n")
PY

printf '%s\n' "$target_root/debug/flyology-db-slatedb-adapter"
printf '%s\n' "$target_root/provenance.json"
