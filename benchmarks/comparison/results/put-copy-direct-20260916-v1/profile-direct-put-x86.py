#!/usr/bin/env python3
"""One owned CPU-sample diagnosis of the existing direct-copy x86 binary."""

import fcntl
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ROOT = Path("/mnt/flyology-bench/experiments/put-copy-direct-20260916-v1-x86_64")
SCREEN = load("put_copy_screen", ROOT / "screen-x86.py")
ANALYZE = load("put_cpu_analyzer", ROOT / "analyze-put-cpu.py")
OUT = ROOT / "evidence/direct-put-cpu-v1"
SCRATCH = ROOT / "direct-put-cpu-scratch-v1"
PANEL = ROOT / "source/benchmarks/comparison/bin/flyology_db_benchmark_panel"
SOURCE = ROOT / "source"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    require(not OUT.exists() and not SCRATCH.exists(), "profile output/scratch already exists")
    require(digest(PANEL) == "c60815178eece0dea36d099c0de75f02ad1bad40d51e809e3814783f09067f73",
            "direct benchmark executable drifted")
    require(digest(SCREEN.SLATE / "libflyology_db_slatedb_benchmark.so")
            == "11e19eb0a904bfd56f82f2010d45a3de79a6ba866680d1c03fa5eff63178409e",
            "Slate library drifted")
    changed = subprocess.run(["git", "-C", str(SOURCE), "diff", "--binary", "HEAD", "--"],
                             capture_output=True, check=True)
    require(hashlib.sha256(changed.stdout).hexdigest()
            == "5e9b4cf6e1b41e51b80daa34d9108d6d32e45f9b0fb782c225064d7067267df2",
            "direct source drifted")
    head = subprocess.run(["git", "-C", str(SOURCE), "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()
    require(head == "613ad2b054725e99b73117f03ae38e213fdfaef7", "source base differs")
    require(str(SOURCE / "src/flyology-db.adb")
            in (ROOT / "evidence/gpr-source-map.txt").read_text(), "source map differs")
    require(subprocess.run(["perf", "--version"], capture_output=True, text=True,
                           check=True).stdout.strip() == "perf version 7.0.14", "perf version differs")
    for name in ("alr", "gprbuild", "gnat1", "cargo", "rustc", "perf"):
        require(subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 1,
                f"competing process: {name}")
    with Path("/run/lock/flyology-db-aws-campaign.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        OUT.mkdir(parents=True)
        SCRATCH.mkdir()
        SCREEN.OUT = OUT
        environment = os.environ.copy()
        environment.update({
            "TMPDIR": str(SCRATCH),
            "FLYOLOGY_DB_BENCH_SCRATCH_ROOT": str(SCRATCH),
            "FLYOLOGY_DB_BENCH_NAMESPACE": "direct-put-cpu-v1",
            "FLYOLOGY_DB_BENCH_WARMUP": "8",
            "FLYOLOGY_DB_BENCH_COMMIT_DIAGNOSTICS": "0",
            "FLYOLOGY_BENCH_LOCK_PATH": "/run/lock/flyology-bench-host-cpu.lock",
            "LD_LIBRARY_PATH": (f"{SCREEN.SLATE}:{SCREEN.TIDES}:"
                                f"{SCREEN.TIDES / 'upstream'}"),
        })
        before = SCREEN.check_power("before")
        argv = ["perf", "record", "--clockid", "mono", "-e", "cpu-clock/period=250000/u",
                "--call-graph", "dwarf,8192", "-o", str(OUT / "perf.data"), "--",
                str(PANEL), SCREEN.REFERENCE, SCREEN.CONTENDER,
                "16", "1024", "256", "35", str(OUT / "pair.json"),
                str(OUT / "metrics.ndjson")]
        SCREEN.run_owned(argv, environment, OUT / "perf-record.log", 600)
        lines = (OUT / "perf-record.log").read_text(encoding="utf-8").splitlines()
        allowed = (r"\[ perf record: Woken up [0-9]+ times to write data \]",
                   r"\[ perf record: Captured and wrote [0-9]+\.[0-9]+ MB .+ "
                   r"\([0-9]+ samples\) \]")
        require(lines and all(any(re.fullmatch(pattern, line) for pattern in allowed)
                              for line in lines), "perf record emitted unexpected diagnostic")
        require(not any(SCRATCH.iterdir()), "benchmark scratch residue")
        after = SCREEN.check_power("after")
        require(before == after, "power detector changed")
        require((OUT / "perf.data").stat().st_size > 0, "perf data missing")
        campaign = load("flyology_db_campaign",
                        SOURCE / "benchmarks/comparison/run_realistic_campaign.py")
        metrics = SCREEN.inspect_metrics(OUT / "pair.json", OUT / "metrics.ndjson",
                                         campaign.load_pair)
        script = subprocess.run(
            ["perf", "script", "--show-lost-events", "--ns", "-i", str(OUT / "perf.data"),
             "-F", "+pid,+tid,+period"], capture_output=True, text=True, check=True)
        require(not script.stderr, "perf script emitted diagnostic")
        require("PERF_RECORD_LOST" not in script.stdout, "perf samples lost")
        require(re.search(r"\bLOST [1-9][0-9]* events\b", script.stdout) is None,
                "perf samples lost")
        (OUT / "samples.txt").write_text(script.stdout, encoding="utf-8")
        ranking = ANALYZE.analyze(OUT / "samples.txt")
        summary = {
            "schema": "flyology.db.benchmark.direct_put_cpu_diagnosis.v1",
            "classification": "whole_process_cpu_samples_not_removable_wall_time",
            "power": before,
            "binary_sha256": digest(PANEL),
            "source_diff_sha256": hashlib.sha256(changed.stdout).hexdigest(),
            "metrics": metrics,
            "ranking": ranking,
        }
        require(not any(SCRATCH.iterdir()), "final scratch residue")
        require(digest(PANEL)
                == "c60815178eece0dea36d099c0de75f02ad1bad40d51e809e3814783f09067f73",
                "panel changed during profile")
        require(digest(SCREEN.SLATE / "libflyology_db_slatedb_benchmark.so")
                == "11e19eb0a904bfd56f82f2010d45a3de79a6ba866680d1c03fa5eff63178409e",
                "Slate library changed during profile")
        current = subprocess.run(["git", "-C", str(SOURCE), "diff", "--binary", "HEAD", "--"],
                                 capture_output=True, check=True).stdout
        require(hashlib.sha256(current).hexdigest() == summary["source_diff_sha256"],
                "source changed during profile")
        current_head = subprocess.run(["git", "-C", str(SOURCE), "rev-parse", "HEAD"],
                                      capture_output=True, text=True, check=True).stdout.strip()
        require(current_head == head, "source base changed during profile")
        (OUT / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        print("Flyology.DB direct Put CPU diagnosis passed", flush=True)


if __name__ == "__main__":
    main()
