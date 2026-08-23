#!/usr/bin/env python3
"""Validate and run a supported Flyology.DB workload against TidesDB."""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from adapter import (
    MAX_ACTIVE_TRANSACTIONS,
    MAX_COLUMN_FAMILIES,
    MAX_KEY_BYTES,
    MAX_MUTATIONS_PER_TRANSACTION,
    MAX_RESULT_BYTES,
    MAX_SCAN_ITEMS,
    MAX_VALUE_BYTES,
    RequestError,
    canonical_family_id,
    encode_family_name,
    encode_storage_path,
)

ADAPTER_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = ADAPTER_ROOT.parents[2]
VALIDATOR = REPOSITORY_ROOT / "oracles" / "contract" / "validate_workload.py"
SCHEMA = REPOSITORY_ROOT / "oracles" / "contract" / "workload.schema.json"
RUNNER = ADAPTER_ROOT / "scripts" / "run.sh"
SUPPORTED_CAPABILITIES = {
    "multi_column_family",
    "snapshot",
    "serializable",
    "crash_recovery",
}


class WorkloadFailure(Exception):
    """One adapter or expectation failure."""


class Service:
    def __init__(self) -> None:
        self.process = subprocess.Popen(
            [str(RUNNER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

    def request(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.process.stdin is None or self.process.stdout is None:
            raise WorkloadFailure("adapter pipes are unavailable")
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            detail = self.process.stderr.read() if self.process.stderr else ""
            raise WorkloadFailure(f"adapter exited before response: {detail}")
        response = json.loads(line)
        if response.get("request_id") != request["request_id"]:
            raise WorkloadFailure(f"request/response mismatch: {response}")
        return response

    def crash(self, request_id: str) -> None:
        if self.process.stdin is None:
            raise WorkloadFailure("adapter input is unavailable")
        self.process.stdin.write(
            json.dumps(
                {"request_id": request_id, "command": "crash"},
                separators=(",", ":"),
            )
            + "\n"
        )
        self.process.stdin.flush()
        self.process.stdin.close()
        self.process.wait(timeout=15)
        if self.process.returncode != 73:
            detail = self.process.stderr.read() if self.process.stderr else ""
            raise WorkloadFailure(f"crash exit was {self.process.returncode}: {detail}")
        self.close_pipes()

    def finish(self) -> None:
        if self.process.poll() is None:
            if self.process.stdin is not None:
                self.process.stdin.close()
            self.process.wait(timeout=15)
        if self.process.returncode != 0:
            detail = self.process.stderr.read() if self.process.stderr else ""
            raise WorkloadFailure(f"adapter exit was {self.process.returncode}: {detail}")
        self.close_pipes()

    def close_pipes(self) -> None:
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


def load(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def preflight(records: list[dict[str, Any]], database: Path) -> list[str]:
    required = set(records[0]["required_capabilities"])
    missing = sorted(required - SUPPORTED_CAPABILITIES)
    limits = records[0]["limits"]
    supported_limits = {
        "transactions": MAX_ACTIVE_TRANSACTIONS,
        "mutations_per_transaction": MAX_MUTATIONS_PER_TRANSACTION,
        "key_bytes": MAX_KEY_BYTES,
        "value_bytes": MAX_VALUE_BYTES,
    }
    for name, supported in supported_limits.items():
        if limits[name] > supported:
            missing.append(f"limit.{name}")
    families = records[0]["column_families"]
    if len(families) > MAX_COLUMN_FAMILIES:
        missing.append("limit.column_families")
    for family in families:
        try:
            canonical_family_id(family["id"])
        except RequestError:
            missing.append("invalid.column_family_id")
        try:
            encode_family_name(family["name"])
        except RequestError:
            missing.append("invalid.column_family_name")
    try:
        encode_storage_path(
            str(database),
            "database path",
            [family["name"] for family in families],
        )
    except RequestError:
        missing.append("invalid.database_layout")
    isolation: dict[str, str] = {}
    possible_state_bytes = 0
    for record in records[1:]:
        if "key" in record and record["key"] == "":
            missing.append("empty_keys")
        if record.get("operation") == "put":
            possible_state_bytes += (
                len(record["column_family_id"].encode("ascii"))
                + len(bytes.fromhex(record["key"]))
                + len(bytes.fromhex(record["value"]))
            )
        if record.get("record") == "checkpoint" and possible_state_bytes > MAX_RESULT_BYTES:
            missing.append("limit.state_result_bytes")
        if record.get("operation") == "checkpoint":
            try:
                encode_storage_path(
                    str(database.parent / f"checkpoint-{record['step']}"),
                    "checkpoint path",
                    [family["name"] for family in families],
                )
            except RequestError:
                missing.append("invalid.checkpoint_layout")
        if record.get("operation") == "begin" and record.get("expected") == "Success":
            isolation[record["transaction"]] = record["isolation"]
        if (
            record.get("operation") == "scan"
            and isolation.get(record.get("transaction")) == "Serializable"
        ):
            missing.append("serializable_range_phantoms")
        if record.get("operation") == "scan":
            if record["maximum_items"] > MAX_SCAN_ITEMS:
                missing.append("limit.scan_items")
            worst_case_bytes = record["maximum_items"] * (
                limits["key_bytes"] + limits["value_bytes"]
            )
            if worst_case_bytes > MAX_RESULT_BYTES:
                missing.append("limit.scan_result_bytes")
    return sorted(set(missing))


def request_for(record: dict[str, Any], request_id: str) -> dict[str, Any]:
    operation = record["operation"]
    request: dict[str, Any] = {"request_id": request_id, "command": operation}
    if "transaction" in record:
        request["transaction"] = record["transaction"]
    if "column_family_id" in record:
        request["family"] = record["column_family_id"]
    if "key" in record:
        request["key"] = base64.b64encode(bytes.fromhex(record["key"])).decode("ascii")
    if "value" in record:
        request["value"] = base64.b64encode(bytes.fromhex(record["value"])).decode("ascii")
    if operation == "begin":
        request["isolation"] = record["isolation"]
    elif operation == "scan":
        request["lower"] = base64.b64encode(bytes.fromhex(record["lower"])).decode("ascii")
        request["upper"] = base64.b64encode(bytes.fromhex(record["upper"])).decode("ascii")
        request["maximum"] = record["maximum_items"]
    return request


def compare_checkpoint(record: dict[str, Any], response: dict[str, Any]) -> None:
    if response.get("outcome") != "Success":
        raise WorkloadFailure(f"checkpoint state failed: {response}")
    if "digest" in record and response.get("digest") != record["digest"]:
        raise WorkloadFailure(
            f"checkpoint {record['name']} digest mismatch: {response.get('digest')}"
        )
    if "expected_tuples" in record:
        actual = [
            {
                "column_family_id": item["family"],
                "key": base64.b64decode(item["key"], validate=True).hex(),
                "value": base64.b64decode(item["value"], validate=True).hex(),
            }
            for item in response.get("tuples", [])
        ]
        if actual != record["expected_tuples"]:
            raise WorkloadFailure(
                f"checkpoint {record['name']} tuples mismatch: {actual}"
            )


def run(records: list[dict[str, Any]], database: Path) -> None:
    families = records[0]["column_families"]
    service: Service | None = Service()
    try:
        for record in records[1:]:
            request_id = str(record["step"])
            if record["record"] == "checkpoint":
                if service is None:
                    raise WorkloadFailure("checkpoint has no live adapter")
                if record.get("durability_barrier"):
                    flush = service.request(
                        {
                            "request_id": request_id + ":flush",
                            "command": "flush",
                        }
                    )
                    if flush.get("outcome") != "Success":
                        raise WorkloadFailure(f"checkpoint flush failed: {flush}")
                compare_checkpoint(
                    record,
                    service.request({"request_id": request_id, "command": "state"}),
                )
                continue

            operation = record["operation"]
            if operation == "crash":
                if service is None:
                    raise WorkloadFailure("crash has no live adapter")
                service.crash(request_id)
                service = None
                continue
            if operation == "reopen":
                if service is not None:
                    service.finish()
                service = Service()
                response = service.request(
                    {
                        "request_id": request_id,
                        "command": "open",
                        "path": str(database),
                        "create": False,
                        "families": families,
                    }
                )
            elif operation in {"create", "open"}:
                if service is None:
                    service = Service()
                response = service.request(
                    {
                        "request_id": request_id,
                        "command": "open",
                        "path": str(database),
                        "create": operation == "create",
                        "families": families,
                    }
                )
            elif operation == "commit" and record["expected"] == "Unsupported":
                response = {"request_id": request_id, "outcome": "Unsupported"}
            elif operation == "resolve":
                response = {"request_id": request_id, "outcome": "Unsupported"}
            elif operation == "checkpoint":
                if service is None:
                    raise WorkloadFailure("checkpoint has no live adapter")
                response = service.request(
                    {
                        "request_id": request_id,
                        "command": "checkpoint",
                        "path": str(database.parent / f"checkpoint-{record['step']}"),
                    }
                )
            else:
                if service is None:
                    raise WorkloadFailure(f"{operation} has no live adapter")
                response = service.request(request_for(record, request_id))
                if operation == "get" and response.get("outcome") == "Success":
                    actual = base64.b64decode(response["value"], validate=True).hex()
                    if actual != record["expected_value"]:
                        raise WorkloadFailure(
                            f"step {record['step']} value mismatch: {actual}"
                        )
            if response.get("outcome") != record["expected"]:
                raise WorkloadFailure(
                    f"step {record['step']} expected {record['expected']}, got {response}"
                )
    finally:
        if service is not None:
            service.finish()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("workload", type=Path)
    parser.add_argument("database", type=Path)
    arguments = parser.parse_args()
    validation = subprocess.run(
        [str(VALIDATOR), str(SCHEMA), str(arguments.workload)],
        check=False,
        capture_output=True,
        text=True,
    )
    if validation.returncode != 0:
        sys.stderr.write(validation.stderr)
        return validation.returncode
    records = load(arguments.workload)
    missing = preflight(records, arguments.database)
    if missing:
        print(
            json.dumps(
                {
                    "outcome": "Unsupported",
                    "reason": "required_capabilities",
                    "unsupported_capabilities": missing,
                },
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 2
    try:
        run(records, arguments.database)
    except WorkloadFailure as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(json.dumps({"outcome": "Success"}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
