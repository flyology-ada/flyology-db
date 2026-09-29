#!/usr/bin/env python3
"""Screen one versus two in-flight cohorts on the same optimized DB binary."""

import fcntl
import hashlib
import importlib.util
import json
import os
import statistics
import subprocess
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "put_copy_screen", Path(__file__).with_name("screen-x86.py"))
assert SPEC is not None and SPEC.loader is not None
SCREEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCREEN)

ROOT = SCREEN.ROOT
OUT = ROOT / "evidence/publisher-overlap-screen-v1"
SCRATCH = ROOT / "publisher-overlap-scratch-v1"
BASE_PROFILE = (
    "flyology-db-files-adaptive-cohort-members8-bytes2159008-"
    "wait-us1000-depth32-workers1-cohorts1"
)
OVERLAP_PROFILE = BASE_PROFILE[:-1] + "2"
ORDER = ("base", "overlap", "overlap", "base")


def require(condition, message):
    SCREEN.require(condition, message)


def source_diff_sha256():
    result = subprocess.run(
        ["git", "-C", str(ROOT / "source"), "diff", "--binary", "HEAD", "--"],
        capture_output=True, check=True,
    )
    return hashlib.sha256(result.stdout).hexdigest()


def main():
    require(not OUT.exists() and not SCRATCH.exists(), "result/scratch root exists")
    require(SCREEN.digest(SCREEN.DIRECT)
            == "c60815178eece0dea36d099c0de75f02ad1bad40d51e809e3814783f09067f73",
            "DB executable drifted")
    require(SCREEN.digest(SCREEN.SLATE / "libflyology_db_slatedb_benchmark.so")
            == "11e19eb0a904bfd56f82f2010d45a3de79a6ba866680d1c03fa5eff63178409e",
            "Slate library drifted")
    require(source_diff_sha256()
            == "5e9b4cf6e1b41e51b80daa34d9108d6d32e45f9b0fb782c225064d7067267df2",
            "source diff drifted")
    require((ROOT / "evidence/gpr-source-map.txt").is_file(), "source map missing")
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
            "LD_LIBRARY_PATH": f"{SCREEN.SLATE}:{SCREEN.TIDES}:{SCREEN.TIDES / 'upstream'}",
        })
        spec = importlib.util.spec_from_file_location(
            "flyology_db_campaign", ROOT / "source/benchmarks/comparison/run_realistic_campaign.py")
        require(spec is not None and spec.loader is not None, "campaign validator missing")
        campaign = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(campaign)
        records = []
        for index, condition in enumerate(ORDER, start=1):
            require(not any(SCRATCH.iterdir()), "scratch residue before arm")
            for name in ("alr", "gprbuild", "gnat1", "cargo", "rustc", "perf"):
                result = subprocess.run(["pgrep", "-x", name], capture_output=True, check=False)
                require(result.returncode == 1, f"host not quiet: {name}")
            SCREEN.OUT = OUT
            before = SCREEN.check_power(f"{index:02}-before")
            profile = BASE_PROFILE if condition == "base" else OVERLAP_PROFILE
            SCREEN.CONTENDER = profile
            json_path = OUT / f"{index:02}-{condition}.json"
            metrics_path = OUT / f"{index:02}-{condition}.metrics.ndjson"
            environment["FLYOLOGY_DB_BENCH_NAMESPACE"] = f"publisher-overlap-{index:02}"
            SCREEN.run_owned(
                [str(SCREEN.DIRECT), SCREEN.REFERENCE, profile, "16", "1024", "256", "35",
                 str(json_path), str(metrics_path)],
                environment, OUT / f"{index:02}-{condition}.log", 300,
            )
            require(not any(SCRATCH.iterdir()), "scratch residue after arm")
            after = SCREEN.check_power(f"{index:02}-after")
            require(before == after, "power detector changed during arm")
            metrics = SCREEN.inspect_metrics(json_path, metrics_path, campaign.load_pair)
            records.append({
                "index": index, "condition": condition, "profile": profile,
                "power": before, "binary_sha256": SCREEN.digest(SCREEN.DIRECT),
                "json_sha256": SCREEN.digest(json_path),
                "metrics_sha256": SCREEN.digest(metrics_path), **metrics,
            })
            print(f"{index:02} {condition} db={metrics['db_median_ms']:.3f} ms "
                  f"slate={metrics['slate_median_ms']:.3f} ms "
                  f"batches={statistics.median(metrics['batch_counts'])}", flush=True)
        require(not any(SCRATCH.iterdir()), "scratch residue at end")
        require(len({(row["power"]["status"], row["power"]["output"]) for row in records}) == 1,
                "power detector changed across arms")
        base = [value for row in records if row["condition"] == "base" for value in row["db_ms"]]
        overlap = [value for row in records if row["condition"] == "overlap"
                   for value in row["db_ms"]]
        result = {
            "schema": "flyology.db.benchmark.publisher_overlap_screen.v1",
            "classification": "exploratory_unknown_power_profile",
            "order": ORDER, "transactions": 35, "mutations_per_transaction": 256,
            "key_bytes": 16, "value_bytes": 1024, "warmup_transactions": 8,
            "expected_state_sha256": SCREEN.EXPECTED_STATE,
            "source_diff_sha256": source_diff_sha256(),
            "binary_sha256": SCREEN.digest(SCREEN.DIRECT),
            "base_median_ms": statistics.median(base),
            "overlap_median_ms": statistics.median(overlap),
            "improvement_fraction": 1 - statistics.median(overlap) / statistics.median(base),
            "records": records,
        }
        (OUT / "summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print("Flyology.DB publisher-overlap exact-state screen passed", flush=True)


if __name__ == "__main__":
    main()
