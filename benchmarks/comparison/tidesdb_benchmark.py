#!/usr/bin/env python3
"""Direct pinned TidesDB durable-transaction benchmark participant."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "oracles" / "adapters" / "tidesdb"
sys.path.insert(0, str(ADAPTER))

from adapter import SUCCESS, TidesLibrary, bytes_argument  # noqa: E402


MAXIMUM_OPERATIONS = 10_000
MAXIMUM_KEY_BYTES = 256
MAXIMUM_VALUE_BYTES = 64 * 1024
MAXIMUM_MUTATIONS = 256
SNAPSHOT_ISOLATION = 3


def require_success(code: int, context: str) -> None:
    if code != SUCCESS:
        raise RuntimeError(f"{context} failed with TidesDB code {code}")


def key_for(index: int, length: int) -> bytes:
    return index.to_bytes(length, "big")


def value_for(index: int, length: int) -> bytes:
    return bytes((index + position * 31) % 256 for position in range(1, length + 1))


def open_database(api: object, root: Path, *, create: bool) -> tuple[ctypes.c_void_p, ctypes.c_void_p]:
    if create:
        root.mkdir(mode=0o755)
    database = ctypes.c_void_p()
    require_success(
        api.flyology_tidesdb_open(str(root).encode(), ctypes.byref(database)),
        "open database",
    )
    family = api.tidesdb_get_column_family(database, b"data")
    if not family and create:
        require_success(api.flyology_tidesdb_create_column_family(database, b"data"), "create family")
        family = api.tidesdb_get_column_family(database, b"data")
    if not family:
        raise RuntimeError("data family is absent")
    return database, ctypes.c_void_p(family)


# website-benchmark:start tidesdb-durable-transaction
def put_transaction(
    api: object,
    database: ctypes.c_void_p,
    family: ctypes.c_void_p,
    index: int,
    key_bytes: int,
    value_bytes: int,
    mutations: int,
) -> None:
    transaction = ctypes.c_void_p()
    require_success(
        api.tidesdb_txn_begin_with_isolation(
            database, SNAPSHOT_ISOLATION, ctypes.byref(transaction)
        ),
        "begin transaction",
    )
    try:
        for mutation in range(1, mutations + 1):
            key_index = (index - 1) * mutations + mutation
            key_storage, key_pointer = bytes_argument(key_for(key_index, key_bytes))
            value_storage, value_pointer = bytes_argument(value_for(key_index, value_bytes))
            require_success(
                api.tidesdb_txn_put(
                    transaction,
                    family,
                    key_pointer,
                    key_bytes,
                    value_pointer,
                    value_bytes,
                    0,
                ),
                "put",
            )
            del key_storage, value_storage
        require_success(api.tidesdb_txn_commit(transaction), "durable commit")
    finally:
        api.tidesdb_txn_free(transaction)
# website-benchmark:end tidesdb-durable-transaction


def verify_one(
    api: object,
    database: ctypes.c_void_p,
    family: ctypes.c_void_p,
    index: int,
    key_bytes: int,
    value_bytes: int,
) -> tuple[bytes, bytes]:
    transaction = ctypes.c_void_p()
    require_success(
        api.tidesdb_txn_begin_with_isolation(
            database, SNAPSHOT_ISOLATION, ctypes.byref(transaction)
        ),
        "verification begin",
    )
    key = key_for(index, key_bytes)
    key_storage, key_pointer = bytes_argument(key)
    value_pointer = ctypes.c_void_p()
    value_size = ctypes.c_size_t()
    try:
        require_success(
            api.tidesdb_txn_get(
                transaction,
                family,
                key_pointer,
                key_bytes,
                ctypes.byref(value_pointer),
                ctypes.byref(value_size),
            ),
            "verification get",
        )
        actual = ctypes.string_at(value_pointer, value_size.value)
        if actual != value_for(index, value_bytes):
            raise RuntimeError(f"value {index} differs after reopen")
        require_success(api.tidesdb_txn_rollback(transaction), "verification rollback")
    finally:
        del key_storage
        if value_pointer.value:
            api.tidesdb_free(value_pointer)
        api.tidesdb_txn_free(transaction)
    return key, actual


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--warmup", type=int, required=True)
    parser.add_argument("--measured", type=int, required=True)
    parser.add_argument("--key-bytes", type=int, required=True)
    parser.add_argument("--value-bytes", type=int, required=True)
    parser.add_argument("--mutations", type=int, required=True)
    arguments = parser.parse_args()
    total = arguments.warmup + arguments.measured
    if arguments.warmup < 0 or arguments.measured <= 0 or not 0 < total <= MAXIMUM_OPERATIONS:
        parser.error("operation geometry is outside the benchmark fixture limit")
    if (
        not 8 <= arguments.key_bytes <= MAXIMUM_KEY_BYTES
        or not 1 <= arguments.value_bytes <= MAXIMUM_VALUE_BYTES
        or not 1 <= arguments.mutations <= MAXIMUM_MUTATIONS
    ):
        parser.error("workload geometry is outside the benchmark fixture limit")

    api = TidesLibrary(arguments.library).lib
    database, family = open_database(api, arguments.root, create=True)
    for index in range(1, arguments.warmup + 1):
        put_transaction(
            api,
            database,
            family,
            index,
            arguments.key_bytes,
            arguments.value_bytes,
            arguments.mutations,
        )
    started = time.perf_counter_ns()
    for index in range(arguments.warmup + 1, total + 1):
        put_transaction(
            api,
            database,
            family,
            index,
            arguments.key_bytes,
            arguments.value_bytes,
            arguments.mutations,
        )
    elapsed = time.perf_counter_ns() - started
    require_success(api.tidesdb_close(database), "close database")

    database, family = open_database(api, arguments.root, create=False)
    state = hashlib.sha256()
    total_keys = total * arguments.mutations
    for index in range(1, total_keys + 1):
        key, value = verify_one(
            api,
            database,
            family,
            index,
            arguments.key_bytes,
            arguments.value_bytes,
        )
        state.update(key)
        state.update(value)
    require_success(api.tidesdb_close(database), "close reopened database")
    print(f"elapsed_nanoseconds={elapsed}")
    print(f"verified_keys={total_keys}")
    print(f"state_sha256={state.hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
