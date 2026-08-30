#!/usr/bin/env python3
"""Direct pinned TidesDB durable-transaction benchmark participant."""

from __future__ import annotations

import argparse
import ctypes
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "oracles" / "adapters" / "tidesdb"
sys.path.insert(0, str(ADAPTER))

from adapter import SUCCESS, TidesLibrary, bytes_argument  # noqa: E402


VALUE_BYTES = 1024
MAXIMUM_OPERATIONS = 10_000
SNAPSHOT_ISOLATION = 3


def require_success(code: int, context: str) -> None:
    if code != SUCCESS:
        raise RuntimeError(f"{context} failed with TidesDB code {code}")


def key_for(index: int) -> bytes:
    return index.to_bytes(16, "big")


def value_for(index: int) -> bytes:
    return bytes((index + position * 31) % 256 for position in range(1, VALUE_BYTES + 1))


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


def put_one(api: object, database: ctypes.c_void_p, family: ctypes.c_void_p, index: int) -> None:
    transaction = ctypes.c_void_p()
    require_success(
        api.tidesdb_txn_begin_with_isolation(
            database, SNAPSHOT_ISOLATION, ctypes.byref(transaction)
        ),
        "begin transaction",
    )
    key_storage, key_pointer = bytes_argument(key_for(index))
    value_storage, value_pointer = bytes_argument(value_for(index))
    try:
        require_success(
            api.tidesdb_txn_put(
                transaction,
                family,
                key_pointer,
                16,
                value_pointer,
                VALUE_BYTES,
                0,
            ),
            "put",
        )
        require_success(api.tidesdb_txn_commit(transaction), "durable commit")
    finally:
        del key_storage, value_storage
        api.tidesdb_txn_free(transaction)


def verify_one(api: object, database: ctypes.c_void_p, family: ctypes.c_void_p, index: int) -> None:
    transaction = ctypes.c_void_p()
    require_success(
        api.tidesdb_txn_begin_with_isolation(
            database, SNAPSHOT_ISOLATION, ctypes.byref(transaction)
        ),
        "verification begin",
    )
    key_storage, key_pointer = bytes_argument(key_for(index))
    value_pointer = ctypes.c_void_p()
    value_size = ctypes.c_size_t()
    try:
        require_success(
            api.tidesdb_txn_get(
                transaction,
                family,
                key_pointer,
                16,
                ctypes.byref(value_pointer),
                ctypes.byref(value_size),
            ),
            "verification get",
        )
        actual = ctypes.string_at(value_pointer, value_size.value)
        if actual != value_for(index):
            raise RuntimeError(f"value {index} differs after reopen")
        require_success(api.tidesdb_txn_rollback(transaction), "verification rollback")
    finally:
        del key_storage
        if value_pointer.value:
            api.tidesdb_free(value_pointer)
        api.tidesdb_txn_free(transaction)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--warmup", type=int, required=True)
    parser.add_argument("--measured", type=int, required=True)
    arguments = parser.parse_args()
    total = arguments.warmup + arguments.measured
    if arguments.warmup < 0 or arguments.measured <= 0 or not 0 < total <= MAXIMUM_OPERATIONS:
        parser.error("operation geometry is outside the benchmark fixture limit")

    api = TidesLibrary(arguments.library).lib
    database, family = open_database(api, arguments.root, create=True)
    for index in range(1, arguments.warmup + 1):
        put_one(api, database, family, index)
    started = time.perf_counter_ns()
    for index in range(arguments.warmup + 1, total + 1):
        put_one(api, database, family, index)
    elapsed = time.perf_counter_ns() - started
    require_success(api.tidesdb_close(database), "close database")

    database, family = open_database(api, arguments.root, create=False)
    for index in range(1, total + 1):
        verify_one(api, database, family, index)
    require_success(api.tidesdb_close(database), "close reopened database")
    print(f"elapsed_nanoseconds={elapsed}")
    print(f"verified_keys={total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
