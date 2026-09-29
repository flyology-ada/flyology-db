#!/usr/bin/env python3
"""One exact-state paired diagnostic; timings are instrumented, not promotion data."""

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path


REFERENCE = "slatedb-1ms-depth32"
CONTENDER = (
    "flyology-db-files-adaptive-cohort-members8-bytes2159008-"
    "wait-us1000-depth32-workers1-cohorts1-diagnostics"
)
EXPECTED_STATE = "090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: run-admission-x86.py SOURCE OUTPUT_ROOT")
    source = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    require(not output.exists(), "output root already exists")
    lock_path = os.environ.get("FLYOLOGY_BENCH_LOCK_PATH", "")
    require(lock_path.startswith("/run/lock/"), "host lock path is not established")

    campaign_path = source / "benchmarks/comparison/run_realistic_campaign.py"
    module_spec = importlib.util.spec_from_file_location("flyology_db_campaign", campaign_path)
    require(module_spec is not None and module_spec.loader is not None,
            "maintained campaign cannot be imported")
    campaign = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(campaign)
    campaign.POWER_DETECTOR = Path(__file__).resolve().parent / "check-power-profile.sh"
    workload = {
        "id": "sustained-8960",
        "key_bytes": 16,
        "value_bytes": 1024,
        "mutations": 256,
        "transactions": 35,
    }
    output.mkdir(parents=True)
    (output / "plan.json").write_text(json.dumps({
        "schema": "flyology.db.benchmark.admission_diagnostic_plan.v1",
        "workload": workload,
        "warmup_transactions": 8,
        "reference": REFERENCE,
        "contender": CONTENDER,
        "source_diff_sha256": "9882967037fe38e83b08c0e151b829dfbb600e54ea9708a255ee2d7ad27127c2",
        "campaign_sha256": sha256(campaign_path),
        "driver_sha256": sha256(Path(__file__)),
        "classification": "instrumented_diagnostic_not_promotion_timing",
    }, indent=2, sort_keys=True) + "\n")

    original_request = campaign.pair_request

    def diagnostic_request(campaign_record, identity, workload_record, reference,
                           contender, json_path, metrics_path):
        request = original_request(campaign_record, identity, workload_record, reference,
                                   contender, json_path, metrics_path)
        request["environment"]["FLYOLOGY_DB_BENCH_WARMUP"] = "8"
        request["environment"]["FLYOLOGY_DB_BENCH_COMMIT_DIAGNOSTICS"] = "1"
        request["environment"]["FLYOLOGY_BENCH_LOCK_PATH"] = lock_path
        return request

    campaign.pair_request = diagnostic_request
    campaign.WORKLOADS = (workload,)
    campaign.LOCAL_PAIRS = ((REFERENCE, CONTENDER),)
    os.environ["FLYOLOGY_DB_BENCH_WARMUP"] = "8"
    campaign.collect("local", output / "pair.json", False)

    paired = json.loads((output / "pair.json").read_text())
    records = paired.get("records", [])
    require(len(records) == 1, "expected one maintained paired record")
    raw_metrics = records[0]["raw"]["metrics"]
    require(isinstance(raw_metrics, str) and Path(raw_metrics).name == raw_metrics,
            "raw metrics path is not a relative filename")
    metrics_path = output / "pair-raw" / raw_metrics
    require(metrics_path.is_file(), "maintained raw metrics file is absent")
    rows = [json.loads(line) for line in metrics_path.read_text().splitlines() if line]
    state = [row for row in rows
             if row.get("schema") == "flyology.db.benchmark.state_verification.v1"]
    pairs = [row for row in rows
             if row.get("schema") == "flyology.db.benchmark.paired_primary_sample.v1"]
    traces = [row for row in rows
              if row.get("schema") == "flyology.db.benchmark.admission_trace.v1"]
    require(len(state) == 22 and len(pairs) == 10 and len(traces) == 11,
            "calibration/measured evidence count changed")
    require(all(row.get("state_sha256") == EXPECTED_STATE
                and row.get("expected_state_sha256") == EXPECTED_STATE
                and row.get("verified_keys") == 11008 for row in state),
            "exact reopened state changed")
    require(sum(row["reference_execution_ordinal"] < row["contender_execution_ordinal"]
                for row in pairs) == 5,
            "maintained order is not balanced")
    require(all(len(row.get("entries", [])) == 35 for row in traces),
            "diagnostic admission trace is incomplete")
    print("Flyology.DB isolated paired admission diagnostic passed", flush=True)


if __name__ == "__main__":
    main()
