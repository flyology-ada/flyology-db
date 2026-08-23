#!/usr/bin/env python3
"""Pinned TidesDB NDJSON comparative-oracle adapter."""

from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

EXPECTED_SHA = "23a67a6531bc6c0b537d3696758c7879586dcfce"
EXPECTED_HEADER_VERSION = "9.3.14"
MAX_ACTIVE_TRANSACTIONS = 64
MAX_MUTATIONS_PER_TRANSACTION = 4096
MAX_COLUMN_FAMILIES = 64
MAX_KEY_BYTES = 1024 * 1024
MAX_VALUE_BYTES = 16 * 1024 * 1024
MAX_SCAN_ITEMS = 100_000
MAX_RESULT_BYTES = 32 * 1024 * 1024
MAX_REQUEST_BYTES = 24 * 1024 * 1024
MAX_IDENTIFIER_BYTES = 128
MAX_SAVEPOINTS_PER_TRANSACTION = 64
TIDES_PATH_BUFFER_BYTES = 4096
TIDES_PATH_SUFFIX_RESERVE = 32
# /L32P2147483647_18446744073709551615.vlog is the longest family-relative
# form constructible by this pin's bounded level, signed partition, and u64 IDs.
TIDES_FAMILY_PATH_RESERVE = 41
MAX_PATH_BYTES = TIDES_PATH_BUFFER_BYTES - 1
MAX_FAMILY_ID = (1 << 32) - 1
TIDES_RESERVED_ROOT_NAMES = frozenset(
    {
        "fence_probe_tmp",
        "LOCK",
        "LOG",
        "primary_lease_tmp",
        "replica_wal_tmp.log",
        "UNIMAP",
        "UNIMAP.tmp",
    }
)
TIDES_RESERVED_ROOT_PREFIXES = ("uwal_",)
CAPABILITIES = {
    "multi_column_family",
    "snapshot",
    "serializable_point_conflicts",
    "crash_recovery_local",
    "savepoints",
    "bounded_scan",
    "flush",
    "compaction",
    "checkpoint",
}

SUCCESS = 0
ERR_MEMORY = -1
ERR_INVALID_ARGS = -2
ERR_NOT_FOUND = -3
ERR_IO = -4
ERR_CORRUPTION = -5
ERR_EXISTS = -6
ERR_CONFLICT = -7
ERR_BUSY = -14
ERR_UNKNOWN = -11
ISOLATION = {"Snapshot": 3, "Serializable": 4}
COMMAND_FIELDS = {
    "capabilities": (set(), set()),
    "open": ({"path", "create", "families"}, {"path", "create", "families"}),
    "close": (set(), set()),
    "begin": ({"transaction", "isolation"}, {"transaction", "isolation"}),
    "get": ({"transaction", "family", "key"}, {"transaction", "family", "key"}),
    "put": (
        {"transaction", "family", "key", "value"},
        {"transaction", "family", "key", "value"},
    ),
    "delete": ({"transaction", "family", "key"}, {"transaction", "family", "key"}),
    "commit": ({"transaction"}, {"transaction"}),
    "rollback": ({"transaction"}, {"transaction"}),
    "savepoint": ({"transaction", "name"}, {"transaction", "name"}),
    "rollback_to": ({"transaction", "name"}, {"transaction", "name"}),
    "release_savepoint": ({"transaction", "name"}, {"transaction", "name"}),
    "scan": (
        {"transaction", "family", "lower", "upper", "maximum"},
        {"transaction", "family", "lower", "upper", "maximum"},
    ),
    "flush": (set(), set()),
    "compact": (set(), set()),
    "checkpoint": ({"path"}, {"path"}),
    "state": (set(), set()),
    "crash": (set(), set()),
}


class RequestError(Exception):
    """One malformed or unsupported adapter request."""


class AdmittedOpenError(Exception):
    """One open/create failure after the engine may have changed persistent state."""

    def __init__(self, code: int, detail: str) -> None:
        super().__init__(detail)
        self.code = code


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RequestError(message)


def decode_bytes(value: Any, field: str, maximum: int) -> bytes:
    require(isinstance(value, str), f"{field} must be base64")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exc:
        raise RequestError(f"{field} must be canonical base64") from exc
    require(encode_bytes(decoded) == value, f"{field} must be canonical base64")
    require(len(decoded) <= maximum, f"{field} exceeds the adapter limit")
    return decoded


def encode_text(
    value: Any,
    field: str,
    maximum: int,
    *,
    allow_empty: bool = False,
) -> bytes:
    require(isinstance(value, str), f"{field} must be text")
    require(allow_empty or bool(value), f"{field} must be nonempty")
    require("\0" not in value, f"{field} contains a null byte")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise RequestError(f"{field} is not valid Unicode text") from exc
    require(len(encoded) <= maximum, f"{field} exceeds the adapter limit")
    return encoded


