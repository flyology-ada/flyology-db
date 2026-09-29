#!/usr/bin/env python3
"""Rank flat CPU sample leaves only when the stack contains DB Store_Mutation."""

import argparse
from collections import Counter
import json
from pathlib import Path


STORE = "flyology__db__store_mutation"
PREPARE = "flyology_db_benchmark_flyology__prepare_transaction"


def frames_of(lines):
    if not lines or "cpu-clock/period=250000/u" not in lines[0]:
        return []
    frames = []
    for line in lines[1:]:
        pieces = line.strip().split(" ", 1)
        if len(pieces) != 2 or not pieces[0].isalnum():
            continue
        symbol = pieces[1].split(" (", 1)[0].rsplit("+0x", 1)[0]
        frames.append(symbol)
    return frames


def analyze(path):
    all_samples = 0
    prepare_samples = 0
    put_samples = 0
    put_leaves = Counter()
    put_self_offsets = Counter()
    current = []

    def consume(lines):
        nonlocal all_samples, prepare_samples, put_samples
        frames = frames_of(lines)
        if not frames:
            return
        all_samples += 1
        if any(PREPARE in frame for frame in frames):
            prepare_samples += 1
        if not any(STORE in frame for frame in frames):
            return
        put_samples += 1
        put_leaves[frames[0]] += 1
        first_line = lines[1]
        if frames[0] == STORE and STORE + "+0x" in first_line:
            offset = first_line.split(STORE + "+0x", 1)[1].split(" ", 1)[0]
            put_self_offsets[offset] += 1

    with path.open() as stream:
        for line in stream:
            if "cpu-clock/period=250000/u" in line and not line[:1].isspace():
                consume(current)
                current = [line]
            elif current and line.strip():
                current.append(line)
        consume(current)
    if all_samples < 1000 or put_samples < 10:
        raise ValueError("Put CPU sample capture is too small for ranking")
    return {
        "schema": "flyology.db.benchmark.put_cpu_sample_ranking.v1",
        "scope": "whole_process_including_warmup; user_cpu_only; not removable_time",
        "source": str(path),
        "all_cpu_samples": all_samples,
        "prepare_transaction_stack_samples": prepare_samples,
        "store_mutation_stack_samples": put_samples,
        "put_stack_leaf_counts": put_leaves.most_common(),
        "store_mutation_self_offset_counts": put_self_offsets.most_common(),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("perf_script", type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.perf_script), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
