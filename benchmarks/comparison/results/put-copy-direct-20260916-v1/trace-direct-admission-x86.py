#!/usr/bin/env python3
"""One current-source admission diagnostic, not promotion timing evidence."""

import fcntl
import hashlib
import importlib.util
import json
import os
import statistics
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True


ROOT = Path("/mnt/flyology-bench/experiments/put-copy-direct-20260916-v1-x86_64")
SOURCE = ROOT / "source"
OUT = ROOT / "evidence/direct-admission-v1"
SCRATCH = ROOT / "direct-admission-scratch-v1"
PANEL = SOURCE / "benchmarks/comparison/bin/flyology_db_benchmark_panel"
REFERENCE = "slatedb-1ms-depth32"
CONTENDER = (
    "flyology-db-files-adaptive-cohort-members8-bytes2159008-"
    "wait-us1000-depth32-workers1-cohorts1-diagnostics"
)
EXPECTED_STATE = "090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_diff():
    result = subprocess.run(["git", "-C", str(SOURCE), "diff", "--binary", "HEAD", "--"],
                            capture_output=True, check=True)
    return hashlib.sha256(result.stdout).hexdigest()


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, "module unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    require(len(sys.argv) == 1, "no arguments accepted")
    require(not OUT.exists() and not SCRATCH.exists(), "output or scratch already exists")
    require(digest(PANEL) == "c60815178eece0dea36d099c0de75f02ad1bad40d51e809e3814783f09067f73",
            "direct benchmark executable changed")
    require(source_diff() == "5e9b4cf6e1b41e51b80daa34d9108d6d32e45f9b0fb782c225064d7067267df2",
            "direct source changed")
    head = subprocess.run(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], capture_output=True,
                          text=True, check=True).stdout.strip()
    require(head == "613ad2b054725e99b73117f03ae38e213fdfaef7", "source base changed")
    source_map = (ROOT / "evidence/gpr-source-map.txt").read_text(encoding="utf-8")
    require(str(SOURCE / "src/flyology-db.adb") in source_map, "wrong compiled source")
    screen = load("put_copy_screen", ROOT / "screen-x86.py")
    require(digest(screen.SLATE / "libflyology_db_slatedb_benchmark.so")
            == "11e19eb0a904bfd56f82f2010d45a3de79a6ba866680d1c03fa5eff63178409e",
            "Slate library changed")
    for name in ("alr", "gprbuild", "gnat1", "cargo", "rustc", "perf"):
        require(subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 1,
                f"competing process: {name}")
    campaign = load("flyology_db_campaign",
                    SOURCE / "benchmarks/comparison/run_realistic_campaign.py")
    with Path("/run/lock/flyology-db-aws-campaign.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        OUT.mkdir(parents=True)
        SCRATCH.mkdir()
        screen.OUT = OUT
        environment = os.environ.copy()
        environment.update({
            "TMPDIR": str(SCRATCH),
            "FLYOLOGY_DB_BENCH_SCRATCH_ROOT": str(SCRATCH),
            "FLYOLOGY_DB_BENCH_NAMESPACE": "direct-admission-v1",
            "FLYOLOGY_DB_BENCH_WARMUP": "8",
            "FLYOLOGY_DB_BENCH_COMMIT_DIAGNOSTICS": "1",
            "FLYOLOGY_BENCH_LOCK_PATH": "/run/lock/flyology-bench-host-cpu.lock",
            "LD_LIBRARY_PATH": f"{screen.SLATE}:{screen.TIDES}:{screen.TIDES / 'upstream'}",
        })
        before = screen.check_power("before")
        screen.run_owned([
            str(PANEL), REFERENCE, CONTENDER, "16", "1024", "256", "35",
            str(OUT / "pair.json"), str(OUT / "metrics.ndjson"),
        ], environment, OUT / "panel.log", 300)
        require(not any(SCRATCH.iterdir()), "benchmark scratch residue")
        after = screen.check_power("after")
        require(before == after, "detectable power state changed")
        campaign.load_pair(OUT / "pair.json", OUT / "metrics.ndjson", REFERENCE, CONTENDER)
        rows = [json.loads(line) for line in (OUT / "metrics.ndjson").read_text().splitlines()
                if line]
        states = [row for row in rows
                  if row.get("schema") == "flyology.db.benchmark.state_verification.v1"]
        pairs = [row for row in rows
                 if row.get("schema") == "flyology.db.benchmark.paired_primary_sample.v1"]
        traces = [row for row in rows
                  if row.get("schema") == "flyology.db.benchmark.admission_trace.v1"]
        configs = [row for row in rows
                   if row.get("schema") == "flyology.db.benchmark.execution_configuration.v1"]
        diagnostics = [row for row in rows
                       if row.get("schema") == "flyology.db.benchmark.commit_diagnostics.v1"]
        require(len(states) == 22 and len(pairs) == 10 and len(traces) == 11,
                "wrong state, pair, or trace count")
        require(all(row.get("state_sha256") == EXPECTED_STATE
                    and row.get("expected_state_sha256") == EXPECTED_STATE
                    and row.get("verified_keys") == 11008
                    and row.get("transactions") == 35
                    and row.get("mutations_per_transaction") == 256 for row in states),
                "reopened state mismatch")
        require(sum(row.get("first") == "reference" for row in pairs) == 5,
                "paired order is not balanced")
        measured = {row["contender_execution_ordinal"] for row in pairs}
        require(len(measured) == 10, "duplicate measured execution")

        def indexed(rows, label):
            result = {}
            for row in rows:
                ordinal = row.get("execution_ordinal")
                if ordinal in measured:
                    require(ordinal not in result, f"duplicate {label} execution")
                    result[ordinal] = row
            require(set(result) == measured, f"measured {label} executions missing")
            return result

        trace_by_ordinal = indexed(traces, "trace")
        config_by_ordinal = indexed(configs, "configuration")
        diagnostic_by_ordinal = indexed(diagnostics, "diagnostic")
        selected_traces = [trace_by_ordinal[key] for key in sorted(measured)]
        selected_configs = [config_by_ordinal[key] for key in sorted(measured)]
        selected_diagnostics = [diagnostic_by_ordinal[key] for key in sorted(measured)]
        require(all(len(row.get("entries", [])) == 35 for row in selected_traces),
                "incomplete admission trace")
        require(all(row.get("manifest_publications") == 0
                    and row.get("batch_publications") == row.get("head_publications")
                    for row in selected_configs), "publication geometry changed")
        adjacent = []
        eight = []
        for row in selected_traces:
            starts = [entry["commit_start_ns"] for entry in row["entries"]]
            returns = [entry["commit_return_ns"] for entry in row["entries"]]
            require(all(a <= b for a, b in zip(starts, returns)), "invalid call brackets")
            require(all(a < b for a, b in zip(starts, starts[1:])), "nonserial call order")
            adjacent.append(min(b - a for a, b in zip(starts, starts[1:])))
            eight.append(min(starts[index + 7] - returns[index]
                             for index in range(len(starts) - 7)))
        require(min(adjacent) > 0 and min(eight) > 0, "nonpositive admission span")
        require(not any(SCRATCH.iterdir()), "final scratch residue")
        require(digest(PANEL) == "c60815178eece0dea36d099c0de75f02ad1bad40d51e809e3814783f09067f73"
                and source_diff()
                == "5e9b4cf6e1b41e51b80daa34d9108d6d32e45f9b0fb782c225064d7067267df2",
                "source or executable changed during diagnostic")
        current_head = subprocess.run(["git", "-C", str(SOURCE), "rev-parse", "HEAD"],
                                      capture_output=True, text=True, check=True).stdout.strip()
        require(current_head == head, "source commit changed during diagnostic")
        require(digest(screen.SLATE / "libflyology_db_slatedb_benchmark.so")
                == "11e19eb0a904bfd56f82f2010d45a3de79a6ba866680d1c03fa5eff63178409e",
                "Slate library changed during diagnostic")
        result = {
            "schema": "flyology.db.benchmark.direct_admission_diagnostic.v1",
            "classification": "instrumented_unknown_power_not_promotion_timing",
            "binary_sha256": digest(PANEL),
            "source_diff_sha256": source_diff(),
            "power": before,
            "state_sha256": EXPECTED_STATE,
            "adjacent_call_start_min_ns_per_execution": adjacent,
            "eight_call_return_to_start_min_ns_per_execution": eight,
            "caller_preparation_ns_per_execution": [
                row["caller_preparation_ns"] for row in selected_diagnostics],
            "batch_publications_per_execution": [
                row["batch_publications"] for row in selected_configs],
            "cohort_width_counts_per_execution": [
                row["width_counts"] for row in selected_diagnostics],
            "median_caller_preparation_ms": statistics.median(
                row["caller_preparation_ns"] for row in selected_diagnostics) / 1e6,
            "median_db_window_ms": statistics.median(
                row["contender_primary_ns_per_operation"] for row in pairs) / 1e6,
        }
        (OUT / "summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print("Flyology.DB direct admission diagnostic passed", flush=True)


if __name__ == "__main__":
    main()