def encode_family_name(value: Any) -> bytes:
    encoded = encode_text(value, "family name", MAX_IDENTIFIER_BYTES - 1)
    require(value not in {".", ".."}, "family name is a reserved path component")
    require(
        "/" not in value and "\\" not in value,
        "family name contains a path separator",
    )
    folded = value.casefold()
    require(
        folded not in {name.casefold() for name in TIDES_RESERVED_ROOT_NAMES}
        and not any(
            folded.startswith(prefix.casefold())
            for prefix in TIDES_RESERVED_ROOT_PREFIXES
        ),
        "family name collides with a reserved TidesDB root entry",
    )
    return encoded


def canonical_family_id(value: Any) -> str:
    require(
        isinstance(value, str)
        and value.isascii()
        and value.isdigit()
        and not value.startswith("0"),
        "family ID must be canonical nonzero decimal",
    )
    require(
        len(value) <= 10
        and (len(value) < 10 or value <= str(MAX_FAMILY_ID)),
        "family ID exceeds canonical nonzero u32",
    )
    return value


def encode_storage_path(
    value: Any,
    field: str,
    family_names: list[Any],
) -> bytes:
    encoded = encode_text(value, field, MAX_PATH_BYTES)
    require(
        len(encoded) + 1 + TIDES_PATH_SUFFIX_RESERVE <= MAX_PATH_BYTES,
        f"{field} leaves no room for TidesDB root suffixes",
    )
    for name in family_names:
        family = encode_family_name(name)
        require(
            len(encoded) + 1 + len(family) + TIDES_FAMILY_PATH_RESERVE
            <= MAX_PATH_BYTES,
            f"{field} leaves no room for TidesDB family paths",
        )
    return encoded


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON member {key!r}")
        result[key] = value
    return result


def bounded_json_integer(text: str) -> int:
    digits = text[1:] if text.startswith("-") else text
    require(len(digits) <= 20, "JSON integer exceeds the adapter limit")
    value = int(text)
    require(abs(value) <= (1 << 64) - 1, "JSON integer exceeds the adapter limit")
    return value


def reject_json_constant(text: str) -> Any:
    raise RequestError(f"non-finite JSON number {text!r} is unsupported")


