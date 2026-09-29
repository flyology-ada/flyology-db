#!/usr/bin/env python3
"""Exploratory exact-state screen of the deterministic-green pipeline foundation."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any


TRANSACTIONS = 35
OUTSTANDING = 32
MAXIMUM_MEMBERS = 8
EXPECTED_STATE = "090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb"
PROFILES = {
    "A": (
        "flyology-db-files-adaptive-cohort-members8-bytes2159008-"
        "wait-us1000-depth32-workers1-cohorts1"
    ),
    "B2": (
        "flyology-db-files-adaptive-cohort-members8-bytes2159008-"
        "wait-us1000-depth32-workers2-cohorts2"
    ),
    "S": "slatedb-1ms-depth32",
}
GEOMETRY = {
    PROFILES["A"]: (1, 1),
    PROFILES["B2"]: (2, 2),
}
COMPARISONS = {
    "AB2": (PROFILES["A"], PROFILES["B2"]),
    "SA": (PROFILES["S"], PROFILES["A"]),
    "SB2": (PROFILES["S"], PROFILES["B2"]),
}
ORDERS = {
    "x86_64": (
        ("SA", "AB2", "SB2"),
        ("SB2", "AB2", "SA"),
    ),
    "arm64": (
        ("SB2", "AB2", "SA"),
        ("SA", "AB2", "SB2"),
    ),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="ascii")


def validate_round(path: Path) -> dict[str, Any]:
    artifact = json.loads(path.read_text(encoding="utf-8"))
    records = artifact.get("records")
    if not isinstance(records, list) or len(records) != len(COMPARISONS):
        raise RuntimeError(f"unexpected comparison inventory: {path}")
    retained: list[dict[str, Any]] = []
    for record in records:
        workload = record.get("workload")
        if workload != {
            "id": "sustained-8960",
            "key_bytes": 16,
            "value_bytes": 1024,
            "mutations": 256,
            "transactions": TRANSACTIONS,
        }:
            raise RuntimeError(f"workload mismatch: {path}")
        reference = record.get("reference")
        contender = record.get("contender")
        if (reference, contender) not in COMPARISONS.values():
            raise RuntimeError(f"participant mismatch: {path}")
        metrics = record.get("metrics")
        if not isinstance(metrics, list):
            raise RuntimeError(f"metrics missing: {path}")
        verifications = [
            metric
            for metric in metrics
            if metric.get("schema") == "flyology.db.benchmark.state_verification.v1"
        ]
        #  Ten measured pairs plus the maintained pair's two calibration runs.
        if len(verifications) != 22:
            raise RuntimeError(f"exact-state verification count mismatch: {path}")
        for row in verifications:
            if (
                row.get("warmup_transactions") != 8
                or row.get("transactions") != TRANSACTIONS
                or row.get("mutations_per_transaction") != 256
                or row.get("verified_keys") != 11008
                or row.get("state_sha256") != EXPECTED_STATE
                or row.get("expected_state_sha256") != EXPECTED_STATE
            ):
                raise RuntimeError(f"exact-state digest or work mismatch: {path}")
        paired = [
            metric
            for metric in metrics
            if metric.get("schema") == "flyology.db.benchmark.paired_primary_sample.v1"
        ]
        if len(paired) != 10 or sum(
            row["reference_execution_ordinal"] < row["contender_execution_ordinal"]
            for row in paired
        ) != 5:
            raise RuntimeError(f"paired order is not balanced: {path}")
        if any(
            abs(row["reference_execution_ordinal"] - row["contender_execution_ordinal"])
            != 1
            or row["transactions_per_operation"] != TRANSACTIONS
            for row in paired
        ):
            raise RuntimeError(f"paired work or adjacency mismatch: {path}")
        primary = [
            metric
            for metric in metrics
            if metric.get("kind") == "custom" and metric.get("axis") == "primary_time"
        ]
        if len(primary) != 1:
            raise RuntimeError(f"primary metric is missing or ambiguous: {path}")
        configurations = [
            metric
            for metric in metrics
            if metric.get("kind") == "flyology_db_execution_configuration"
        ]
        expected_flyology = {
            participant
            for participant in (reference, contender)
            if participant.startswith("flyology-db-")
        }
        if {row.get("participant") for row in configurations} != expected_flyology:
            raise RuntimeError(f"execution configuration inventory mismatch: {path}")
        publication_rows = []
        for row in configurations:
            participant = row["participant"]
            workers, cohorts = GEOMETRY[participant]
            transactions = row.get("transactions")
            batches = row.get("batch_publications")
            heads = row.get("head_publications")
            if (
                row.get("caller_pipeline_depth") != OUTSTANDING
                or row.get("caller_preparation_width") != 1
                or row.get("runtime_preparation_concurrency") != workers
                or row.get("runtime_pipeline_depth") != cohorts
                or type(transactions) is not int
                or transactions <= 0
                or type(batches) is not int
                or batches < (transactions + MAXIMUM_MEMBERS - 1) // MAXIMUM_MEMBERS
                or batches > transactions
                or heads != batches
                or row.get("manifest_publications") != 0
            ):
                raise RuntimeError(f"runtime or publication geometry mismatch: {path}")
            publication_rows.append(
                {
                    "participant": participant,
                    "execution_ordinal": row["execution_ordinal"],
                    "transactions": transactions,
                    "batch_publications": batches,
                    "head_publications": heads,
                }
            )
        retained.append(
            {
                "reference": reference,
                "contender": contender,
                "reference_median_ns": primary[0]["reference_median"],
                "contender_median_ns": primary[0]["contender_median"],
                "change_percent": primary[0]["change"],
                "interval_low": primary[0]["interval_low"],
                "interval_high": primary[0]["interval_high"],
                "publication_rows": publication_rows,
            }
        )
    return {
        "matrix_sha256": sha256(path),
        "classification": artifact.get("classification"),
        "host": artifact.get("host"),
        "comparisons": retained,
    }


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: foundation-screen-driver.py SOURCE ARCH OUTPUT_ROOT")
    source = Path(sys.argv[1]).resolve()
    architecture = sys.argv[2]
    output_root = Path(sys.argv[3]).resolve()
    if architecture not in ORDERS:
        raise SystemExit(f"unsupported architecture: {architecture}")
    if output_root.exists():
        raise SystemExit(f"output root already exists: {output_root}")
    lock_path = os.environ.get("FLYOLOGY_BENCH_LOCK_PATH", "")
    if not lock_path.startswith("/run/lock/"):
        raise SystemExit("host lock must be an absolute /run/lock path")
    output_root.mkdir(parents=True)

    campaign_path = source / "benchmarks" / "comparison" / "run_realistic_campaign.py"
    module_spec = importlib.util.spec_from_file_location("flyology_db_campaign", campaign_path)
    if module_spec is None or module_spec.loader is None:
        raise SystemExit("could not load maintained campaign")
    campaign = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(campaign)

    workload = {
        "id": "sustained-8960",
        "key_bytes": 16,
        "value_bytes": 1024,
        "mutations": 256,
        "transactions": TRANSACTIONS,
    }
    plan = {
        "schema": "flyology.db.benchmark.foundation-screen-plan.v1",
        "architecture": architecture,
        "warmup_transactions": 8,
        "maximum_outstanding_transactions": OUTSTANDING,
        "host_lock_path": lock_path,
        "workload": workload,
        "profiles": PROFILES,
        "runtime_geometry": {name: list(value) for name, value in GEOMETRY.items()},
        "orders": ORDERS[architecture],
        "driver_sha256": sha256(Path(__file__).resolve()),
        "maintained_campaign_sha256": sha256(campaign_path),
    }
    write_json(output_root / "plan.json", plan)

    original_identity = campaign.campaign_identity
    original_request = campaign.pair_request

    def matrix_identity(lane, pairs, workloads, power):
        identity = original_identity(lane, pairs, workloads, power)
        identity["foundation_screen"] = {
            "architecture": architecture,
            "warmup_transactions": 8,
            "driver_sha256": plan["driver_sha256"],
            "plan_sha256": sha256(output_root / "plan.json"),
        }
        return identity

    def matrix_request(
        campaign_record,
        identity,
        workload_record,
        reference,
        contender,
        json_path,
        metrics_path,
    ):
        request = original_request(
            campaign_record,
            identity,
            workload_record,
            reference,
            contender,
            json_path,
            metrics_path,
        )
        request["environment"]["FLYOLOGY_DB_BENCH_WARMUP"] = "8"
        request["environment"]["FLYOLOGY_BENCH_LOCK_PATH"] = lock_path
        return request

    campaign.campaign_identity = matrix_identity
    campaign.pair_request = matrix_request
    campaign.WORKLOADS = (workload,)
    os.environ["FLYOLOGY_DB_BENCH_WARMUP"] = "8"

    rounds = []
    for number, order in enumerate(ORDERS[architecture], start=1):
        campaign.LOCAL_PAIRS = tuple(COMPARISONS[name] for name in order)
        round_path = output_root / f"round-{number}.json"
        campaign.collect("local", round_path, False)
        rounds.append({"round": number, "order": order, **validate_round(round_path)})
    write_json(
        output_root / "validated-summary.json",
        {
            "schema": "flyology.db.benchmark.foundation-screen-summary.v1",
            "architecture": architecture,
            "plan_sha256": sha256(output_root / "plan.json"),
            "rounds": rounds,
        },
    )
    print("Flyology.DB exploratory foundation screen passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
