#!/usr/bin/env python3
"""Black-box protocol, crash, recovery, and capability tests for the adapter."""

from __future__ import annotations

import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any

ORACLES_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ORACLES_ROOT / "contract"))
sys.path.insert(0, str(ORACLES_ROOT / "adapters/slatedb"))

from canonical_state import canonical_digest  # noqa: E402
from run_workload import WorkloadFailure, check_operation  # noqa: E402

PROTOCOL = "flyology.db.oracle.adapter.v1"
DATABASE_ID = bytes.fromhex("00112233445566778899aabbccddeeff")
TRANSACTION = bytes.fromhex("10112233445566778899aabbccddeeff")
RECEIPT = bytes.fromhex("20112233445566778899aabbccddeeff")


def b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def command(
    binary: Path,
    root: Path,
    database_path: str,
    extra_arguments: list[str] | None = None,
) -> list[str]:
    return [
        str(binary),
        "--root",
        str(root),
        "--database-path",
        database_path,
        *(extra_arguments or []),
    ]


def start(
    binary: Path,
    root: Path,
    database_path: str,
    extra_arguments: list[str] | None = None,
) -> subprocess.Popen[str]:
    return subprocess.Popen(
        command(binary, root, database_path, extra_arguments),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )


def request(process: subprocess.Popen[str], value: dict[str, Any]) -> dict[str, Any]:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    if not line:
        detail = process.stderr.read() if process.stderr is not None else ""
        raise AssertionError(f"adapter exited: {detail}")
    response = json.loads(line)
    assert response["request_id"] == value["request_id"]
    return response


def preflight(
    process: subprocess.Popen[str],
    request_id: str,
    families: list[dict[str, str]] | None = None,
    capabilities: list[str] | None = None,
    database_id: bytes = DATABASE_ID,
) -> dict[str, Any]:
    return request(
        process,
        {
            "request_id": request_id,
            "operation": "preflight",
            "protocol": PROTOCOL,
            "database_id": b64(database_id),
            "limits": {
                "transactions": 4,
                "mutations_per_transaction": 4,
                "key_bytes": 8,
                "value_bytes": 16,
            },
            "column_families": families or [{"id": "1", "name": "default"}],
            "required_capabilities": capabilities or ["snapshot", "crash_recovery"],
        },
    )


def close(process: subprocess.Popen[str]) -> None:
    assert process.stdin is not None
    process.stdin.close()
    assert process.wait(timeout=60) == 0


def digest_tuple(family: str, key: bytes, value: bytes) -> str:
    return canonical_digest(
        [
            {
                "column_family_id": family,
                "key": key.hex(),
                "value": value.hex(),
            }
        ]
    )


