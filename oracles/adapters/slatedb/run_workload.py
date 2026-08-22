#!/usr/bin/env python3
"""Run one validated Flyology.DB workload through the pinned SlateDB adapter."""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import subprocess
import sys
from typing import Any, TextIO

PROTOCOL = "flyology.db.oracle.adapter.v1"


class WorkloadFailure(Exception):
    pass


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def b64(hex_value: str) -> str:
    return base64.b64encode(bytes.fromhex(hex_value)).decode("ascii")


class Process:
    def __init__(self, binary: Path, root: Path, database_path: str) -> None:
        self.value = subprocess.Popen(
            [str(binary), "--root", str(root), "--database-path", database_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )

    def request(self, value: dict[str, Any]) -> dict[str, Any]:
        if self.value.stdin is None or self.value.stdout is None:
            raise WorkloadFailure("adapter pipes are unavailable")
        self.value.stdin.write(canonical(value) + "\n")
        self.value.stdin.flush()
        line = self.value.stdout.readline()
        if not line:
            detail = self.value.stderr.read() if self.value.stderr is not None else ""
            raise WorkloadFailure(f"adapter exited before responding: {detail.strip()}")
        response = json.loads(line)
        if response.get("request_id") != value["request_id"]:
            raise WorkloadFailure("adapter did not preserve request_id")
        return response

    def kill(self) -> int:
        self.value.kill()
        return self.value.wait(timeout=30)

    def close(self) -> None:
        if self.value.poll() is not None:
            return
        assert self.value.stdin is not None
        self.value.stdin.close()
        status = self.value.wait(timeout=60)
        if status != 0:
            detail = self.value.stderr.read() if self.value.stderr is not None else ""
            raise WorkloadFailure(f"adapter clean close failed ({status}): {detail.strip()}")


def preflight(process: Process, header: dict[str, Any], request_id: str) -> dict[str, Any]:
    return process.request(
        {
            "request_id": request_id,
            "operation": "preflight",
            "protocol": PROTOCOL,
            "database_id": b64(header["database_id"]),
            "limits": header["limits"],
            "column_families": header["column_families"],
            "required_capabilities": header["required_capabilities"],
        }
    )


def derived_capabilities(records: list[dict[str, Any]]) -> list[str]:
    header = records[0]
    required = list(header["required_capabilities"])
    derived: list[str] = []
    if len(header["column_families"]) != 1:
        derived.append("multi_column_family")
    for record in records[1:]:
        if record["record"] != "operation":
            continue
        operation = record["operation"]
        if operation == "commit" and record["expected"] != "Unsupported":
            derived.append("remote_durable")
        elif operation == "resolve":
            derived.append("outcome_resolution")
        elif operation == "crash":
            derived.append("crash_recovery")
        elif operation == "begin":
            derived.append(
                "serializable" if record["isolation"] == "Serializable" else "snapshot"
            )
    for capability in derived:
        if capability not in required:
            required.append(capability)
    return required


def translate(record: dict[str, Any], request_id: str, after_crash: bool) -> dict[str, Any]:
    operation = record["operation"]
    request: dict[str, Any] = {"request_id": request_id, "operation": operation}
    if after_crash and operation == "reopen":
        request["operation"] = "recovery"
    if "transaction" in record:
        request["transaction"] = b64(record["transaction"])
    if "column_family_id" in record:
        request["column_family_id"] = record["column_family_id"]
    for field in ("key", "value", "lower", "upper"):
        if field in record:
            request[field] = b64(record[field])
    if "isolation" in record:
        request["isolation"] = record["isolation"]
    if "maximum_items" in record:
        request["maximum_items"] = record["maximum_items"]
    if "receipt" in record:
        request["receipt"] = b64(record["receipt"])
    if operation == "commit":
        request["durability"] = "remote"
    return request


def check_operation(record: dict[str, Any], response: dict[str, Any]) -> None:
    if response.get("outcome") != record["expected"]:
        raise WorkloadFailure(
            f"step {record['step']} expected {record['expected']}, got {response.get('outcome')}"
        )
    if "expected_value" in record:
        expected = b64(record["expected_value"])
        if response.get("value") != expected:
            raise WorkloadFailure(f"step {record['step']} returned the wrong value")
    if "receipt" in record and response.get("outcome") in {
        "Success",
        "Outcome_Unknown",
    }:
        if response.get("receipt") != b64(record["receipt"]):
            raise WorkloadFailure(f"step {record['step']} returned the wrong receipt")


def check_state(record: dict[str, Any], response: dict[str, Any]) -> None:
    if response.get("outcome") != "Success":
        raise WorkloadFailure(f"checkpoint {record['name']} failed: {response.get('outcome')}")
    if "digest" in record and response.get("digest") != record["digest"]:
        raise WorkloadFailure(f"checkpoint {record['name']} digest mismatch")
    if "expected_tuples" in record:
        expected = [
            {
                "column_family_id": item["column_family_id"],
                "key": b64(item["key"]),
                "value": b64(item["value"]),
            }
            for item in record["expected_tuples"]
        ]
        if response.get("tuples") != expected:
            raise WorkloadFailure(f"checkpoint {record['name']} state mismatch")


def record_history(output: TextIO | None, kind: str, value: dict[str, Any]) -> None:
    if output is not None:
        output.write(canonical({"record": kind, **value}) + "\n")
        output.flush()


def run(args: argparse.Namespace) -> int:
    project_root = Path(__file__).resolve().parents[3]
    validator = project_root / "oracles/contract/validate_workload.py"
    schema = project_root / "oracles/contract/workload.schema.json"
    subprocess.run([str(validator), str(schema), str(args.workload)], check=True)
    records = [json.loads(line) for line in args.workload.read_text().splitlines()]
    header = dict(records[0])
    header["required_capabilities"] = derived_capabilities(records)
    args.root.mkdir(parents=True, exist_ok=True)
    database_path = f"flyology-db-{header['database_id']}"
    history = args.history.open("w", encoding="utf-8") if args.history else None
    process = Process(args.adapter, args.root, database_path)
    after_crash = False
    try:
        response = preflight(process, header, "preflight:0")
        record_history(history, "response", response)
        if response.get("outcome") == "Unsupported":
            print(canonical(response))
            return 2
        if response.get("outcome") != "Success":
            raise WorkloadFailure("capability preflight failed")

        for record in records[1:]:
            request_id = f"step:{record['step']}"
            if record["record"] == "operation" and record["operation"] == "crash":
                status = process.kill()
                record_history(
                    history,
                    "lifecycle",
                    {"request_id": request_id, "event": "sigkill", "status": status},
                )
                process = None
                after_crash = True
                continue
            if process is None:
                process = Process(args.adapter, args.root, database_path)
                recovered = preflight(process, header, f"recovery-preflight:{record['step']}")
                record_history(history, "response", recovered)
                if recovered.get("outcome") != "Success":
                    raise WorkloadFailure("post-crash capability preflight failed")

            if record["record"] == "checkpoint":
                request = {
                    "request_id": request_id,
                    "operation": "state",
                    "durability_barrier": record.get("durability_barrier", False),
                }
                record_history(history, "request", request)
                response = process.request(request)
                record_history(history, "response", response)
                check_state(record, response)
                after_crash = False
                continue

            request = translate(record, request_id, after_crash)
            record_history(history, "request", request)
            response = process.request(request)
            record_history(history, "response", response)
            check_operation(record, response)
            after_crash = False
        return 0
    finally:
        if process is not None:
            process.close()
        if history is not None:
            history.close()


def parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    project_root = here.parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--workload", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument(
        "--adapter",
        type=Path,
        default=project_root / "build/oracles/slatedb-adapter/debug/flyology-db-slatedb-adapter",
    )
    parser.add_argument("--history", type=Path)
    return parser.parse_args()


def main() -> int:
    try:
        return run(parse_args())
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError, WorkloadFailure) as error:
        print(f"SlateDB workload failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
