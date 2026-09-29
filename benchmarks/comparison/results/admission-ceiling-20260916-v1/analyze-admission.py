#!/usr/bin/env python3
"""Validate admission traces and describe a no-backlog scheduling sensitivity."""

import argparse
import json
import statistics
from pathlib import Path


STATE_DIGEST = "090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb"
WAIT_MICROSECONDS = (1000, 5000, 10000)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_by_ordinal(rows, schema):
    found = {}
    for row in rows:
        if row.get("schema") != schema:
            continue
        ordinal = row["execution_ordinal"]
        require(ordinal not in found, f"duplicate {schema} ordinal {ordinal}")
        found[ordinal] = row
    return found


def immediate_deadline_groups(entries, wait_ns, maximum_members):
    """Use optimistic call brackets, assuming selection at each leader deadline."""
    groups = []
    first = 0
    while first < len(entries):
        deadline = entries[first]["commit_return_ns"] + wait_ns
        last = first + 1
        while (last < len(entries)
               and last - first < maximum_members
               and entries[last]["commit_start_ns"] <= deadline):
            last += 1
        groups.append(last - first)
        first = last
    return groups


def analyze(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line]
    traces = unique_by_ordinal(rows, "flyology.db.benchmark.admission_trace.v1")
    configurations = unique_by_ordinal(rows, "flyology.db.benchmark.execution_configuration.v1")
    states = unique_by_ordinal(rows, "flyology.db.benchmark.state_verification.v1")
    paired_ordinals = {
        int(row["contender_execution_ordinal"])
        for row in rows
        if row.get("schema") == "flyology.db.benchmark.paired_primary_sample.v1"
    }
    require(traces, "no admission traces")
    require(len(paired_ordinals) == 10, "expected ten paired measured ordinals")
    result = []
    for ordinal, trace in sorted(traces.items()):
        if ordinal not in paired_ordinals:
            continue
        config = configurations.get(ordinal)
        state = states.get(ordinal)
        require(config is not None and state is not None, f"missing evidence for ordinal {ordinal}")
        count = trace["transactions"]
        entries = trace["entries"]
        require(count == 35 and len(entries) == count, f"wrong workload length at {ordinal}")
        require(config["transactions"] == count, f"configuration count mismatch at {ordinal}")
        require(config["caller_preparation_width"] == 1,
                f"not a serial caller preparation at {ordinal}")
        require(config["manifest_publications"] == 0, f"manifest write at {ordinal}")
        require(config["batch_publications"] == config["head_publications"],
                f"batch/HEAD mismatch at {ordinal}")
        require(state["state_sha256"] == STATE_DIGEST
                and state["expected_state_sha256"] == STATE_DIGEST
                and state["verified_keys"] == 11008
                and state["mutations_per_transaction"] == 256,
                f"state mismatch at {ordinal}")
        for index, entry in enumerate(entries):
            require(entry["index"] == index + 1, f"index mismatch at {ordinal}/{index}")
            fields = ("preparation_start_ns", "preparation_end_ns", "commit_start_ns",
                      "commit_return_ns", "finish_return_ns")
            times = [entry[field] for field in fields]
            require(times == sorted(times), f"nonmonotonic event order at {ordinal}/{index}")
            require(entry["sequence"] > 0 and entry["transition"] > 0,
                    f"missing receipt identity at {ordinal}/{index}")
            if index:
                previous = entries[index - 1]
                require(entry["preparation_start_ns"] >= previous["commit_return_ns"],
                        f"overlapping serial caller at {ordinal}/{index}")
                require(entry["sequence"] == previous["sequence"] + 1,
                        f"nonconsecutive sequence at {ordinal}/{index}")
                require(entry["transition"] in (previous["transition"],
                                                previous["transition"] + 1),
                        f"nonconsecutive transition at {ordinal}/{index}")
        transitions = [entry["transition"] for entry in entries]
        observed = len(set(transitions))
        require(observed == config["batch_publications"],
                f"receipt/publication mismatch at {ordinal}: {observed}")
        fixed_group_window_ns = max(
            entries[min(first + 7, count - 1)]["commit_start_ns"]
            - entries[first]["commit_return_ns"]
            for first in range(0, count, 8)
        )
        groups = {
            str(wait_us): immediate_deadline_groups(entries, wait_us * 1000, 8)
            for wait_us in WAIT_MICROSECONDS
        }
        result.append({
            "execution_ordinal": ordinal,
            "observed_batch_head_pairs": observed,
            "serial_last_commit_return_ms": round(entries[-1]["commit_return_ns"] / 1e6, 3),
            "serial_last_preparation_end_ms": round(entries[-1]["preparation_end_ns"] / 1e6, 3),
            "last_finish_return_ms": round(max(e["finish_return_ns"] for e in entries) / 1e6, 3),
            "fixed_8_8_8_8_3_call_start_window_ms": round(max(0, fixed_group_window_ns) / 1e6, 3),
            "immediate_deadline_groups_by_wait_us": groups,
        })
    require(len(result) == 10, f"expected ten measured traces, got {len(result)}")
    return {
        "schema": "flyology.db.benchmark.admission_ceiling.v1",
        "source": str(path),
        "interpretation": (
            "instrumented_success_path_call_brackets_only; immediate-deadline sensitivity "
            "excludes delayed selector/backlog and is neither cohort eligibility nor throughput bound"
        ),
        "serial_last_commit_return_median_ms": round(statistics.median(
            row["serial_last_commit_return_ms"] for row in result), 3),
        "fixed_8_8_8_8_3_call_start_window_median_ms": round(statistics.median(
            row["fixed_8_8_8_8_3_call_start_window_ms"] for row in result), 3),
        "executions": result,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("metrics_ndjson", type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.metrics_ndjson), sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
