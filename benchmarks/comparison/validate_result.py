#!/usr/bin/env python3
"""Validate retained Flyology.DB benchmark panel results without dependencies."""

from __future__ import annotations

import hashlib
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
PANEL = ROOT / "panel.json"
WORKLOAD = ROOT / "workload.json"
SCHEMA = ROOT / "result.schema.json"
SCHEMA_VERSION = "flyology.db.benchmark.result.v1"
HEX = set("0123456789abcdef")


class InvalidResult(ValueError):
    """A retained result violates the benchmark contract."""


def object_only(value: Any, keys: set[str], name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InvalidResult(f"{name} must be an object")
    extras = set(value) - keys
    missing = keys - set(value)
    if extras:
        raise InvalidResult(f"{name} has unknown members: {sorted(extras)}")
    if missing:
        raise InvalidResult(f"{name} is missing members: {sorted(missing)}")
    return value


def nonempty(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value:
        raise InvalidResult(f"{name} must be a nonempty string")
    return value


def exact_hash(value: Any, name: str) -> str:
    text = nonempty(value, name)
    if len(text) != 64 or any(character not in HEX for character in text):
        raise InvalidResult(f"{name} must be a lowercase SHA-256")
    return text


def integer(value: Any, name: str, minimum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise InvalidResult(f"{name} must be an integer >= {minimum}")
    return value


def panel_contract() -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    panel = json.loads(PANEL.read_text(encoding="utf-8"))
    if panel.get("schema_version") != "flyology.db.benchmark.panel.v1":
        raise InvalidResult("unsupported panel schema")
    participants = {item["id"]: item for item in panel["participants"]}
    lanes = {item["id"]: item for item in panel["lanes"]}
    if len(participants) != len(panel["participants"]):
        raise InvalidResult("duplicate panel participant")
    if len(lanes) != len(panel["lanes"]):
        raise InvalidResult("duplicate panel lane")
    return participants, lanes


def contract_digest() -> str:
    digest = hashlib.sha256()
    for path in (PANEL, WORKLOAD, SCHEMA):
        digest.update(path.name.encode("ascii"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def workload_contract() -> tuple[dict[str, Any], str]:
    workload = json.loads(WORKLOAD.read_text(encoding="utf-8"))
    expected = {
        "schema_version", "id", "seed", "key_bytes", "value_bytes",
        "transaction_mutations", "concurrency", "key_selection",
        "timed_operation", "verification", "repetition_isolation",
    }
    workload = object_only(workload, expected, "workload contract")
    if workload["schema_version"] != "flyology.db.benchmark.workload.v1":
        raise InvalidResult("unsupported workload schema")
    return workload, hashlib.sha256(WORKLOAD.read_bytes()).hexdigest()


def validate(path: Path) -> None:
    result = json.loads(path.read_text(encoding="utf-8"))
    result = object_only(
        result,
        {"schema_version", "contract_sha256", "campaign", "host", "workload", "results"},
        "result",
    )
    if result["schema_version"] != SCHEMA_VERSION:
        raise InvalidResult("unsupported result schema")
    if exact_hash(result["contract_sha256"], "contract_sha256") != contract_digest():
        raise InvalidResult("result does not name the current panel contract")

    campaign = object_only(
        result["campaign"], {"id", "classification", "started_at_utc"}, "campaign"
    )
    nonempty(campaign["id"], "campaign.id")
    if campaign["classification"] not in {"directional", "isolated_host"}:
        raise InvalidResult("campaign.classification is invalid")
    nonempty(campaign["started_at_utc"], "campaign.started_at_utc")

    host = object_only(
        result["host"], {"os", "architecture", "cpu", "memory_bytes", "power"}, "host"
    )
    for field in ("os", "architecture", "cpu"):
        nonempty(host[field], f"host.{field}")
    integer(host["memory_bytes"], "host.memory_bytes", 1)
    power = object_only(
        host["power"], {"os", "detector", "profile", "power_source"}, "host.power"
    )
    for field in ("os", "detector", "profile"):
        nonempty(power[field], f"host.power.{field}")
    if power["power_source"] is not None:
        nonempty(power["power_source"], "host.power.power_source")

    workload = object_only(
        result["workload"],
        {
            "id", "sha256", "seed", "key_bytes", "value_bytes", "key_count",
            "transaction_mutations", "concurrency", "warmup_operations",
            "measured_operations", "repetitions",
        },
        "workload",
    )
    fixed_workload, workload_digest = workload_contract()
    if nonempty(workload["id"], "workload.id") != fixed_workload["id"]:
        raise InvalidResult("workload.id does not match the workload contract")
    if exact_hash(workload["sha256"], "workload.sha256") != workload_digest:
        raise InvalidResult("workload.sha256 does not match the workload contract")
    integer(workload["seed"], "workload.seed", 0)
    for field, minimum in (
        ("key_bytes", 1), ("value_bytes", 0), ("key_count", 1),
        ("transaction_mutations", 1), ("concurrency", 1),
        ("warmup_operations", 0), ("measured_operations", 1), ("repetitions", 1),
    ):
        integer(workload[field], f"workload.{field}", minimum)
    for field in (
        "seed", "key_bytes", "value_bytes", "transaction_mutations", "concurrency"
    ):
        if workload[field] != fixed_workload[field]:
            raise InvalidResult(f"workload.{field} does not match the workload contract")
    if workload["key_count"] != (
        workload["warmup_operations"] + workload["measured_operations"]
    ):
        raise InvalidResult("workload.key_count must equal warmup plus measured operations")

    participants, lanes = panel_contract()
    measurements = result["results"]
    if not isinstance(measurements, list) or not measurements:
        raise InvalidResult("results must be a nonempty array")
    seen: set[tuple[str, str]] = set()
    for index, measurement_value in enumerate(measurements):
        name = f"results[{index}]"
        measurement = object_only(
            measurement_value,
            {
                "lane", "participant", "engine_source", "adapter_source", "compiler",
                "build_flags", "storage_revision", "storage_configuration",
                "correctness_gate", "correctness_evidence", "dependency_sources",
                "power", "samples", "median_operations_per_second",
            },
            name,
        )
        lane_id = nonempty(measurement["lane"], f"{name}.lane")
        participant_id = nonempty(measurement["participant"], f"{name}.participant")
        if lane_id not in lanes or participant_id not in participants:
            raise InvalidResult(f"{name} names an unknown lane or participant")
        lane_entry = next(
            (item for item in lanes[lane_id]["participants"] if item["id"] == participant_id),
            None,
        )
        if lane_entry is None or lane_entry["status"] != "eligible":
            raise InvalidResult(f"{name} measures an unsupported participant")
        identity = (lane_id, participant_id)
        if identity in seen:
            raise InvalidResult(f"duplicate measurement for {lane_id}/{participant_id}")
        seen.add(identity)
        for field in (
            "engine_source", "adapter_source", "compiler", "storage_revision",
            "correctness_gate",
        ):
            nonempty(measurement[field], f"{name}.{field}")
        exact_hash(measurement["correctness_evidence"], f"{name}.correctness_evidence")
        if not isinstance(measurement["build_flags"], list) or not all(
            isinstance(value, str) for value in measurement["build_flags"]
        ):
            raise InvalidResult(f"{name}.build_flags must be a string array")
        dependencies = measurement["dependency_sources"]
        if not isinstance(dependencies, dict) or not dependencies:
            raise InvalidResult(f"{name}.dependency_sources must be a nonempty object")
        for dependency, source in dependencies.items():
            nonempty(dependency, f"{name}.dependency_sources key")
            nonempty(source, f"{name}.dependency_sources.{dependency}")
        storage_configuration = measurement["storage_configuration"]
        if not isinstance(storage_configuration, dict) or not storage_configuration:
            raise InvalidResult(f"{name}.storage_configuration must be a nonempty object")
        for setting, value in storage_configuration.items():
            nonempty(setting, f"{name}.storage_configuration key")
            nonempty(value, f"{name}.storage_configuration.{setting}")
        participant_power = object_only(
            measurement["power"],
            {"os", "detector", "profile", "power_source"},
            f"{name}.power",
        )
        if participant_power != power:
            raise InvalidResult(f"{name}.power does not match the campaign power profile")

        samples = measurement["samples"]
        if not isinstance(samples, list) or len(samples) != workload["repetitions"]:
            raise InvalidResult(f"{name}.samples must match workload.repetitions")
        rates: list[float] = []
        for repetition, sample_value in enumerate(samples, start=1):
            sample_name = f"{name}.samples[{repetition - 1}]"
            sample = object_only(
                sample_value,
                {"repetition", "operations", "bytes", "elapsed_nanoseconds", "errors", "checksum"},
                sample_name,
            )
            if integer(sample["repetition"], f"{sample_name}.repetition", 1) != repetition:
                raise InvalidResult(f"{sample_name}.repetition is not contiguous")
            operations = integer(sample["operations"], f"{sample_name}.operations", 1)
            if operations != workload["measured_operations"]:
                raise InvalidResult(f"{sample_name}.operations does not match the workload")
            byte_count = integer(sample["bytes"], f"{sample_name}.bytes", 0)
            expected_bytes = operations * (workload["key_bytes"] + workload["value_bytes"])
            if byte_count != expected_bytes:
                raise InvalidResult(f"{sample_name}.bytes does not match application payload")
            elapsed = integer(sample["elapsed_nanoseconds"], f"{sample_name}.elapsed_nanoseconds", 1)
            if integer(sample["errors"], f"{sample_name}.errors", 0) != 0:
                raise InvalidResult(f"{sample_name}.errors must be zero")
            exact_hash(sample["checksum"], f"{sample_name}.checksum")
            rates.append(operations * 1_000_000_000.0 / elapsed)
        summary = measurement["median_operations_per_second"]
        if isinstance(summary, bool) or not isinstance(summary, (int, float)) or not math.isfinite(summary):
            raise InvalidResult(f"{name}.median_operations_per_second must be finite")
        expected = statistics.median(rates)
        if not math.isclose(float(summary), expected, rel_tol=1e-9, abs_tol=1e-9):
            raise InvalidResult(f"{name}.median_operations_per_second does not match samples")

    measured_by_lane: dict[str, set[str]] = {}
    checksums: dict[int, str] = {}
    for measurement in measurements:
        measured_by_lane.setdefault(measurement["lane"], set()).add(measurement["participant"])
        for sample in measurement["samples"]:
            previous = checksums.setdefault(sample["repetition"], sample["checksum"])
            if sample["checksum"] != previous:
                raise InvalidResult("participant state checksums do not match")
    for lane_id, measured in measured_by_lane.items():
        eligible = {
            item["id"]
            for item in lanes[lane_id]["participants"]
            if item["status"] == "eligible"
        }
        if measured != eligible:
            raise InvalidResult(f"results for {lane_id} do not contain every eligible participant")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} RESULT.json", file=sys.stderr)
        return 2
    try:
        validate(Path(sys.argv[1]))
    except (InvalidResult, json.JSONDecodeError, OSError) as error:
        print(f"invalid benchmark result: {error}", file=sys.stderr)
        return 1
    print("Flyology.DB benchmark result valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