def encode_bytes(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def bytes_argument(value: bytes) -> tuple[Any, ctypes.c_void_p]:
    storage = (ctypes.c_uint8 * max(1, len(value)))()
    if value:
        storage[: len(value)] = value
    return storage, ctypes.cast(storage, ctypes.c_void_p)


def canonical_digest(rows: list[tuple[str, bytes, bytes]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"flyology.db.oracle.state.v1\0")
    for family, key, value in rows:
        family_bytes = family.encode("ascii")
        for part in (family_bytes, key, value):
            digest.update(len(part).to_bytes(8, "big"))
            digest.update(part)
    return digest.hexdigest()


class TidesLibrary:
    """Checked ctypes declarations for the pinned opaque-pointer API."""

    def __init__(self, library_path: Path) -> None:
        self.lib = ctypes.CDLL(str(library_path))
        pointer = ctypes.c_void_p
        size = ctypes.c_size_t

        self.lib.flyology_tidesdb_expected_sha.restype = ctypes.c_char_p
        reported = self.lib.flyology_tidesdb_expected_sha().decode("ascii")
        if reported != EXPECTED_SHA:
            raise RuntimeError(f"shim pin mismatch: expected {EXPECTED_SHA}, found {reported}")
        self.lib.flyology_tidesdb_header_version.restype = ctypes.c_char_p
        version = self.lib.flyology_tidesdb_header_version().decode("ascii")
        if version != EXPECTED_HEADER_VERSION:
            raise RuntimeError(
                f"header version mismatch: expected {EXPECTED_HEADER_VERSION}, found {version}"
            )
        self.lib.flyology_tidesdb_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(pointer)]
        self.lib.flyology_tidesdb_open.restype = ctypes.c_int
        self.lib.flyology_tidesdb_create_column_family.argtypes = [pointer, ctypes.c_char_p]
        self.lib.flyology_tidesdb_create_column_family.restype = ctypes.c_int

        self.lib.tidesdb_close.argtypes = [pointer]
        self.lib.tidesdb_close.restype = ctypes.c_int
        self.lib.tidesdb_get_column_family.argtypes = [pointer, ctypes.c_char_p]
        self.lib.tidesdb_get_column_family.restype = pointer
        self.lib.tidesdb_list_column_families.argtypes = [
            pointer,
            ctypes.POINTER(ctypes.POINTER(pointer)),
            ctypes.POINTER(ctypes.c_int),
        ]
        self.lib.tidesdb_list_column_families.restype = ctypes.c_int
        self.lib.tidesdb_txn_begin_with_isolation.argtypes = [
            pointer,
            ctypes.c_int,
            ctypes.POINTER(pointer),
        ]
        self.lib.tidesdb_txn_begin_with_isolation.restype = ctypes.c_int
        self.lib.tidesdb_txn_put.argtypes = [
            pointer,
            pointer,
            pointer,
            size,
            pointer,
            size,
            ctypes.c_long,
        ]
        self.lib.tidesdb_txn_put.restype = ctypes.c_int
        self.lib.tidesdb_txn_get.argtypes = [
            pointer,
            pointer,
            pointer,
            size,
            ctypes.POINTER(pointer),
            ctypes.POINTER(size),
        ]
        self.lib.tidesdb_txn_get.restype = ctypes.c_int
        self.lib.tidesdb_txn_delete.argtypes = [pointer, pointer, pointer, size]
        self.lib.tidesdb_txn_delete.restype = ctypes.c_int
        self.lib.tidesdb_txn_commit.argtypes = [pointer]
        self.lib.tidesdb_txn_commit.restype = ctypes.c_int
        self.lib.tidesdb_txn_rollback.argtypes = [pointer]
        self.lib.tidesdb_txn_rollback.restype = ctypes.c_int
        self.lib.tidesdb_txn_free.argtypes = [pointer]
        self.lib.tidesdb_txn_free.restype = None
        self.lib.tidesdb_txn_savepoint.argtypes = [pointer, ctypes.c_char_p]
        self.lib.tidesdb_txn_savepoint.restype = ctypes.c_int
        self.lib.tidesdb_txn_rollback_to_savepoint.argtypes = [pointer, ctypes.c_char_p]
        self.lib.tidesdb_txn_rollback_to_savepoint.restype = ctypes.c_int
        self.lib.tidesdb_txn_release_savepoint.argtypes = [pointer, ctypes.c_char_p]
        self.lib.tidesdb_txn_release_savepoint.restype = ctypes.c_int
        self.lib.tidesdb_iter_new.argtypes = [pointer, pointer, ctypes.POINTER(pointer)]
        self.lib.tidesdb_iter_new.restype = ctypes.c_int
        self.lib.tidesdb_iter_seek.argtypes = [pointer, pointer, size]
        self.lib.tidesdb_iter_seek.restype = ctypes.c_int
        self.lib.tidesdb_iter_seek_to_first.argtypes = [pointer]
        self.lib.tidesdb_iter_seek_to_first.restype = ctypes.c_int
        self.lib.tidesdb_iter_next.argtypes = [pointer]
        self.lib.tidesdb_iter_next.restype = ctypes.c_int
        self.lib.tidesdb_iter_valid.argtypes = [pointer]
        self.lib.tidesdb_iter_valid.restype = ctypes.c_int
        self.lib.tidesdb_iter_key_value.argtypes = [
            pointer,
            ctypes.POINTER(pointer),
            ctypes.POINTER(size),
            ctypes.POINTER(pointer),
            ctypes.POINTER(size),
        ]
        self.lib.tidesdb_iter_key_value.restype = ctypes.c_int
        self.lib.tidesdb_iter_free.argtypes = [pointer]
        self.lib.tidesdb_iter_free.restype = None
        self.lib.tidesdb_flush_memtable.argtypes = [pointer]
        self.lib.tidesdb_flush_memtable.restype = ctypes.c_int
        self.lib.tidesdb_compact.argtypes = [pointer]
        self.lib.tidesdb_compact.restype = ctypes.c_int
        self.lib.tidesdb_checkpoint.argtypes = [pointer, ctypes.c_char_p]
        self.lib.tidesdb_checkpoint.restype = ctypes.c_int
        self.lib.tidesdb_free.argtypes = [pointer]
        self.lib.tidesdb_free.restype = None


class Adapter:
    def __init__(self, library: TidesLibrary) -> None:
        self.api = library.lib
        self.database = ctypes.c_void_p()
        self.path: Path | None = None
        self.family_names: dict[str, str] = {}
        self.families: dict[str, ctypes.c_void_p] = {}
        self.transactions: dict[str, tuple[ctypes.c_void_p, str]] = {}
        self.mutation_counts: dict[str, int] = {}
        self.savepoint_counts: dict[str, dict[str, int]] = {}
        self.failed_commit_transactions: set[str] = set()
        self.database_fence_reason: str | None = None

    def response(self, request_id: Any, outcome: str, **fields: Any) -> dict[str, Any]:
        return {"request_id": request_id, "outcome": outcome, **fields}

    def map_code(
        self,
        code: int,
        isolation: str | None = None,
        commit_may_be_ambiguous: bool = False,
    ) -> str:
        if code == SUCCESS:
            return "Success"
        if code == ERR_CONFLICT:
            return "Serialization_Failure" if isolation == "Serializable" else "Conflict"
        if commit_may_be_ambiguous and code not in {
            ERR_INVALID_ARGS,
            ERR_NOT_FOUND,
            ERR_EXISTS,
            ERR_BUSY,
        }:
            return "Outcome_Unknown"
        if code == ERR_NOT_FOUND:
            return "Not_Found"
        if code == ERR_EXISTS:
            return "Conflict"
        if code == ERR_CORRUPTION:
            return "Corrupt"
        return "Unsupported"

    def code_response(
        self,
        request_id: Any,
        code: int,
        isolation: str | None = None,
        commit_may_be_ambiguous: bool = False,
    ) -> dict[str, Any]:
        fields: dict[str, Any] = {"raw_code": code}
        if code == ERR_BUSY:
            fields["reason"] = "engine_backpressure"
        return self.response(
            request_id,
            self.map_code(code, isolation, commit_may_be_ambiguous),
            **fields,
        )

    def admitted_effect_response(
        self,
        request_id: Any,
        code: int,
        reason: str,
    ) -> dict[str, Any]:
        if code == SUCCESS:
            return self.code_response(request_id, code)
        return self.response(
            request_id,
            "Corrupt",
            raw_code=code,
            reason=reason,
        )

    def require_open(self) -> None:
        require(bool(self.database.value), "database is not open")

    def family(self, family_id: Any) -> ctypes.c_void_p:
        require(isinstance(family_id, str) and family_id in self.families, "unknown column family")
        return self.families[family_id]

    def transaction(self, transaction_id: Any) -> tuple[ctypes.c_void_p, str]:
        require(
            isinstance(transaction_id, str) and transaction_id in self.transactions,
            "unknown transaction",
        )
        return self.transactions[transaction_id]

    def open_database(self, request: dict[str, Any], request_id: Any) -> dict[str, Any]:
        require(not self.database.value, "database is already open")
        path = request.get("path")
        families = request.get("families")
        require(
            isinstance(families, list) and 0 < len(families) <= MAX_COLUMN_FAMILIES,
            "families must be nonempty and bounded",
        )
        create = request.get("create")
        require(isinstance(create, bool), "create must be boolean")
        descriptors: list[tuple[str, str]] = []
        ids: set[str] = set()
        names: set[str] = set()
        for item in families:
            require(
                isinstance(item, dict) and set(item) == {"id", "name"},
                "invalid family descriptor",
            )
            family_id = item["id"]
            name = item["name"]
            canonical_family_id(family_id)
            require(family_id not in ids, "duplicate family ID")
            require(
                isinstance(name, str)
                and bool(name)
                and name not in names,
                "duplicate, empty, or oversized family name",
            )
            encode_family_name(name)
            descriptors.append((family_id, name))
            ids.add(family_id)
            names.add(name)

        encoded_path = encode_storage_path(
            path,
            "path",
            [name for _, name in descriptors],
        )

        path_object = Path(path)
        try:
            path_exists = path_object.exists()
        except OSError as exc:
            raise RequestError(f"path cannot be inspected: {exc}") from exc
        if create and path_exists:
            return self.code_response(request_id, ERR_EXISTS)
        if not create and not path_exists:
            return self.code_response(request_id, ERR_NOT_FOUND)
        if create:
            try:
                path_object.mkdir(mode=0o755)
            except FileExistsError:
                return self.code_response(request_id, ERR_EXISTS)
            except OSError as exc:
                raise RequestError(f"database path cannot be reserved: {exc}") from exc
        handle = ctypes.c_void_p()
        code = self.api.flyology_tidesdb_open(encoded_path, ctypes.byref(handle))
        if code != SUCCESS:
            if handle.value:
                self.api.tidesdb_close(handle)
            return self.response(
                request_id,
                "Corrupt",
                raw_code=code,
                reason="engine_open_failed_after_admission",
            )
        self.database = handle
        self.database_fence_reason = None
        self.path = Path(path)
        try:
            for family_id, name in descriptors:
                encoded = name.encode("utf-8")
                family = self.api.tidesdb_get_column_family(self.database, encoded)
                if not family and create:
                    create_code = self.api.flyology_tidesdb_create_column_family(
                        self.database,
                        encoded,
                    )
                    if create_code not in {SUCCESS, ERR_EXISTS}:
                        raise AdmittedOpenError(
                            create_code,
                            f"create column family failed with {create_code}",
                        )
                    family = self.api.tidesdb_get_column_family(self.database, encoded)
                require(bool(family), f"column family {name!r} is absent")
                self.family_names[family_id] = name
                self.families[family_id] = ctypes.c_void_p(family)
            require(self.list_family_names() == names, "database has an unexpected family set")
        except (AdmittedOpenError, RequestError) as exc:
            close_code = self.api.tidesdb_close(self.database)
            self.database = ctypes.c_void_p()
            self.path = None
            self.family_names.clear()
            self.families.clear()
            raw_code = exc.code if isinstance(exc, AdmittedOpenError) else ERR_CORRUPTION
            response = self.response(
                request_id,
                "Corrupt",
                raw_code=raw_code,
                reason="database_initialization_failed_after_admission",
                detail=str(exc),
            )
            if close_code != SUCCESS:
                response["close_raw_code"] = close_code
            return response
        except Exception:
            self.api.tidesdb_close(self.database)
            self.database = ctypes.c_void_p()
            self.path = None
            self.family_names.clear()
            self.families.clear()
            raise
        return self.code_response(request_id, SUCCESS)

    def list_family_names(self) -> set[str]:
        names = ctypes.POINTER(ctypes.c_void_p)()
        count = ctypes.c_int()
        code = self.api.tidesdb_list_column_families(
            self.database,
            ctypes.byref(names),
            ctypes.byref(count),
        )
        try:
            require(
                code == SUCCESS and 0 <= count.value <= MAX_COLUMN_FAMILIES,
                "column-family listing failed or exceeded the adapter limit",
            )
            require(count.value == 0 or bool(names), "column-family listing returned null")
            result: set[str] = set()
            for index in range(count.value):
                pointer = names[index]
                require(bool(pointer), "column-family listing returned null")
                try:
                    result.add(ctypes.string_at(pointer).decode("utf-8"))
                except UnicodeDecodeError as exc:
                    raise RequestError(
                        "column-family listing contains invalid UTF-8"
                    ) from exc
            require(len(result) == count.value, "column-family listing contains duplicates")
            return result
        finally:
            if names:
                try:
                    for index in range(max(0, count.value)):
                        pointer = names[index]
                        if pointer:
                            self.api.tidesdb_free(pointer)
                finally:
                    self.api.tidesdb_free(ctypes.cast(names, ctypes.c_void_p))

    def close_database(self, request_id: Any) -> dict[str, Any]:
        self.require_open()
        require(
            not self.transactions and not self.failed_commit_transactions,
            "transactions requiring cleanup prevent close",
        )
        code = self.api.tidesdb_close(self.database)
        self.database = ctypes.c_void_p()
        self.database_fence_reason = None
        self.path = None
        self.family_names.clear()
        self.families.clear()
        return self.admitted_effect_response(
            request_id,
            code,
            "engine_close_failed_after_admission",
        )

    def begin(self, request: dict[str, Any], request_id: Any) -> dict[str, Any]:
        self.require_open()
        transaction_id = request.get("transaction")
        isolation = request.get("isolation")
        encode_text(transaction_id, "transaction", MAX_IDENTIFIER_BYTES)
        require(
            transaction_id not in self.transactions
            and transaction_id not in self.failed_commit_transactions,
            "duplicate transaction",
        )
        require(isolation in ISOLATION, "unsupported isolation")
        require(
            len(self.transactions) < MAX_ACTIVE_TRANSACTIONS,
            "active transaction limit reached",
        )
        handle = ctypes.c_void_p()
        code = self.api.tidesdb_txn_begin_with_isolation(
            self.database,
            ISOLATION[isolation],
            ctypes.byref(handle),
        )
        if code == SUCCESS:
            self.transactions[transaction_id] = (handle, isolation)
            self.mutation_counts[transaction_id] = 0
            self.savepoint_counts[transaction_id] = {}
        return self.code_response(request_id, code, isolation)

    def get(self, request: dict[str, Any], request_id: Any) -> dict[str, Any]:
        txn, isolation = self.transaction(request.get("transaction"))
        family = self.family(request.get("family"))
        key = decode_bytes(request.get("key"), "key", MAX_KEY_BYTES)
        require(bool(key), "TidesDB does not support empty keys")
        key_storage, key_pointer = bytes_argument(key)
        value_pointer = ctypes.c_void_p()
        value_size = ctypes.c_size_t()
        code = self.api.tidesdb_txn_get(
            txn,
            family,
            key_pointer,
            len(key),
            ctypes.byref(value_pointer),
            ctypes.byref(value_size),
        )
        del key_storage
        try:
            if code != SUCCESS:
                return self.code_response(request_id, code, isolation)
            require(
                value_size.value <= MAX_VALUE_BYTES,
                "stored value exceeds the adapter limit",
            )
            require(
                value_size.value == 0 or bool(value_pointer),
                "engine returned a null value buffer",
            )
            value = ctypes.string_at(value_pointer, value_size.value)
        finally:
            if value_pointer.value:
                self.api.tidesdb_free(value_pointer)
        return self.code_response(request_id, SUCCESS, isolation) | {"value": encode_bytes(value)}

    def put(self, request: dict[str, Any], request_id: Any) -> dict[str, Any]:
        transaction_id = request.get("transaction")
        txn, isolation = self.transaction(transaction_id)
        require(
            self.mutation_counts[transaction_id] < MAX_MUTATIONS_PER_TRANSACTION,
            "transaction mutation limit reached",
        )
        family = self.family(request.get("family"))
        key = decode_bytes(request.get("key"), "key", MAX_KEY_BYTES)
        require(bool(key), "TidesDB does not support empty keys")
        value = decode_bytes(request.get("value"), "value", MAX_VALUE_BYTES)
        key_storage, key_pointer = bytes_argument(key)
        value_storage, value_pointer = bytes_argument(value)
        code = self.api.tidesdb_txn_put(
            txn, family, key_pointer, len(key), value_pointer, len(value), 0
        )
        del key_storage, value_storage
        if code == SUCCESS:
            self.mutation_counts[transaction_id] += 1
        return self.code_response(request_id, code, isolation)

    def delete(self, request: dict[str, Any], request_id: Any) -> dict[str, Any]:
        transaction_id = request.get("transaction")
        txn, isolation = self.transaction(transaction_id)
        require(
            self.mutation_counts[transaction_id] < MAX_MUTATIONS_PER_TRANSACTION,
            "transaction mutation limit reached",
        )
        family = self.family(request.get("family"))
        key = decode_bytes(request.get("key"), "key", MAX_KEY_BYTES)
        require(bool(key), "TidesDB does not support empty keys")
        key_storage, key_pointer = bytes_argument(key)
        code = self.api.tidesdb_txn_delete(txn, family, key_pointer, len(key))
        del key_storage
        if code == SUCCESS:
            self.mutation_counts[transaction_id] += 1
        return self.code_response(request_id, code, isolation)

    def finish_transaction(
        self,
        request: dict[str, Any],
        request_id: Any,
        commit: bool,
    ) -> dict[str, Any]:
        transaction_id = request.get("transaction")
        if not commit and transaction_id in self.failed_commit_transactions:
            self.failed_commit_transactions.remove(transaction_id)
            return self.code_response(request_id, SUCCESS)
        txn, isolation = self.transaction(transaction_id)
        code = self.api.tidesdb_txn_commit(txn) if commit else self.api.tidesdb_txn_rollback(txn)
        response = self.code_response(
            request_id,
            code,
            isolation,
            commit_may_be_ambiguous=commit,
        )
        consume = (
            not commit
            or code == ERR_BUSY
            or response["outcome"] in {"Success", "Outcome_Unknown"}
        )
        if consume:
            self.api.tidesdb_txn_free(txn)
            del self.transactions[transaction_id]
            del self.mutation_counts[transaction_id]
            del self.savepoint_counts[transaction_id]
        if response["outcome"] == "Outcome_Unknown":
            self.database_fence_reason = "an unresolved commit outcome"
        elif commit and code == ERR_BUSY:
            self.failed_commit_transactions.add(transaction_id)
            self.database_fence_reason = (
                "engine backpressure after write reservation requires reopen"
            )
            response["reason"] = "engine_backpressure_session_fenced"
        return response

    def savepoint(self, request: dict[str, Any], request_id: Any, action: str) -> dict[str, Any]:
        transaction_id = request.get("transaction")
        txn, isolation = self.transaction(transaction_id)
        name = request.get("name")
        encoded = encode_text(name, "savepoint name", MAX_IDENTIFIER_BYTES)
        registry = self.savepoint_counts[transaction_id]
        if action == "savepoint":
            require(
                name in registry or len(registry) < MAX_SAVEPOINTS_PER_TRANSACTION,
                "transaction savepoint limit reached",
            )
        else:
            require(name in registry, "unknown savepoint")
        function = {
            "savepoint": self.api.tidesdb_txn_savepoint,
            "rollback_to": self.api.tidesdb_txn_rollback_to_savepoint,
            "release_savepoint": self.api.tidesdb_txn_release_savepoint,
        }[action]
        code = function(txn, encoded)
        if code == SUCCESS:
            if action == "savepoint":
                registry[name] = self.mutation_counts[transaction_id]
            elif action == "rollback_to":
                self.mutation_counts[transaction_id] = registry[name]
                names = list(registry)
                for invalidated in names[names.index(name) :]:
                    del registry[invalidated]
            else:
                del registry[name]
        return self.code_response(request_id, code, isolation)

    def scan_rows(
        self,
        txn: ctypes.c_void_p,
        family: ctypes.c_void_p,
        lower: bytes,
        upper: bytes | None,
        maximum: int,
        maximum_bytes: int,
        per_row_bytes: int = 0,
    ) -> tuple[int, list[tuple[bytes, bytes]]]:
        iterator = ctypes.c_void_p()
        code = self.api.tidesdb_iter_new(txn, family, ctypes.byref(iterator))
        if code != SUCCESS:
            return code, []
        rows: list[tuple[bytes, bytes]] = []
        used_bytes = 0
        try:
            if lower:
                lower_storage, lower_pointer = bytes_argument(lower)
                code = self.api.tidesdb_iter_seek(iterator, lower_pointer, len(lower))
                del lower_storage
            else:
                code = self.api.tidesdb_iter_seek_to_first(iterator)
            if code == ERR_NOT_FOUND:
                return SUCCESS, []
            if code != SUCCESS:
                return code, []
            while self.api.tidesdb_iter_valid(iterator) and len(rows) < maximum:
                key_pointer = ctypes.c_void_p()
                key_size = ctypes.c_size_t()
                value_pointer = ctypes.c_void_p()
                value_size = ctypes.c_size_t()
                code = self.api.tidesdb_iter_key_value(
                    iterator,
                    ctypes.byref(key_pointer),
                    ctypes.byref(key_size),
                    ctypes.byref(value_pointer),
                    ctypes.byref(value_size),
                )
                if code != SUCCESS:
                    return code, []
                require(
                    key_size.value <= MAX_KEY_BYTES,
                    "stored key exceeds the adapter limit",
                )
                require(
                    key_size.value == 0 or bool(key_pointer),
                    "engine returned a null key buffer",
                )
                key = ctypes.string_at(key_pointer, key_size.value)
                if upper is not None and key >= upper:
                    break
                require(
                    value_size.value <= MAX_VALUE_BYTES,
                    "stored value exceeds the adapter limit",
                )
                require(
                    value_size.value == 0 or bool(value_pointer),
                    "engine returned a null value buffer",
                )
                row_bytes = len(key) + value_size.value + per_row_bytes
                require(
                    row_bytes <= maximum_bytes - used_bytes,
                    "scan result exceeds the adapter byte limit",
                )
                value = ctypes.string_at(value_pointer, value_size.value)
                rows.append((key, value))
                used_bytes += row_bytes
                code = self.api.tidesdb_iter_next(iterator)
                if code == ERR_NOT_FOUND:
                    return SUCCESS, rows
                if code != SUCCESS:
                    return code, []
            return SUCCESS, rows
        finally:
            self.api.tidesdb_iter_free(iterator)

    def scan(self, request: dict[str, Any], request_id: Any) -> dict[str, Any]:
        txn, isolation = self.transaction(request.get("transaction"))
        family = self.family(request.get("family"))
        lower = decode_bytes(request.get("lower"), "lower", MAX_KEY_BYTES)
        upper = decode_bytes(request.get("upper"), "upper", MAX_KEY_BYTES)
        maximum = request.get("maximum")
        require(lower < upper, "scan bounds are empty")
        require(
            isinstance(maximum, int)
            and not isinstance(maximum, bool)
            and 1 <= maximum <= MAX_SCAN_ITEMS,
            "invalid or unbounded maximum",
        )
        code, rows = self.scan_rows(
            txn,
            family,
            lower,
            upper,
            maximum,
            MAX_RESULT_BYTES,
        )
        response = self.code_response(request_id, code, isolation)
        if code == SUCCESS:
            response["rows"] = [
                {"key": encode_bytes(key), "value": encode_bytes(value)}
                for key, value in rows
            ]
        return response

    def every_family(self, request_id: Any, operation: str) -> dict[str, Any]:
        self.require_open()
        for family in self.families.values():
            function = (
                self.api.tidesdb_flush_memtable
                if operation == "flush"
                else self.api.tidesdb_compact
            )
            code = function(family)
            if code != SUCCESS:
                return self.admitted_effect_response(
                    request_id,
                    code,
                    f"engine_{operation}_failed_after_admission",
                )
        return self.code_response(request_id, SUCCESS)

    def state(self, request_id: Any) -> dict[str, Any]:
        self.require_open()
        transaction = ctypes.c_void_p()
        code = self.api.tidesdb_txn_begin_with_isolation(
            self.database,
            ISOLATION["Snapshot"],
            ctypes.byref(transaction),
        )
        if code != SUCCESS:
            return self.code_response(request_id, code, "Snapshot")
        all_rows: list[tuple[str, bytes, bytes]] = []
        result_bytes = 0
        try:
            for family_id, family in self.families.items():
                remaining = MAX_SCAN_ITEMS - len(all_rows)
                family_bytes = len(family_id.encode("ascii"))
                code, rows = self.scan_rows(
                    transaction,
                    family,
                    b"",
                    None,
                    remaining + 1,
                    MAX_RESULT_BYTES - result_bytes,
                    family_bytes,
                )
                if code != SUCCESS:
                    return self.code_response(request_id, code, "Snapshot")
                require(
                    len(rows) <= remaining,
                    "logical state exceeds the adapter enumeration limit",
                )
                all_rows.extend((family_id, key, value) for key, value in rows)
                result_bytes += sum(
                    family_bytes + len(key) + len(value) for key, value in rows
                )
        finally:
            self.api.tidesdb_txn_rollback(transaction)
            self.api.tidesdb_txn_free(transaction)
        all_rows.sort(key=lambda row: (int(row[0]), row[1]))
        return self.code_response(request_id, SUCCESS) | {
            "digest": canonical_digest(all_rows),
            "tuples": [
                {"family": family, "key": encode_bytes(key), "value": encode_bytes(value)}
                for family, key, value in all_rows
            ],
        }

    def dispatch(self, request: dict[str, Any]) -> dict[str, Any] | None:
        require(isinstance(request, dict), "request must be an object")
        require("request_id" in request, "request_id is required")
        request_id = request["request_id"]
        require(
            (isinstance(request_id, str) and bool(request_id))
            or (isinstance(request_id, int) and not isinstance(request_id, bool)),
            "request_id must be a nonempty string or integer",
        )
        if isinstance(request_id, str):
            encode_text(request_id, "request_id", MAX_IDENTIFIER_BYTES)
        command = request.get("command")
        require(isinstance(command, str), "command is required")
        require(command in COMMAND_FIELDS, f"unsupported command {command!r}")
        allowed, required = COMMAND_FIELDS[command]
        supplied = set(request) - {"request_id", "command"}
        require(not required - supplied, f"{command} is missing required fields")
        require(not supplied - allowed, f"{command} has unsupported fields")
        if command not in {"capabilities", "open", "close", "crash", "rollback"}:
            require(
                self.database_fence_reason is None,
                f"{self.database_fence_reason} and fences this database",
            )
        if command == "capabilities":
            return self.response(
                request_id,
                "Success",
                capabilities=sorted(CAPABILITIES),
                expected_sha=EXPECTED_SHA,
                header_version=EXPECTED_HEADER_VERSION,
                tag_label="v9.3.15",
                remote_durable=False,
                empty_keys=False,
                serializable_range_phantoms=False,
                limits={
                    "active_transactions": MAX_ACTIVE_TRANSACTIONS,
                    "mutations_per_transaction": MAX_MUTATIONS_PER_TRANSACTION,
                    "savepoints_per_transaction": MAX_SAVEPOINTS_PER_TRANSACTION,
                    "column_families": MAX_COLUMN_FAMILIES,
                    "key_bytes": MAX_KEY_BYTES,
                    "value_bytes": MAX_VALUE_BYTES,
                    "scan_items": MAX_SCAN_ITEMS,
                    "result_bytes": MAX_RESULT_BYTES,
                },
            )
        if command == "open":
            return self.open_database(request, request_id)
        if command == "close":
            return self.close_database(request_id)
        if command == "begin":
            return self.begin(request, request_id)
        if command == "get":
            return self.get(request, request_id)
        if command == "put":
            return self.put(request, request_id)
        if command == "delete":
            return self.delete(request, request_id)
        if command == "commit":
            return self.finish_transaction(request, request_id, True)
        if command == "rollback":
            return self.finish_transaction(request, request_id, False)
        if command in {"savepoint", "rollback_to", "release_savepoint"}:
            return self.savepoint(request, request_id, command)
        if command == "scan":
            return self.scan(request, request_id)
        if command in {"flush", "compact"}:
            return self.every_family(request_id, command)
        if command == "checkpoint":
            self.require_open()
            path = request.get("path")
            encoded_path = encode_storage_path(
                path,
                "checkpoint path",
                list(self.family_names.values()),
            )
            require(
                self.path is not None and path != str(self.path),
                "checkpoint path is database path",
            )
            checkpoint_path = Path(path)
            try:
                if checkpoint_path.exists():
                    require(checkpoint_path.is_dir(), "checkpoint path is not a directory")
                    if next(checkpoint_path.iterdir(), None) is not None:
                        return self.code_response(request_id, ERR_EXISTS)
            except OSError as exc:
                raise RequestError(f"checkpoint path cannot be inspected: {exc}") from exc
            return self.admitted_effect_response(
                request_id,
                self.api.tidesdb_checkpoint(self.database, encoded_path),
                "engine_checkpoint_failed_after_admission",
            )
        if command == "state":
            return self.state(request_id)
        if command == "crash":
            self.require_open()
            os._exit(73)
        raise AssertionError("validated command has no dispatch branch")

    def abandon(self) -> None:
        for transaction, _ in self.transactions.values():
            self.api.tidesdb_txn_rollback(transaction)
            self.api.tidesdb_txn_free(transaction)
        self.transactions.clear()
        self.mutation_counts.clear()
        self.savepoint_counts.clear()
        self.failed_commit_transactions.clear()
        if self.database.value:
            self.api.tidesdb_close(self.database)
            self.database = ctypes.c_void_p()
            self.database_fence_reason = None


def run(library_path: Path) -> int:
    adapter = Adapter(TidesLibrary(library_path))
    try:
        line_number = 0
        while True:
            raw_line = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
            if not raw_line:
                break
            line_number += 1
            request: Any = None
            try:
                if len(raw_line) > MAX_REQUEST_BYTES:
                    while raw_line and not raw_line.endswith(b"\n"):
                        raw_line = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
                    raise RequestError("request exceeds the adapter line limit")
                line = raw_line.decode("utf-8")
                request = json.loads(
                    line,
                    object_pairs_hook=unique_object,
                    parse_int=bounded_json_integer,
                    parse_constant=reject_json_constant,
                )
                response = adapter.dispatch(request)
            except (
                UnicodeDecodeError,
                json.JSONDecodeError,
                RecursionError,
                RequestError,
            ) as exc:
                response = {
                    "request_id": request.get("request_id") if isinstance(request, dict) else None,
                    "outcome": "Unsupported",
                    "detail": f"line {line_number}: {exc}",
                }
            if response is not None:
                print(json.dumps(response, separators=(",", ":"), sort_keys=True), flush=True)
    finally:
        adapter.abandon()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True, type=Path)
    arguments = parser.parse_args()
    return run(arguments.library)


if __name__ == "__main__":
    raise SystemExit(main())
