#!/usr/bin/env python3
"""Classify retained whole-process CPU samples under DB transaction preparation."""

import argparse
from collections import Counter
import json
from pathlib import Path


PREPARE = "flyology_db_benchmark_flyology__prepare_transaction"
KEY = "flyology_db_benchmark_flyology__key_for"
VALUE = "flyology_db_benchmark_flyology__value_for"
STORE = "flyology__db__store_mutation"
EVENT = "cpu-clock/period=250000/u"


def frames_of(lines):
    if not lines or EVENT not in lines[0]:
        return []
    frames = []
    for line in lines[1:]:
        pieces = line.strip().split(" ", 1)
        if len(pieces) != 2 or not pieces[0].isalnum():
            continue
        frames.append(pieces[1].split(" (", 1)[0].rsplit("+0x", 1)[0])
    return frames


def analyze(path):
    total = 0
    preparation = 0
    category = Counter()
    leaves = Counter()
    current = []

    def consume(lines):
        nonlocal total, preparation
        frames = frames_of(lines)
        if not frames:
            return
        total += 1
        if not any(PREPARE in frame for frame in frames):
            return
        preparation += 1
        leaves[frames[0]] += 1
        if any(VALUE in frame for frame in frames):
            category["fixture_value_for"] += 1
        elif any(KEY in frame for frame in frames):
            category["fixture_key_for"] += 1
        elif any(STORE in frame for frame in frames):
            category["db_store_mutation"] += 1
        else:
            category["other_preparation"] += 1

    with path.open(encoding="utf-8") as stream:
        for line in stream:
            if EVENT in line and not line[:1].isspace():
                consume(current)
                current = [line]
            elif current and line.strip():
                current.append(line)
        consume(current)
    if total < 1000 or preparation < 100:
        raise ValueError("retained CPU sample capture is too small")
    if sum(category.values()) != preparation:
        raise ValueError("preparation samples were not partitioned")
    return {
        "schema": "flyology.db.benchmark.direct_preparation_cpu_samples.v1",
        "scope": "whole_process_including_warmup; sampled_user_cpu_not_wall_time",
        "source": str(path),
        "event": EVENT,
        "all_cpu_samples": total,
        "prepare_transaction_stack_samples": preparation,
        "categories": dict(sorted(category.items())),
        "top_preparation_leaf_counts": leaves.most_common(25),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("perf_script", type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.perf_script), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
