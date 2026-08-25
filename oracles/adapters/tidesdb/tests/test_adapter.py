from __future__ import annotations

import base64
import ctypes
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

ADAPTER_ROOT = Path(__file__).resolve().parents[1]
CANONICAL_VECTORS = ADAPTER_ROOT.parents[1] / "contract" / "canonical_state_vectors.json"
RUNNER = ADAPTER_ROOT / "scripts" / "run.sh"
sys.path.insert(0, str(ADAPTER_ROOT))

from adapter import (  # noqa: E402
    Adapter,
    ERR_BUSY,
    ERR_CORRUPTION,
    ERR_INVALID_ARGS,
    ERR_IO,
    ERR_MEMORY,
    MAX_PATH_BYTES,
    MAX_SAVEPOINTS_PER_TRANSACTION,
    MAX_VALUE_BYTES,
    RequestError,
    TIDES_FAMILY_PATH_RESERVE,
    TIDES_PATH_SUFFIX_RESERVE,
    canonical_digest,
    encode_storage_path,
)


def encoded(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


class Protocol:
    def __init__(self) -> None:
        self.process = subprocess.Popen(
            [str(RUNNER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.request_id = 0
        # run.sh validates/builds the pinned adapter before exec.  A test that
        # uses only pure helpers can otherwise finish and close stdin while the
        # child is still in that pre-exec phase, turning ordinary build latency
        # into a false teardown timeout.  The protocol is usable only after one
        # complete request/response handshake; this adds no timing policy.
        self.request("capabilities")

    def request(self, command: str, **fields: Any) -> dict[str, Any]:
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        request_id = self.request_id
        self.request_id += 1
        request = {"request_id": request_id, "command": command, **fields}
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        response_text = self.process.stdout.readline()
        if not response_text:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise AssertionError(f"adapter ended before response: {stderr}")
        response = json.loads(response_text)
        self.assert_request_id(response, request_id)
        return response

    def raw(self, text: str) -> dict[str, Any]:
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(text + "\n")
        self.process.stdin.flush()
        response_text = self.process.stdout.readline()
        if not response_text:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise AssertionError(f"adapter ended before response: {stderr}")
        return json.loads(response_text)

    @staticmethod
    def assert_request_id(response: dict[str, Any], request_id: int) -> None:
        if response.get("request_id") != request_id:
            raise AssertionError(f"response request_id mismatch: {response}")

    def crash(self) -> None:
        assert self.process.stdin is not None
        request = {"request_id": self.request_id, "command": "crash"}
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        self.process.stdin.close()
        self.process.wait(timeout=10)
        if self.process.returncode != 73:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise AssertionError(f"crash exit was {self.process.returncode}: {stderr}")
        self.close_pipes()

    def close_process(self) -> None:
        if self.process.poll() is None:
            if self.process.stdin is not None:
                self.process.stdin.close()
            self.process.wait(timeout=10)
        if self.process.returncode != 0:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise AssertionError(f"adapter exit was {self.process.returncode}: {stderr}")
        self.close_pipes()

    def close_pipes(self) -> None:
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


class TidesDBAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="flyology-tidesdb-test-")
        self.database = str(Path(self.temporary.name) / "database")
        self.families = [
            {"id": "1", "name": "accounts"},
            {"id": "2", "name": "audit"},
        ]
        self.protocol = Protocol()

    def tearDown(self) -> None:
        self.protocol.close_process()
        self.temporary.cleanup()

    def open(self, create: bool = True) -> None:
        response = self.protocol.request(
            "open", path=self.database, create=create, families=self.families
        )
        self.assertEqual(response["outcome"], "Success", response)

    def begin(self, transaction: str, isolation: str = "Snapshot") -> None:
        response = self.protocol.request(
            "begin", transaction=transaction, isolation=isolation
        )
        self.assertEqual(response["outcome"], "Success", response)

    def put(self, transaction: str, family: str, key: bytes, value: bytes) -> None:
        response = self.protocol.request(
            "put",
            transaction=transaction,
            family=family,
            key=encoded(key),
            value=encoded(value),
        )
        self.assertEqual(response["outcome"], "Success", response)

    def commit(self, transaction: str) -> dict[str, Any]:
        return self.protocol.request("commit", transaction=transaction)

    def test_capabilities_fail_closed_for_remote_and_range_serializable(self) -> None:
        response = self.protocol.request("capabilities")
        self.assertEqual(response["outcome"], "Success")
        self.assertFalse(response["remote_durable"])
        self.assertFalse(response["empty_keys"])
        self.assertFalse(response["serializable_range_phantoms"])
        self.assertNotIn("remote_durable", response["capabilities"])
        self.assertEqual(
            response["expected_sha"],
            "23a67a6531bc6c0b537d3696758c7879586dcfce",
        )
        self.assertEqual(response["header_version"], "9.3.14")
        self.assertEqual(response["tag_label"], "v9.3.15")
        self.assertEqual(response["limits"]["result_bytes"], 32 * 1024 * 1024)
        self.assertEqual(
            response["limits"]["savepoints_per_transaction"],
            MAX_SAVEPOINTS_PER_TRANSACTION,
        )

    def test_digest_and_ambiguity_mapping_match_the_contract(self) -> None:
        vectors = json.loads(CANONICAL_VECTORS.read_text(encoding="utf-8"))
        for vector in vectors["vectors"]:
            if vector["ordering"] != "canonical":
                continue
            rows = [
                (
                    item["column_family_id"],
                    bytes.fromhex(item["key"]),
                    bytes.fromhex(item["value"]),
                )
                for item in vector["tuples"]
            ]
            self.assertEqual(canonical_digest(rows), vector["sha256"], vector["name"])
        adapter = object.__new__(Adapter)
        self.assertEqual(adapter.map_code(ERR_IO), "Unsupported")
        self.assertEqual(
            adapter.map_code(ERR_IO, commit_may_be_ambiguous=True),
            "Outcome_Unknown",
        )
        self.assertEqual(
            adapter.map_code(ERR_MEMORY, commit_may_be_ambiguous=True),
            "Outcome_Unknown",
        )
        self.assertEqual(
            adapter.map_code(ERR_CORRUPTION, commit_may_be_ambiguous=True),
            "Outcome_Unknown",
        )
        self.assertEqual(
            adapter.map_code(ERR_INVALID_ARGS, commit_may_be_ambiguous=True),
            "Unsupported",
        )
        self.assertEqual(
            adapter.map_code(ERR_BUSY, commit_may_be_ambiguous=True),
            "Unsupported",
        )
        self.assertEqual(
            adapter.code_response(1, ERR_BUSY)["reason"],
            "engine_backpressure",
        )

    def test_native_family_list_cleanup_precedes_count_validation(self) -> None:
        class OversizedListAPI:
            def __init__(self) -> None:
                self.buffers = [
                    ctypes.create_string_buffer(f"family-{index}".encode("ascii"))
                    for index in range(65)
                ]
                self.array = (ctypes.c_void_p * len(self.buffers))(
                    *(ctypes.addressof(item) for item in self.buffers)
                )
                self.freed: list[int] = []

            def tidesdb_list_column_families(
                self,
                _database: ctypes.c_void_p,
                names: Any,
                count: Any,
            ) -> int:
                names_pointer = ctypes.cast(
                    names,
                    ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)),
                )
                names_pointer[0] = ctypes.cast(
                    self.array,
                    ctypes.POINTER(ctypes.c_void_p),
                )
                ctypes.cast(count, ctypes.POINTER(ctypes.c_int))[0] = len(
                    self.buffers
                )
                return 0

            def tidesdb_free(self, pointer: Any) -> None:
                self.freed.append(
                    pointer.value if isinstance(pointer, ctypes.c_void_p) else pointer
                )

        adapter = object.__new__(Adapter)
        adapter.api = OversizedListAPI()
        adapter.database = ctypes.c_void_p(1)
        with self.assertRaisesRegex(RequestError, "exceeded the adapter limit"):
            adapter.list_family_names()
        expected = [ctypes.addressof(item) for item in adapter.api.buffers]
        expected.append(ctypes.addressof(adapter.api.array))
        self.assertCountEqual(adapter.api.freed, expected)

    def test_native_get_cleanup_precedes_result_validation(self) -> None:
        class OversizedGetAPI:
            def __init__(self) -> None:
                self.buffer = ctypes.create_string_buffer(b"x")
                self.freed: list[int] = []

            def tidesdb_txn_get(
                self,
                _transaction: ctypes.c_void_p,
                _family: ctypes.c_void_p,
                _key: ctypes.c_void_p,
                _key_size: int,
                value: Any,
                value_size: Any,
            ) -> int:
                ctypes.cast(value, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.addressof(
                    self.buffer
                )
                ctypes.cast(value_size, ctypes.POINTER(ctypes.c_size_t))[0] = (
                    MAX_VALUE_BYTES + 1
                )
                return 0

            def tidesdb_free(self, pointer: ctypes.c_void_p) -> None:
                self.freed.append(pointer.value)

        adapter = object.__new__(Adapter)
        adapter.api = OversizedGetAPI()
        adapter.transactions = {"t": (ctypes.c_void_p(1), "Snapshot")}
        adapter.families = {"1": ctypes.c_void_p(2)}
        with self.assertRaisesRegex(RequestError, "stored value exceeds"):
            adapter.get(
                {"transaction": "t", "family": "1", "key": encoded(b"key")},
                request_id=1,
            )
        self.assertEqual(adapter.api.freed, [ctypes.addressof(adapter.api.buffer)])

    def test_storage_path_bounds_accept_equality_and_reject_one_over(self) -> None:
        root_length = MAX_PATH_BYTES - 1 - TIDES_PATH_SUFFIX_RESERVE
        self.assertEqual(
            len(encode_storage_path("r" * root_length, "path", [])),
            root_length,
        )
        with self.assertRaisesRegex(RequestError, "root suffixes"):
            encode_storage_path("r" * (root_length + 1), "path", [])

        family = "accounts"
        family_length = (
            MAX_PATH_BYTES - 1 - len(family) - TIDES_FAMILY_PATH_RESERVE
        )
        for field in ("path", "checkpoint path"):
            with self.subTest(field=field):
                self.assertEqual(
                    len(encode_storage_path("f" * family_length, field, [family])),
                    family_length,
                )
                with self.assertRaisesRegex(RequestError, "family paths"):
                    encode_storage_path("f" * (family_length + 1), field, [family])

    def test_cross_family_commit_savepoint_scan_and_reopen(self) -> None:
        self.open()
        self.begin("t1")
        self.put("t1", "1", b"a", b"1")
        self.assertEqual(
            self.protocol.request("savepoint", transaction="t1", name="before-audit")["outcome"],
            "Success",
        )
        self.put("t1", "2", b"a", b"discard")
        self.assertEqual(
            self.protocol.request("rollback_to", transaction="t1", name="before-audit")["outcome"],
            "Success",
        )
        self.put("t1", "2", b"a", b"created")
        get = self.protocol.request(
            "get", transaction="t1", family="1", key=encoded(b"a")
        )
        self.assertEqual(get["value"], encoded(b"1"))
        scan = self.protocol.request(
            "scan",
            transaction="t1",
            family="1",
            lower=encoded(b""),
            upper=encoded(b"z"),
            maximum=10,
        )
        self.assertEqual(scan["rows"], [{"key": encoded(b"a"), "value": encoded(b"1")}])
        self.assertEqual(self.commit("t1")["outcome"], "Success")
        first = self.protocol.request("state")
        self.assertEqual(
            first["tuples"],
            [
                {"family": "1", "key": encoded(b"a"), "value": encoded(b"1")},
                {"family": "2", "key": encoded(b"a"), "value": encoded(b"created")},
            ],
        )
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")
        self.open(create=False)
        reopened = self.protocol.request("state")
        self.assertEqual(reopened["digest"], first["digest"])
        self.assertEqual(reopened["tuples"], first["tuples"])
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")

    def test_snapshot_conflict_and_serializable_point_conflict_mapping(self) -> None:
        self.open()
        self.begin("seed")
        self.put("seed", "1", b"watched", b"0")
        self.assertEqual(self.commit("seed")["outcome"], "Success")

        self.begin("left")
        self.begin("right")
        self.put("left", "1", b"same", b"left")
        self.put("right", "1", b"same", b"right")
        self.assertEqual(self.commit("left")["outcome"], "Success")
        self.assertEqual(self.commit("right")["outcome"], "Conflict")
        self.assertEqual(
            self.protocol.request("rollback", transaction="right")["outcome"],
            "Success",
        )

        self.begin("reader", "Serializable")
        read = self.protocol.request(
            "get", transaction="reader", family="1", key=encoded(b"watched")
        )
        self.assertEqual(read["outcome"], "Success")
        self.begin("writer")
        self.put("writer", "1", b"watched", b"1")
        self.assertEqual(self.commit("writer")["outcome"], "Success")
        self.put("reader", "1", b"other", b"x")
        self.assertEqual(self.commit("reader")["outcome"], "Serialization_Failure")
        self.assertEqual(
            self.protocol.request("rollback", transaction="reader")["outcome"],
            "Success",
        )
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")

    def test_abrupt_exit_recovers_successful_unified_full_sync_commit(self) -> None:
        self.open()
        self.begin("durable")
        self.put("durable", "1", b"a", b"1")
        self.put("durable", "2", b"a", b"audit")
        self.assertEqual(self.commit("durable")["outcome"], "Success")
        self.protocol.crash()

        self.protocol = Protocol()
        self.open(create=False)
        state = self.protocol.request("state")
        self.assertEqual(
            state["tuples"],
            [
                {"family": "1", "key": encoded(b"a"), "value": encoded(b"1")},
                {"family": "2", "key": encoded(b"a"), "value": encoded(b"audit")},
            ],
        )
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")

    def test_malformed_request_gets_one_typed_response(self) -> None:
        response = self.protocol.request("unknown")
        self.assertEqual(response["outcome"], "Unsupported")
        self.assertIn("unsupported command", response["detail"])
        extra = self.protocol.request("capabilities", unexpected=True)
        self.assertEqual(extra["outcome"], "Unsupported")
        self.assertIn("unsupported fields", extra["detail"])
        duplicate = self.protocol.raw(
            '{"request_id":1,"request_id":2,"command":"capabilities"}'
        )
        self.assertIsNone(duplicate["request_id"])
        self.assertEqual(duplicate["outcome"], "Unsupported")
        self.assertIn("duplicate JSON member", duplicate["detail"])
        null_path = self.protocol.request(
            "open",
            path=self.database + "\0suffix",
            create=True,
            families=self.families,
        )
        self.assertEqual(null_path["outcome"], "Unsupported")
        self.assertIn("null byte", null_path["detail"])
        self.assertFalse(Path(self.database).exists())

        oversized_integer = self.protocol.raw(
            '{"request_id":18446744073709551616,"command":"capabilities"}'
        )
        self.assertIsNone(oversized_integer["request_id"])
        self.assertEqual(oversized_integer["outcome"], "Unsupported")
        self.assertIn("integer exceeds", oversized_integer["detail"])

        nonfinite = self.protocol.raw(
            '{"request_id":1,"command":"capabilities","unexpected":NaN}'
        )
        self.assertIsNone(nonfinite["request_id"])
        self.assertEqual(nonfinite["outcome"], "Unsupported")
        self.assertIn("non-finite JSON number", nonfinite["detail"])

    def test_family_path_components_are_rejected_before_create(self) -> None:
        for name in (".", "..", "nested/family", "back\\slash"):
            with self.subTest(name=name):
                response = self.protocol.request(
                    "open",
                    path=self.database,
                    create=True,
                    families=[{"id": "1", "name": name}],
                )
                self.assertEqual(response["outcome"], "Unsupported", response)
                self.assertIn("family name", response["detail"])
                self.assertFalse(Path(self.database).exists())

    def test_reserved_tides_root_names_are_rejected_before_create(self) -> None:
        for name in (
            "LOCK",
            "lock",
            "LOG",
            "UNIMAP",
            "UNIMAP.tmp",
            "uwal_0.log",
            "replica_wal_tmp.log",
            "primary_lease_tmp",
            "fence_probe_tmp",
        ):
            with self.subTest(name=name):
                response = self.protocol.request(
                    "open",
                    path=self.database,
                    create=True,
                    families=[{"id": "1", "name": name}],
                )
                self.assertEqual(response["outcome"], "Unsupported", response)
                self.assertIn("reserved TidesDB root", response["detail"])
                self.assertEqual(list(Path(self.temporary.name).iterdir()), [])

    def test_noncanonical_or_out_of_range_family_ids_are_effect_free(self) -> None:
        for family_id in (
            "0",
            "01",
            "4294967296",
            "9" * 4_096,
            "-1",
            "+1",
        ):
            with self.subTest(family_id=family_id):
                response = self.protocol.request(
                    "open",
                    path=self.database,
                    create=True,
                    families=[{"id": family_id, "name": "accounts"}],
                )
                self.assertEqual(response["outcome"], "Unsupported", response)
                self.assertIn("family ID", response["detail"])
                self.assertEqual(list(Path(self.temporary.name).iterdir()), [])
        self.families = [{"id": "4294967295", "name": "maximum"}]
        self.open()
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")

    def test_database_and_checkpoint_paths_reserve_constructed_suffixes(self) -> None:
        family_name = "accounts"
        rejected_length = (
            4095 - 1 - len(family_name) - TIDES_FAMILY_PATH_RESERVE + 1
        )
        long_database = self.database + "x" * (rejected_length - len(self.database))
        response = self.protocol.request(
            "open",
            path=long_database,
            create=True,
            families=[{"id": "1", "name": family_name}],
        )
        self.assertEqual(response["outcome"], "Unsupported", response)
        self.assertIn("family paths", response["detail"])
        self.assertEqual(list(Path(self.temporary.name).iterdir()), [])

        self.open()
        long_checkpoint = self.database + "x" * (
            rejected_length - len(self.database)
        )
        checkpoint = self.protocol.request("checkpoint", path=long_checkpoint)
        self.assertEqual(checkpoint["outcome"], "Unsupported", checkpoint)
        self.assertIn("family paths", checkpoint["detail"])
        self.assertEqual(
            [entry.name for entry in Path(self.temporary.name).iterdir()],
            ["database"],
        )
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")

    def test_busy_commit_consumes_transaction_and_fences_until_reopen(self) -> None:
        class BusyAPI:
            def __init__(self) -> None:
                self.freed: list[int | None] = []

            @staticmethod
            def tidesdb_txn_commit(_transaction: ctypes.c_void_p) -> int:
                return ERR_BUSY

            def tidesdb_txn_free(self, transaction: ctypes.c_void_p) -> None:
                self.freed.append(transaction.value)

            @staticmethod
            def tidesdb_close(_database: ctypes.c_void_p) -> int:
                return 0

        adapter = object.__new__(Adapter)
        adapter.api = BusyAPI()
        adapter.transactions = {"busy": (ctypes.c_void_p(1), "Snapshot")}
        adapter.mutation_counts = {"busy": 1}
        adapter.savepoint_counts = {"busy": {}}
        adapter.failed_commit_transactions = set()
        adapter.database_fence_reason = None
        adapter.database = ctypes.c_void_p(2)
        adapter.path = Path("unused")
        adapter.family_names = {}
        adapter.families = {}

        response = adapter.finish_transaction(
            {"transaction": "busy"}, request_id=1, commit=True
        )
        self.assertEqual(response["outcome"], "Unsupported")
        self.assertEqual(response["raw_code"], ERR_BUSY)
        self.assertEqual(
            response["reason"], "engine_backpressure_session_fenced"
        )
        self.assertNotIn("busy", adapter.transactions)
        self.assertIn("busy", adapter.failed_commit_transactions)
        self.assertEqual(adapter.api.freed, [1])
        with self.assertRaises(RequestError):
            adapter.dispatch({"request_id": 2, "command": "state"})

        rollback = adapter.finish_transaction(
            {"transaction": "busy"}, request_id=3, commit=False
        )
        self.assertEqual(rollback["outcome"], "Success")
        self.assertNotIn("busy", adapter.failed_commit_transactions)
        self.assertIsNotNone(adapter.database_fence_reason)

        closed = adapter.close_database(request_id=4)
        self.assertEqual(closed["outcome"], "Success")
        self.assertIsNone(adapter.database_fence_reason)
        self.assertFalse(adapter.database.value)
        class BusyLibrary:
            def __init__(self) -> None:
                self.lib = BusyAPI()

        reopened_session = Adapter(BusyLibrary())
        self.assertIsNone(reopened_session.database_fence_reason)

    def test_open_is_noncreating_and_create_is_exclusive(self) -> None:
        missing = self.protocol.request(
            "open",
            path=self.database,
            create=False,
            families=self.families,
        )
        self.assertEqual(missing["outcome"], "Not_Found")
        self.assertFalse(Path(self.database).exists())
        self.open()
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")
        existing = self.protocol.request(
            "open",
            path=self.database,
            create=True,
            families=self.families,
        )
        self.assertEqual(existing["outcome"], "Conflict")

    def test_native_open_failure_after_directory_reservation_is_not_unsupported(self) -> None:
        class FailingOpenAPI:
            def __init__(self) -> None:
                self.saw_reserved_directory = False

            def flyology_tidesdb_open(
                self,
                path: bytes,
                _handle: Any,
            ) -> int:
                self.saw_reserved_directory = Path(path.decode("utf-8")).is_dir()
                return ERR_IO

        adapter = object.__new__(Adapter)
        adapter.api = FailingOpenAPI()
        adapter.database = ctypes.c_void_p()
        adapter.database_fence_reason = None
        adapter.path = None
        adapter.family_names = {}
        adapter.families = {}
        response = adapter.open_database(
            {
                "path": self.database,
                "create": True,
                "families": [{"id": "1", "name": "accounts"}],
            },
            request_id=1,
        )
        self.assertTrue(adapter.api.saw_reserved_directory)
        self.assertEqual(response["outcome"], "Corrupt", response)
        self.assertEqual(response["raw_code"], ERR_IO)
        self.assertNotEqual(response["outcome"], "Unsupported")
        self.assertTrue(Path(self.database).is_dir())

    def test_duplicate_family_ids_are_rejected_before_create(self) -> None:
        response = self.protocol.request(
            "open",
            path=self.database,
            create=True,
            families=[
                {"id": "1", "name": "first"},
                {"id": "1", "name": "second"},
            ],
        )
        self.assertEqual(response["outcome"], "Unsupported")
        self.assertIn("family ID", response["detail"])
        self.assertFalse(Path(self.database).exists())

    def test_state_orders_u32_family_ids_numerically_before_digesting(self) -> None:
        self.families = [
            {"id": "10", "name": "ten"},
            {"id": "2", "name": "two"},
        ]
        self.open()
        self.begin("numeric-order")
        self.put("numeric-order", "10", b"a", b"ten")
        self.put("numeric-order", "2", b"z", b"two")
        self.assertEqual(self.commit("numeric-order")["outcome"], "Success")
        state = self.protocol.request("state")
        expected_rows = [("2", b"z", b"two"), ("10", b"a", b"ten")]
        self.assertEqual(
            state["tuples"],
            [
                {"family": family, "key": encoded(key), "value": encoded(value)}
                for family, key, value in expected_rows
            ],
        )
        self.assertEqual(state["digest"], canonical_digest(expected_rows))
        self.assertNotEqual(
            state["digest"],
            canonical_digest(sorted(expected_rows, key=lambda row: (row[0], row[1]))),
        )
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")

    def test_savepoint_bound_and_rollback_invalidation_match_the_pin(self) -> None:
        self.open()
        self.begin("bounded")
        for index in range(MAX_SAVEPOINTS_PER_TRANSACTION):
            response = self.protocol.request(
                "savepoint",
                transaction="bounded",
                name=f"s{index}",
            )
            self.assertEqual(response["outcome"], "Success", response)
        updated = self.protocol.request(
            "savepoint", transaction="bounded", name="s0"
        )
        self.assertEqual(updated["outcome"], "Success", updated)
        overflow = self.protocol.request(
            "savepoint", transaction="bounded", name="overflow"
        )
        self.assertEqual(overflow["outcome"], "Unsupported", overflow)
        self.assertIn("savepoint limit", overflow["detail"])
        rolled_back = self.protocol.request(
            "rollback_to", transaction="bounded", name="s0"
        )
        self.assertEqual(rolled_back["outcome"], "Success", rolled_back)
        for invalidated in ("s0", "s1"):
            response = self.protocol.request(
                "rollback_to", transaction="bounded", name=invalidated
            )
            self.assertEqual(response["outcome"], "Unsupported", response)
            self.assertIn("unknown savepoint", response["detail"])
        recreated = self.protocol.request(
            "savepoint", transaction="bounded", name="new"
        )
        self.assertEqual(recreated["outcome"], "Success", recreated)
        self.assertEqual(
            self.protocol.request("rollback", transaction="bounded")["outcome"],
            "Success",
        )
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")

    def test_noncanonical_base64_is_rejected_without_mutating(self) -> None:
        self.open()
        self.begin("invalid")
        response = self.protocol.request(
            "put",
            transaction="invalid",
            family="1",
            key="YR==",
            value=encoded(b"value"),
        )
        self.assertEqual(response["outcome"], "Unsupported")
        self.assertIn("canonical base64", response["detail"])
        self.assertEqual(
            self.protocol.request("rollback", transaction="invalid")["outcome"],
            "Success",
        )
        self.assertEqual(self.protocol.request("state")["tuples"], [])
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")

    def test_empty_key_is_rejected_before_calling_the_engine(self) -> None:
        self.open()
        self.begin("empty-key")
        response = self.protocol.request(
            "put",
            transaction="empty-key",
            family="1",
            key=encoded(b""),
            value=encoded(b"value"),
        )
        self.assertEqual(response["outcome"], "Unsupported")
        self.assertIn("empty keys", response["detail"])
        self.assertEqual(
            self.protocol.request("rollback", transaction="empty-key")["outcome"],
            "Success",
        )
        self.assertEqual(self.protocol.request("state")["tuples"], [])
        self.assertEqual(self.protocol.request("close")["outcome"], "Success")


if __name__ == "__main__":
    unittest.main()
