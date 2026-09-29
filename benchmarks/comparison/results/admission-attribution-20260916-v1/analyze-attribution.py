#!/usr/bin/env python3
"""Validate paired state and describe instrumented caller preparation costs."""

import argparse
import json
import statistics
from pathlib import Path


STATE_DIGEST = "090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb"


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


def analyze(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line]
    traces = unique_by_ordinal(rows, "flyology.db.benchmark.admission_trace.v1")
    configurations = unique_by_ordinal(rows, "flyology.db.benchmark.execution_configuration.v1")
    states = unique_by_ordinal(rows, "flyology.db.benchmark.state_verification.v1")
    pairs = [row for row in rows
             if row.get("schema") == "flyology.db.benchmark.paired_primary_sample.v1"]
    paired_ordinals = {int(row["contender_execution_ordinal"]) for row in pairs}
    require(traces, "no admission traces")
    require(len(pairs) == len(paired_ordinals) == 10, "expected ten unique measured pairs")
    require(sum(row["first"] == "reference" for row in pairs) == 5,
            "paired order is not balanced")
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
            for field in ("preparation_cpu_ns", "begin_ns", "generation_ns",
                          "put_call_ns"):
                require(isinstance(entry.get(field), int) and entry[field] >= 0,
                        f"invalid {field} at {ordinal}/{index}")
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
        preparation_wall_ns = sum(
            entry["preparation_end_ns"] - entry["preparation_start_ns"]
            for entry in entries
        )
        preparation_cpu_ns = sum(entry["preparation_cpu_ns"] for entry in entries)
        begin_ns = sum(entry["begin_ns"] for entry in entries)
        generation_ns = sum(entry["generation_ns"] for entry in entries)
        put_ns = sum(entry["put_call_ns"] for entry in entries)
        require(preparation_cpu_ns <= preparation_wall_ns + 1_000_000,
                f"caller CPU exceeds wall by over 1 ms at {ordinal}")
        require(begin_ns + generation_ns + put_ns <= preparation_wall_ns + 1_000_000,
                f"nested elapsed components exceed preparation wall at {ordinal}")
        result.append({
            "execution_ordinal": ordinal,
            "observed_batch_head_pairs": observed,
            "preparation_wall_ms": round(preparation_wall_ns / 1e6, 3),
            "preparation_task_cpu_ms": round(preparation_cpu_ns / 1e6, 3),
            "preparation_wall_minus_task_cpu_ms": round(
                (preparation_wall_ns - preparation_cpu_ns) / 1e6, 3),
            "begin_elapsed_ms": round(begin_ns / 1e6, 3),
            "input_generation_elapsed_ms": round(generation_ns / 1e6, 3),
            "put_call_elapsed_ms": round(put_ns / 1e6, 3),
            "unattributed_preparation_elapsed_ms": round(
                (preparation_wall_ns - begin_ns - generation_ns - put_ns) / 1e6, 3),
            "serial_last_commit_return_ms": round(entries[-1]["commit_return_ns"] / 1e6, 3),
            "last_finish_return_ms": round(max(e["finish_return_ns"] for e in entries) / 1e6, 3),
        })
    require(len(result) == 10, f"expected ten measured traces, got {len(result)}")
    return {
        "schema": "flyology.db.benchmark.preparation_attribution.v1",
        "source": str(path),
        "interpretation": (
            "instrumented task CPU and nested elapsed brackets; generation includes fixture input; "
            "put_call includes waits; instrumentation perturbs timings; neither nested elapsed "
            "nor wall-minus-task-CPU identifies a removable cost without a control/profile"
        ),
        "paired_primary_median_ms": {
            "slatedb": round(statistics.median(
                float(row["reference_primary_ns_per_operation"]) for row in pairs) / 1e6, 3),
            "flyology_db": round(statistics.median(
                float(row["contender_primary_ns_per_operation"]) for row in pairs) / 1e6, 3),
        },
        "median_components_ms": {
            key: round(statistics.median(row[key] for row in result), 3)
            for key in ("preparation_wall_ms", "preparation_task_cpu_ms",
                        "preparation_wall_minus_task_cpu_ms", "begin_elapsed_ms",
                        "input_generation_elapsed_ms", "put_call_elapsed_ms",
                        "unattributed_preparation_elapsed_ms")
        },
        "executions": result,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("metrics_ndjson", type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.metrics_ndjson), sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
