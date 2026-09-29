#!/usr/bin/env python3
"""Exploratory, exact-state paired screen of two isolated DB binaries."""

import fcntl
import hashlib
import importlib.util
import json
import os
import signal
import statistics
import subprocess
import sys
from pathlib import Path


ROOT = Path("/mnt/flyology-bench/experiments/put-copy-direct-20260916-v1-x86_64")
PRIOR = Path("/mnt/flyology-bench/experiments/admission-attribution-20260916-v1-x86_64")
BASELINE = PRIOR / "source/benchmarks/comparison/bin/flyology_db_benchmark_panel"
DIRECT = ROOT / "source/benchmarks/comparison/bin/flyology_db_benchmark_panel"
SLATE = ROOT / "source/benchmarks/comparison/slatedb/target/release"
TIDES = ROOT / "source/oracles/adapters/tidesdb/build"
DETECTOR = PRIOR / "check-power-profile.sh"
OUT = ROOT / "evidence/paired-screen-v1"
SCRATCH = ROOT / "scratch"
EXPECTED_STATE = "090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb"
REFERENCE = "slatedb-1ms-depth32"
CONTENDER = (
    "flyology-db-files-adaptive-cohort-members8-bytes2159008-"
    "wait-us1000-depth32-workers1-cohorts1"
)
ORDER = ("baseline", "direct", "direct", "baseline",
         "direct", "baseline", "baseline", "direct")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_owned(argv, environment, log_path, timeout):
    process = subprocess.Popen(
        argv, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as failure:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
        log_path.write_text(output, encoding="utf-8")
        raise RuntimeError(f"panel did not complete: {type(failure).__name__}: {argv[0]}")
    log_path.write_text(output, encoding="utf-8")
    require(process.returncode == 0, f"nonzero {process.returncode}: {argv[0]}")
    children = subprocess.run(["pgrep", "-g", str(process.pid)], capture_output=True, text=True,
                              check=False)
    require(children.returncode == 1, f"panel process group still has children: {children.stdout}")
    return output


def check_power(label):
    result = subprocess.run([str(DETECTOR)], text=True, capture_output=True, check=False)
    require(result.returncode in (0, 2), "reduced or invalid power profile")
    require(not result.stderr, "power detector emitted stderr")
    (OUT / f"power-{label}.env").write_text(result.stdout, encoding="utf-8")
    return {"status": result.returncode, "output": result.stdout}


def inspect_metrics(json_path, path, validator):
    validator(json_path, path, REFERENCE, CONTENDER)
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    states = [row for row in rows
              if row.get("schema") == "flyology.db.benchmark.state_verification.v1"]
    pairs = [row for row in rows
             if row.get("schema") == "flyology.db.benchmark.paired_primary_sample.v1"]
    configs = [row for row in rows
               if row.get("schema") == "flyology.db.benchmark.execution_configuration.v1"]
    require(len(states) == 22 and len(pairs) == 10, "wrong state or pair count")
    require(sum(row["first"] == "reference" for row in pairs) == 5,
            "Slate/DB order is not balanced")
    require(all(row.get("state_sha256") == EXPECTED_STATE
                and row.get("expected_state_sha256") == EXPECTED_STATE
                and row.get("verified_keys") == 11008
                and row.get("warmup_transactions") == 8
                and row.get("transactions") == 35
                and row.get("mutations_per_transaction") == 256
                for row in states), "reopened state mismatch")
    measured = {row["contender_execution_ordinal"] for row in pairs}
    require(len(measured) == 10, "duplicate measured execution")
    require(all(row.get("reference") == REFERENCE and row.get("contender") == CONTENDER
                and row.get("transactions_per_operation") == 35
                and row.get("reference_iterations") == 1
                and row.get("contender_iterations") == 1
                for row in pairs), "paired workload geometry changed")
    selected = [row for row in configs if row.get("execution_ordinal") in measured]
    require(len(selected) == 10, "measured configuration missing")
    require(all(row.get("transactions") == 35
                and row.get("manifest_publications") == 0
                and row.get("batch_publications") == row.get("head_publications")
                and 1 <= row.get("batch_publications", -1) <= 35
                for row in selected), "publication geometry changed")
    require(not any(row.get("schema") == "flyology.db.benchmark.admission_trace.v1"
                    for row in rows), "diagnostic instrumentation unexpectedly enabled")
    db = [float(row["contender_primary_ns_per_operation"]) / 1e6 for row in pairs]
    slate = [float(row["reference_primary_ns_per_operation"]) / 1e6 for row in pairs]
    require(all(value > 0 for value in db + slate), "nonpositive primary timing")
    return {"db_ms": db, "slate_ms": slate,
            "db_median_ms": statistics.median(db),
            "slate_median_ms": statistics.median(slate),
            "batch_counts": [row["batch_publications"] for row in selected]}


def main():
    require(len(sys.argv) == 1, "this script accepts no overrides")
    require(not OUT.exists() and not SCRATCH.exists(), "output or scratch already exists")
    require(digest(BASELINE) == "c3541db1a5ed46836ad1d1b03502f2682460b7f99cf483a2b1fc80d3f695af65",
            "baseline binary changed")
    require(digest(DIRECT) == "c60815178eece0dea36d099c0de75f02ad1bad40d51e809e3814783f09067f73",
            "direct binary changed")
    require(digest(SLATE / "libflyology_db_slatedb_benchmark.so")
            == "11e19eb0a904bfd56f82f2010d45a3de79a6ba866680d1c03fa5eff63178409e",
            "Slate library changed")
    require(digest(ROOT / "source/src/flyology-db.adb")
            == digest(ROOT / "source/benchmarks/comparison/.deps/flyology_db-fca74780/src/flyology-db.adb"),
            "nested source differs")
    require(DETECTOR.is_file(), "power detector missing")
    baseline_source = PRIOR / "source"
    direct_source = ROOT / "source"
    def tracked_diff(source):
        output = subprocess.run(["git", "-C", str(source), "diff", "--binary", "HEAD", "--"],
                                capture_output=True, check=True).stdout
        return hashlib.sha256(output).hexdigest()
    require(tracked_diff(baseline_source)
            == "b4850b89330e9489d84e63c166410c6da9ffb2f515b0cda43dff0e794df902a3",
            "baseline source drifted")
    for source in (baseline_source, direct_source):
        head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
        require(head == "613ad2b054725e99b73117f03ae38e213fdfaef7",
                "benchmark source base changed")
    require(tracked_diff(direct_source)
            == "5e9b4cf6e1b41e51b80daa34d9108d6d32e45f9b0fb782c225064d7067267df2",
            "direct source drifted")
    changed = subprocess.run(["git", "-C", str(direct_source), "diff", "--name-only", "HEAD", "--"],
                             capture_output=True, text=True, check=True).stdout.splitlines()
    baseline_changed = subprocess.run(
        ["git", "-C", str(baseline_source), "diff", "--name-only", "HEAD", "--"],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    require(changed == baseline_changed and "src/flyology-db.adb" in changed,
            "source change inventory differs")
    require(all((baseline_source / path).read_bytes() == (direct_source / path).read_bytes()
                for path in changed if path != "src/flyology-db.adb"),
            "source changed outside the copy body")
    source_map = (ROOT / "evidence/gpr-source-map.txt").read_text(encoding="utf-8")
    build_log = ROOT / "evidence/benchmark-build.log"
    require("Success: Build finished successfully" in build_log.read_text(encoding="utf-8"),
            "benchmark build did not finish")
    require(str(direct_source / "src/flyology-db.adb") in source_map
            and str(direct_source / "benchmarks/comparison/src/flyology_db_benchmark_flyology.adb")
            in source_map
            and str(baseline_source / "src/flyology-db.adb") not in source_map,
            "GPR selected wrong source")
    campaign_path = direct_source / "benchmarks/comparison/run_realistic_campaign.py"
    spec = importlib.util.spec_from_file_location("flyology_db_campaign", campaign_path)
    require(spec is not None and spec.loader is not None, "maintained validator unavailable")
    campaign = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(campaign)
    with Path("/run/lock/flyology-db-aws-campaign.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        OUT.mkdir(parents=True)
        SCRATCH.mkdir()
        environment = os.environ.copy()
        environment.update({
            "TMPDIR": str(SCRATCH),
            "FLYOLOGY_DB_BENCH_SCRATCH_ROOT": str(SCRATCH),
            "FLYOLOGY_BENCH_LOCK_PATH": "/run/lock/flyology-bench-host-cpu.lock",
            "FLYOLOGY_DB_BENCH_WARMUP": "8",
            "FLYOLOGY_DB_BENCH_COMMIT_DIAGNOSTICS": "0",
            "LD_LIBRARY_PATH": f"{SLATE}:{TIDES}:{TIDES / 'upstream'}",
        })
        records = []
        for index, condition in enumerate(ORDER, start=1):
            require(not any(SCRATCH.iterdir()), "scratch residue before panel")
            conflicts = []
            for name in ("alr", "gprbuild", "gnat1", "cargo", "rustc", "perf"):
                result = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True,
                                        check=False)
                require(result.returncode in (0, 1), f"process audit failed for {name}")
                if result.returncode == 0:
                    conflicts.append((name, result.stdout))
            require(not conflicts, f"host is not quiet: {conflicts}")
            power = check_power(f"{index:02}-before")
            binary = BASELINE if condition == "baseline" else DIRECT
            json_path = OUT / f"{index:02}-{condition}.json"
            metrics_path = OUT / f"{index:02}-{condition}.metrics.ndjson"
            environment["FLYOLOGY_DB_BENCH_NAMESPACE"] = f"put-copy-screen-{index:02}"
            run_owned([
                str(binary), REFERENCE, CONTENDER, "16", "1024", "256", "35",
                str(json_path), str(metrics_path),
            ], environment, OUT / f"{index:02}-{condition}.log", 300)
            require(json_path.is_file() and metrics_path.is_file(), "panel outputs missing")
            require(not any(SCRATCH.iterdir()), "scratch residue after panel")
            after_power = check_power(f"{index:02}-after")
            require(power == after_power, "power detector changed during panel")
            metrics = inspect_metrics(json_path, metrics_path, campaign.load_pair)
            records.append({"index": index, "condition": condition, "power": power,
                            "binary_sha256": digest(binary), "json_sha256": digest(json_path),
                            "metrics_sha256": digest(metrics_path),
                            "host_load_average": os.getloadavg(), **metrics})
            print(f"{index:02} {condition} db={metrics['db_median_ms']:.3f} ms ",
                  f"slate={metrics['slate_median_ms']:.3f} ms", flush=True)
        require(not any(SCRATCH.iterdir()), "scratch residue at end")
        require(len(records) == len(ORDER), "incomplete order")
        power_signatures = {(row["power"]["status"], row["power"]["output"])
                            for row in records}
        require(len(power_signatures) == 1, "detected power state changed")
        baseline = [value for row in records if row["condition"] == "baseline"
                    for value in row["db_ms"]]
        direct = [value for row in records if row["condition"] == "direct"
                  for value in row["db_ms"]]
        result = {
            "schema": "flyology.db.benchmark.put_copy_screen.v1",
            "classification": "exploratory_unknown_power_profile",
            "order": ORDER,
            "workload": {"transactions": 35, "mutations": 256, "key_bytes": 16,
                         "value_bytes": 1024, "warmup_transactions": 8},
            "expected_reopened_keys": 11008,
            "expected_state_sha256": EXPECTED_STATE,
            "baseline_source_diff_sha256": tracked_diff(baseline_source),
            "direct_source_diff_sha256": tracked_diff(direct_source),
            "benchmark_build_log_sha256": digest(build_log),
            "gpr_source_map_sha256": digest(ROOT / "evidence/gpr-source-map.txt"),
            "baseline_median_ms": statistics.median(baseline),
            "direct_median_ms": statistics.median(direct),
            "improvement_fraction": 1 - statistics.median(direct) / statistics.median(baseline),
            "records": records,
        }
        (OUT / "summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n",
                                          encoding="utf-8")
        print("Flyology.DB exact-state x86 direct-copy screen passed", flush=True)


if __name__ == "__main__":
    main()