def protocol_test(binary: Path, root: Path) -> None:
    database_path = f"flyology-db-{DATABASE_ID.hex()}"
    process = start(binary, root, database_path)
    assert preflight(process, "preflight")["outcome"] == "Success"
    assert request(process, {"request_id": "create", "operation": "create"})["outcome"] == "Success"
    malformed_transaction_requests = [
        {"operation": "begin", "isolation": "Snapshot"},
        {"operation": "get", "column_family_id": "1", "key": b64(b"a")},
        {
            "operation": "put",
            "column_family_id": "1",
            "key": b64(b"a"),
            "value": b64(b"v"),
        },
        {"operation": "delete", "column_family_id": "1", "key": b64(b"a")},
        {
            "operation": "scan",
            "column_family_id": "1",
            "lower": b64(b"a"),
            "upper": b64(b"b"),
            "maximum_items": 1,
        },
        {"operation": "commit", "durability": "local_comparative"},
        {"operation": "rollback"},
    ]
    for position, malformed in enumerate(malformed_transaction_requests):
        response = request(
            process,
            {
                "request_id": f"malformed-transaction-{position}",
                "transaction": b64(TRANSACTION).rstrip("="),
                **malformed,
            },
        )
        assert response["outcome"] == "Unsupported"
        assert response["reason"] == "transaction_id"

    receipt_transaction = bytes.fromhex("a0112233445566778899aabbccddeeff")
    receipt_value = bytes.fromhex("a1112233445566778899aabbccddeeff")
    assert request(
        process,
        {
            "request_id": "receipt-begin",
            "operation": "begin",
            "transaction": b64(receipt_transaction),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    for position, receipt in enumerate((None, b64(receipt_value).rstrip("="))):
        missing_or_invalid = {
            "request_id": f"receipt-rejected-{position}",
            "operation": "commit",
            "transaction": b64(receipt_transaction),
            "durability": "local_comparative",
        }
        if receipt is not None:
            missing_or_invalid["receipt"] = receipt
        response = request(process, missing_or_invalid)
        assert response["outcome"] == "Unsupported"
        assert response["reason"] == "receipt_id"
    assert request(
        process,
        {
            "request_id": "receipt-put-after-rejection",
            "operation": "put",
            "transaction": b64(receipt_transaction),
            "column_family_id": "1",
            "key": b64(b"receipt"),
            "value": b64(b"retained"),
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "receipt-rollback",
            "operation": "rollback",
            "transaction": b64(receipt_transaction),
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "begin",
            "operation": "begin",
            "transaction": b64(TRANSACTION),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    key = b"\x00\xff"
    value = b"\x00value\xff"
    assert request(
        process,
        {
            "request_id": "put",
            "operation": "put",
            "transaction": b64(TRANSACTION),
            "column_family_id": "1",
            "key": b64(key),
            "value": b64(value),
        },
    )["outcome"] == "Success"
    get = request(
        process,
        {
            "request_id": "get",
            "operation": "get",
            "transaction": b64(TRANSACTION),
            "column_family_id": "1",
            "key": b64(key),
        },
    )
    assert get == {"request_id": "get", "outcome": "Success", "value": b64(value)}
    scan = request(
        process,
        {
            "request_id": "scan",
            "operation": "scan",
            "transaction": b64(TRANSACTION),
            "column_family_id": "1",
            "lower": b64(b"\x00"),
            "upper": b64(b"\x01"),
            "maximum_items": 1,
        },
    )
    assert scan["outcome"] == "Success"
    assert scan["items"] == [{"key": b64(key), "value": b64(value)}]
    assert scan["truncated"] is False
    commit = request(
        process,
        {
            "request_id": "commit",
            "operation": "commit",
            "transaction": b64(TRANSACTION),
            "receipt": b64(RECEIPT),
            "durability": "local_comparative",
        },
    )
    assert commit == {
        "request_id": "commit",
        "outcome": "Success",
        "receipt": b64(RECEIPT),
        "durability": "local_comparative",
    }

    serial_reader = bytes.fromhex("60112233445566778899aabbccddeeff")
    concurrent_writer = bytes.fromhex("70112233445566778899aabbccddeeff")
    assert request(
        process,
        {
            "request_id": "serial-begin",
            "operation": "begin",
            "transaction": b64(serial_reader),
            "isolation": "Serializable",
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "serial-read",
            "operation": "get",
            "transaction": b64(serial_reader),
            "column_family_id": "1",
            "key": b64(key),
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "concurrent-begin",
            "operation": "begin",
            "transaction": b64(concurrent_writer),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "concurrent-put",
            "operation": "put",
            "transaction": b64(concurrent_writer),
            "column_family_id": "1",
            "key": b64(key),
            "value": b64(value),
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "concurrent-commit",
            "operation": "commit",
            "transaction": b64(concurrent_writer),
            "receipt": b64(bytes.fromhex("80112233445566778899aabbccddeeff")),
            "durability": "local_comparative",
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "serial-put",
            "operation": "put",
            "transaction": b64(serial_reader),
            "column_family_id": "1",
            "key": b64(key),
            "value": b64(value),
        },
    )["outcome"] == "Success"
    serial_commit = request(
        process,
        {
            "request_id": "serial-commit",
            "operation": "commit",
            "transaction": b64(serial_reader),
            "receipt": b64(bytes.fromhex("90112233445566778899aabbccddeeff")),
            "durability": "local_comparative",
        },
    )
    assert serial_commit["outcome"] == "Serialization_Failure"
    assert serial_commit["engine_error_kind"] == "Transaction"
    assert request(
        process,
        {
            "request_id": "serial-rollback",
            "operation": "rollback",
            "transaction": b64(serial_reader),
        },
    )["outcome"] == "Success"

    state = request(
        process,
        {"request_id": "state", "operation": "state", "durability_barrier": True},
    )
    assert state["digest"] == digest_tuple("1", key, value)
    assert state["tuples"] == [
        {"column_family_id": "1", "key": b64(key), "value": b64(value)}
    ]

    rollback_transaction = bytes.fromhex("30112233445566778899aabbccddeeff")
    assert request(
        process,
        {
            "request_id": "rollback-begin",
            "operation": "begin",
            "transaction": b64(rollback_transaction),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "delete",
            "operation": "delete",
            "transaction": b64(rollback_transaction),
            "column_family_id": "1",
            "key": b64(key),
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "deleted-get",
            "operation": "get",
            "transaction": b64(rollback_transaction),
            "column_family_id": "1",
            "key": b64(key),
        },
    )["outcome"] == "Not_Found"
    assert request(
        process,
        {
            "request_id": "rollback",
            "operation": "rollback",
            "transaction": b64(rollback_transaction),
        },
    )["outcome"] == "Success"

    remote_transaction = bytes.fromhex("50112233445566778899aabbccddeeff")
    assert request(
        process,
        {
            "request_id": "remote-begin",
            "operation": "begin",
            "transaction": b64(remote_transaction),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "remote-put",
            "operation": "put",
            "transaction": b64(remote_transaction),
            "column_family_id": "1",
            "key": b64(b"\x00\xfe"),
            "value": b64(b"not-remote"),
        },
    )["outcome"] == "Success"
    remote_commit = request(
        process,
        {
            "request_id": "remote-commit",
            "operation": "commit",
            "transaction": b64(remote_transaction),
            "receipt": b64(bytes.fromhex("51112233445566778899aabbccddeeff")),
            "durability": "remote",
        },
    )
    assert remote_commit["outcome"] == "Unsupported"
    assert remote_commit["reason"] == "remote_durable"
    assert request(
        process,
        {
            "request_id": "remote-rollback",
            "operation": "rollback",
            "transaction": b64(remote_transaction),
        },
    )["outcome"] == "Success"
    assert request(process, {"request_id": "reopen", "operation": "reopen"})["outcome"] == "Success"

    rejected = request(
        process,
        {"request_id": "strict", "operation": "state", "durability_barrier": False, "extra": 1},
    )
    assert rejected["request_id"] == "strict" and rejected["outcome"] == "Unsupported"

    invalid_receipts = (
        "not-base64",
        b64(RECEIPT).rstrip("="),
        b64(RECEIPT + b"\x00"),
    )
    for position, receipt in enumerate(invalid_receipts):
        response = request(
            process,
            {
                "request_id": f"resolve-invalid-{position}",
                "operation": "resolve",
                "receipt": receipt,
            },
        )
        assert response["outcome"] == "Unsupported"
        assert response["reason"] == "receipt_id"
    response = request(
        process,
        {
            "request_id": "resolve-canonical",
            "operation": "resolve",
            "receipt": b64(RECEIPT),
        },
    )
    assert response["outcome"] == "Unsupported"
    assert response["reason"] == "outcome_resolution"

    assert process.stdin is not None
    process.stdin.write(json.dumps({"request_id": "crash", "operation": "crash"}) + "\n")
    process.stdin.flush()
    assert process.wait(timeout=30) != 0

    recovered = start(binary, root, database_path)
    assert preflight(recovered, "recovery-preflight")["outcome"] == "Success"
    assert request(recovered, {"request_id": "recovery", "operation": "recovery"})["outcome"] == "Success"
    assert request(
        recovered,
        {
            "request_id": "reader-begin",
            "operation": "begin",
            "transaction": b64(bytes.fromhex("40112233445566778899aabbccddeeff")),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    recovered_get = request(
        recovered,
        {
            "request_id": "recovered-get",
            "operation": "get",
            "transaction": b64(bytes.fromhex("40112233445566778899aabbccddeeff")),
            "column_family_id": "1",
            "key": b64(key),
        },
    )
    assert recovered_get["value"] == b64(value)
    assert request(
        recovered,
        {
            "request_id": "reader-rollback",
            "operation": "rollback",
            "transaction": b64(bytes.fromhex("40112233445566778899aabbccddeeff")),
        },
    )["outcome"] == "Success"
    close(recovered)

    opened = start(binary, root, database_path)
    assert preflight(opened, "open-preflight")["outcome"] == "Success"
    assert request(opened, {"request_id": "open", "operation": "open"})["outcome"] == "Success"
    close(opened)


def immediate_commit_crash_recovery_test(binary: Path, root: Path, mode: str) -> None:
    database_id = bytes.fromhex(
        "60112233445566778899aabbccddeeff"
        if mode == "sigkill"
        else "70112233445566778899aabbccddeeff"
    )
    transaction = bytes.fromhex(
        "61112233445566778899aabbccddeeff"
        if mode == "sigkill"
        else "71112233445566778899aabbccddeeff"
    )
    receipt = bytes.fromhex(
        "62112233445566778899aabbccddeeff"
        if mode == "sigkill"
        else "72112233445566778899aabbccddeeff"
    )
    key = b"kill" if mode == "sigkill" else b"abort"
    value = b"durable"
    database_path = f"flyology-db-{database_id.hex()}"
    process = start(binary, root, database_path)
    assert preflight(process, "preflight", database_id=database_id)["outcome"] == "Success"
    assert request(process, {"request_id": "create", "operation": "create"})[
        "outcome"
    ] == "Success"
    assert request(
        process,
        {
            "request_id": "begin",
            "operation": "begin",
            "transaction": b64(transaction),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "put",
            "operation": "put",
            "transaction": b64(transaction),
            "column_family_id": "1",
            "key": b64(key),
            "value": b64(value),
        },
    )["outcome"] == "Success"
    committed = request(
        process,
        {
            "request_id": "commit",
            "operation": "commit",
            "transaction": b64(transaction),
            "receipt": b64(receipt),
            "durability": "local_comparative",
        },
    )
    assert committed["outcome"] == "Success"
    assert committed["receipt"] == b64(receipt)

    if mode == "sigkill":
        process.kill()
        assert process.wait(timeout=30) < 0
    else:
        assert process.stdin is not None
        process.stdin.write(
            json.dumps({"request_id": "crash", "operation": "crash"}) + "\n"
        )
        process.stdin.flush()
        assert process.wait(timeout=30) < 0

    process = start(binary, root, database_path)
    assert preflight(process, "recovery-preflight", database_id=database_id)[
        "outcome"
    ] == "Success"
    assert request(process, {"request_id": "recovery", "operation": "recovery"})[
        "outcome"
    ] == "Success"
    state = request(
        process,
        {"request_id": "state", "operation": "state", "durability_barrier": False},
    )
    assert state["digest"] == digest_tuple("1", key, value)
    assert state["tuples"] == [
        {"column_family_id": "1", "key": b64(key), "value": b64(value)}
    ]
    close(process)


def successful_receipt_reuse_test(binary: Path, root: Path) -> None:
    database_id = bytes.fromhex("83112233445566778899aabbccddeeff")
    receipt = bytes.fromhex("84112233445566778899aabbccddeeff")
    fresh_receipt = bytes.fromhex("85112233445566778899aabbccddeeff")
    database_path = f"flyology-db-{database_id.hex()}"
    process = start(binary, root, database_path, ["--max-receipt-ids", "1"])
    assert preflight(process, "preflight", database_id=database_id)["outcome"] == "Success"
    assert request(process, {"request_id": "create", "operation": "create"})[
        "outcome"
    ] == "Success"

    first_transaction = bytes.fromhex("86112233445566778899aabbccddeeff")
    assert request(
        process,
        {
            "request_id": "first-begin",
            "operation": "begin",
            "transaction": b64(first_transaction),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "first-put",
            "operation": "put",
            "transaction": b64(first_transaction),
            "column_family_id": "1",
            "key": b64(b"kept"),
            "value": b64(b"visible"),
        },
    )["outcome"] == "Success"
    committed = request(
        process,
        {
            "request_id": "first-commit",
            "operation": "commit",
            "transaction": b64(first_transaction),
            "receipt": b64(receipt),
            "durability": "local_comparative",
        },
    )
    assert committed["outcome"] == "Success"
    assert committed["receipt"] == b64(receipt)
    assert request(process, {"request_id": "reopen", "operation": "reopen"})[
        "outcome"
    ] == "Success"

    second_transaction = bytes.fromhex("87112233445566778899aabbccddeeff")
    assert request(
        process,
        {
            "request_id": "second-begin",
            "operation": "begin",
            "transaction": b64(second_transaction),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    assert request(
        process,
        {
            "request_id": "second-put",
            "operation": "put",
            "transaction": b64(second_transaction),
            "column_family_id": "1",
            "key": b64(b"hidden"),
            "value": b64(b"not-applied"),
        },
    )["outcome"] == "Success"
    reused = request(
        process,
        {
            "request_id": "second-commit",
            "operation": "commit",
            "transaction": b64(second_transaction),
            "receipt": b64(receipt),
            "durability": "local_comparative",
        },
    )
    assert reused["outcome"] == "Unsupported"
    assert reused["reason"] == "receipt_reused"
    assert request(
        process,
        {
            "request_id": "second-rollback",
            "operation": "rollback",
            "transaction": b64(second_transaction),
        },
    )["outcome"] == "Success"

    third_transaction = bytes.fromhex("88112233445566778899aabbccddeeff")
    assert request(
        process,
        {
            "request_id": "third-begin",
            "operation": "begin",
            "transaction": b64(third_transaction),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    capacity = request(
        process,
        {
            "request_id": "third-commit",
            "operation": "commit",
            "transaction": b64(third_transaction),
            "receipt": b64(fresh_receipt),
            "durability": "local_comparative",
        },
    )
    assert capacity["outcome"] == "Unsupported"
    assert capacity["reason"] == "receipt_capacity"
    assert request(
        process,
        {
            "request_id": "third-rollback",
            "operation": "rollback",
            "transaction": b64(third_transaction),
        },
    )["outcome"] == "Success"
    state = request(
        process,
        {"request_id": "state", "operation": "state", "durability_barrier": False},
    )
    assert state["tuples"] == [
        {"column_family_id": "1", "key": b64(b"kept"), "value": b64(b"visible")}
    ]
    close(process)


def aggregate_projection_bound_test(binary: Path, root: Path) -> None:
    database_id = bytes.fromhex("80112233445566778899aabbccddeeff")
    transaction = bytes.fromhex("81112233445566778899aabbccddeeff")
    database_path = f"flyology-db-{database_id.hex()}"
    process = start(
        binary,
        root,
        database_path,
        ["--max-scan-bytes", "120", "--max-state-bytes", "220"],
    )
    assert preflight(process, "preflight", database_id=database_id)["outcome"] == "Success"
    assert request(process, {"request_id": "create", "operation": "create"})[
        "outcome"
    ] == "Success"
    assert request(
        process,
        {
            "request_id": "begin",
            "operation": "begin",
            "transaction": b64(transaction),
            "isolation": "Snapshot",
        },
    )["outcome"] == "Success"
    for key in (b"a", b"b"):
        assert request(
            process,
            {
                "request_id": f"put-{key.decode()}",
                "operation": "put",
                "transaction": b64(transaction),
                "column_family_id": "1",
                "key": b64(key),
                "value": b64(b"12345678"),
            },
        )["outcome"] == "Success"
    scan = request(
        process,
        {
            "request_id": "scan",
            "operation": "scan",
            "transaction": b64(transaction),
            "column_family_id": "1",
            "lower": b64(b"a"),
            "upper": b64(b"c"),
            "maximum_items": 2,
        },
    )
    assert scan["outcome"] == "Unsupported"
    assert scan["reason"] == "scan_byte_limit"
    assert request(
        process,
        {
            "request_id": "commit",
            "operation": "commit",
            "transaction": b64(transaction),
            "receipt": b64(bytes.fromhex("82112233445566778899aabbccddeeff")),
            "durability": "local_comparative",
        },
    )["outcome"] == "Success"
    state = request(
        process,
        {"request_id": "state", "operation": "state", "durability_barrier": False},
    )
    assert state["outcome"] == "Unsupported"
    assert state["reason"] == "state_byte_limit"
    close(process)


def preflight_rejection_test(binary: Path, root: Path) -> None:
    database_path = f"flyology-db-{DATABASE_ID.hex()}"
    process = start(binary, root, "wrong-database-identity")
    response = preflight(process, "identity")
    assert response["outcome"] == "Unsupported"
    assert response["reason"] == "database_identity_path"
    close(process)
    assert not any(root.iterdir())

    process = start(binary, root, database_path)
    response = preflight(
        process,
        "families",
        families=[{"id": "1", "name": "default"}, {"id": "2", "name": "other"}],
    )
    assert response["outcome"] == "Unsupported" and response["reason"] == "column_families"
    close(process)
    assert not any(root.iterdir())

    process = start(binary, root, database_path)
    response = preflight(
        process,
        "family-id-bound",
        families=[{"id": "12345678901", "name": "default"}],
    )
    assert response["outcome"] == "Unsupported"
    assert response["reason"] == "column_family_id"
    close(process)
    assert not any(root.iterdir())

    process = start(binary, root, database_path)
    response = preflight(process, "remote", capabilities=["remote_durable"])
    assert response["outcome"] == "Unsupported"
    assert response["unsupported_capabilities"] == ["remote_durable"]
    close(process)
    assert not any(root.iterdir())


def runner_receipt_test() -> None:
    record = {
        "step": 7,
        "expected": "Outcome_Unknown",
        "receipt": RECEIPT.hex(),
    }
    check_operation(
        record,
        {"outcome": "Outcome_Unknown", "receipt": b64(RECEIPT)},
    )
    try:
        check_operation(record, {"outcome": "Outcome_Unknown"})
    except WorkloadFailure:
        pass
    else:
        raise AssertionError("runner accepted Outcome_Unknown without its receipt")


def main() -> int:
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="flyology-db-slatedb-protocol-") as temporary:
        protocol_test(binary, Path(temporary))
    with tempfile.TemporaryDirectory(prefix="flyology-db-slatedb-preflight-") as temporary:
        preflight_rejection_test(binary, Path(temporary))
    for mode in ("sigkill", "abort"):
        with tempfile.TemporaryDirectory(
            prefix=f"flyology-db-slatedb-{mode}-recovery-"
        ) as temporary:
            immediate_commit_crash_recovery_test(binary, Path(temporary), mode)
    with tempfile.TemporaryDirectory(prefix="flyology-db-slatedb-bounds-") as temporary:
        aggregate_projection_bound_test(binary, Path(temporary))
    with tempfile.TemporaryDirectory(prefix="flyology-db-slatedb-receipts-") as temporary:
        successful_receipt_reuse_test(binary, Path(temporary))
    runner_receipt_test()
    print("SlateDB adapter protocol tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
