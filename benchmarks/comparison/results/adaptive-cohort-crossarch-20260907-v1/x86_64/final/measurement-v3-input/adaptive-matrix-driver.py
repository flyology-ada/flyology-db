#!/usr/bin/env python3
"""Run the fixed adaptive-cohort comparison matrix on one native host."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: adaptive-matrix-driver.py SOURCE ARCH OUTPUT_ROOT")
    source = Path(sys.argv[1]).resolve()
    architecture = sys.argv[2]
    output_root = Path(sys.argv[3]).resolve()
    lock_path = os.environ.get("FLYOLOGY_BENCH_LOCK_PATH", "")
    if architecture not in ("x86_64", "arm64"):
        raise SystemExit(f"unsupported matrix architecture: {architecture}")
    if not lock_path.startswith("/run/lock/"):
        raise SystemExit("FLYOLOGY_BENCH_LOCK_PATH must name an absolute /run/lock path")
    if output_root.exists():
        raise SystemExit(f"matrix output already exists: {output_root}")
    output_root.mkdir(parents=True)

    campaign_path = source / "benchmarks" / "comparison" / "run_realistic_campaign.py"
    module_spec = importlib.util.spec_from_file_location("flyology_db_campaign", campaign_path)
    if module_spec is None or module_spec.loader is None:
        raise SystemExit("could not load the maintained benchmark campaign module")
    campaign = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(campaign)

    adaptive = (
        "flyology-db-files-adaptive-cohort-members8-"
        "bytes2159008-wait-us1000-depth8-waves"
    )
    comparisons = {
        "P": ("flyology-db-files", adaptive),
        "Q": ("flyology-db-files-singleton-depth8-waves", adaptive),
        "R": ("slatedb-1ms-depth8-waves", adaptive),
    }
    orders = {
        "x86_64": (("P", "Q", "R"), ("Q", "R", "P"), ("R", "P", "Q")),
        "arm64": (("R", "Q", "P"), ("Q", "P", "R"), ("P", "R", "Q")),
    }
    workload = {
        "id": "sustained-8960",
        "key_bytes": 16,
        "value_bytes": 1024,
        "mutations": 256,
        "transactions": 35,
    }
    driver_path = Path(__file__).resolve()
    plan = {
        "schema": "flyology.db.benchmark.adaptive-crossarch-plan.v1",
        "architecture": architecture,
        "warmup_transactions": 8,
        "host_lock_path": lock_path,
        "workload": workload,
        "comparisons": comparisons,
        "orders": orders[architecture],
        "driver_sha256": sha256(driver_path),
        "maintained_campaign_sha256": sha256(campaign_path),
    }
    (output_root / "plan.json").write_text(
        json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="ascii"
    )

    original_identity = campaign.campaign_identity
    original_request = campaign.pair_request

    def matrix_identity(lane, pairs, workloads, power):
        identity = original_identity(lane, pairs, workloads, power)
        identity["adaptive_matrix"] = {
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

    for repetition, order in enumerate(orders[architecture], start=1):
        campaign.LOCAL_PAIRS = tuple(comparisons[name] for name in order)
        campaign.collect("local", output_root / f"round-{repetition}.json", False)

    print("Flyology.DB adaptive cross-architecture matrix passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
