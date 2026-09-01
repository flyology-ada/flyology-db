#!/usr/bin/env python3
"""Validate and summarize the retained exact-owned batch-image A/B CSV."""

import csv
import hashlib
import json
import random
import statistics
import sys
from pathlib import Path


def percentile(values: list[float], fraction: float) -> float:
    index = min(len(values) - 1, int(fraction * len(values)))
    return values[index]


def main() -> None:
    source = Path(sys.argv[1])
    raw = source.read_bytes()
    rows = list(csv.DictReader(raw.decode("ascii").splitlines()))
    expected_smoke = [
        ("1", "control"),
        ("1", "candidate"),
        ("2", "control"),
        ("2", "candidate"),
        ("4", "control"),
        ("4", "candidate"),
        ("8", "control"),
        ("8", "candidate"),
    ]
    if len(rows) != 40:
        raise SystemExit(f"expected 40 rows, found {len(rows)}")
    if [(row["group_size"], row["variant"]) for row in rows[:8]] != expected_smoke:
        raise SystemExit("the first eight rows do not match the maintained smoke order")

    state = "5283189c4531950d9f91a1aff1212a3cd36d69a2768ee759aa801ee3471b79a9"
    for row in rows:
        if row["verified_keys"] != "10240" or row["state_sha256"] != state:
            raise SystemExit("work or final-state mismatch")
        if int(row["batch_objects"]) != 40 // int(row["group_size"]):
            raise SystemExit("batch-object geometry mismatch")

    measured = rows[8:]
    expected_schedule: list[tuple[str, str, str, str]] = []
    for cycle in range(1, 9):
        first, second = (
            ("control", "candidate") if cycle % 2 == 1 else ("candidate", "control")
        )
        expected_schedule.extend(
            [
                (str(cycle), "1", "1", first),
                (str(cycle), "2", "1", second),
                (str(cycle), "3", "8", first),
                (str(cycle), "4", "8", second),
            ]
        )
    actual_schedule = [
        (row["cycle"], row["ordinal"], row["group_size"], row["variant"])
        for row in measured
    ]
    if actual_schedule != expected_schedule:
        raise SystemExit("measured rows do not match the maintained balanced A/B schedule")

    output: dict[str, object] = {
        "measurements_sha256": hashlib.sha256(raw).hexdigest(),
        "smoke_rows": 8,
        "measured_rows": 32,
        "within_geometry_schedule_validated": True,
        "cross_geometry_order_balanced": False,
        "verified_keys_per_run": 10240,
        "state_sha256": state,
        "groups": {},
    }
    for group_size in (1, 8):
        by_cycle: dict[int, dict[str, dict[str, str]]] = {}
        for row in measured:
            if int(row["group_size"]) == group_size:
                by_cycle.setdefault(int(row["cycle"]), {})[row["variant"]] = row
        if sorted(by_cycle) != list(range(1, 9)):
            raise SystemExit(f"group {group_size} lacks the eight balanced cycles")

        pairs: list[tuple[int, int]] = []
        gains: list[float] = []
        for cycle in sorted(by_cycle):
            pair = by_cycle[cycle]
            if set(pair) != {"control", "candidate"}:
                raise SystemExit(f"group {group_size} cycle {cycle} is not a complete pair")
            control = pair["control"]
            candidate = pair["candidate"]
            if control["batch_digest"] != candidate["batch_digest"]:
                raise SystemExit(f"group {group_size} cycle {cycle} has different batch bytes")
            control_ns = int(control["elapsed_nanoseconds"])
            candidate_ns = int(candidate["elapsed_nanoseconds"])
            pairs.append((control_ns, candidate_ns))
            gains.append((control_ns - candidate_ns) * 100.0 / control_ns)

        generator = random.Random(20260901 + group_size)
        bootstrap = []
        for _ in range(200_000):
            sample = [gains[generator.randrange(len(gains))] for _ in gains]
            bootstrap.append(statistics.median(sample))
        bootstrap.sort()
        output["groups"][str(group_size)] = {
            "control_median_ms": statistics.median(pair[0] for pair in pairs) / 1_000_000.0,
            "candidate_median_ms": statistics.median(pair[1] for pair in pairs) / 1_000_000.0,
            "paired_gain_median_percent": statistics.median(gains),
            "paired_gain_min_percent": min(gains),
            "paired_gain_max_percent": max(gains),
            "paired_gain_bootstrap_95_percent": [
                percentile(bootstrap, 0.025),
                percentile(bootstrap, 0.975),
            ],
            "wins": sum(candidate < control for control, candidate in pairs),
            "pairs": len(pairs),
            "batch_objects_per_run": 40 // group_size,
            "batch_digest": by_cycle[1]["control"]["batch_digest"],
        }

    print(json.dumps(output, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
