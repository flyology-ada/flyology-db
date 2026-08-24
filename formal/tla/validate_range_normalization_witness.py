#!/usr/bin/env python3
"""Validate the range-normalization execution trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "RecordRange",
    "RecordRange",
    "RecordRange",
    "RecordRange",
    "RejectCapacity",
    "RecordRange",
    "RejectAllocation",
]

EXPECTED_CANDIDATES = [
    {"family": "F1", "lower": 0, "upper": 1},
    {"family": "F1", "lower": 1, "upper": 2},
    {"family": "F1", "lower": 3, "upper": 4},
    {"family": "F1", "lower": 2, "upper": 3},
    {"family": "F2", "lower": 1, "upper": 2},
    {"family": "F2", "lower": 3, "upper": 4},
    {"family": "F1", "lower": 0, "upper": 1},
    {"family": "F2", "lower": 1, "upper": 3},
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid range-normalization witness: {message}")


def load_states(path: Path) -> list[dict[str, object]]:
    try:
        entries = json.loads(path.read_text(encoding="utf-8"))["counterexample"]["state"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        fail(str(error))
    if not isinstance(entries, list):
        fail("counterexample.state is not an array")
    states: list[dict[str, object]] = []
    for expected_index, entry in enumerate(entries, start=1):
        if (
            not isinstance(entry, list)
            or len(entry) != 2
            or entry[0] != expected_index
            or not isinstance(entry[1], dict)
        ):
            fail(f"state {expected_index} has an invalid envelope")
        states.append(entry[1])
    return states


def sorted_records(value: object, label: str) -> list[dict[str, object]]:
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        fail(f"{label} is not a set of records")
    return sorted(value, key=lambda item: (str(item.get("family")), int(item.get("lower", -1))))


def validate(states: list[dict[str, object]]) -> None:
    actions = [state.get("action") for state in states]
    if actions != EXPECTED_ACTIONS:
        fail(f"unexpected action path: {actions!r}")
    candidates = [state.get("candidate") for state in states]
    if candidates != EXPECTED_CANDIDATES:
        fail(f"unexpected candidate path: {candidates!r}")

    before_capacity = states[4]
    after_capacity = states[5]
    if before_capacity.get("ranges") != after_capacity.get("ranges"):
        fail("capacity rejection changed retained ranges")
    if before_capacity.get("coverage") != after_capacity.get("coverage"):
        fail("capacity rejection changed observed coverage")

    before_allocation = states[6]
    final = states[7]
    if before_allocation.get("ranges") != final.get("ranges"):
        fail("allocation rejection changed retained ranges")
    if before_allocation.get("coverage") != final.get("coverage"):
        fail("allocation rejection changed observed coverage")
    if final.get("result") != "CapacityExceeded":
        fail("allocation rejection lost its typed result")

    ranges = sorted_records(final.get("ranges"), "final ranges")
    expected_ranges = [
        {"family": "F1", "lower": 0, "upper": 4},
        {"family": "F2", "lower": 1, "upper": 2},
    ]
    if ranges != expected_ranges:
        fail(f"final normalized ranges are {ranges!r}, expected {expected_ranges!r}")

    coverage = final.get("coverage")
    expected_coverage = [
        {"family": "F1", "key": 0},
        {"family": "F1", "key": 1},
        {"family": "F1", "key": 2},
        {"family": "F1", "key": 3},
        {"family": "F2", "key": 1},
    ]
    if not isinstance(coverage, list):
        fail("final coverage is not a set")
    actual_coverage = sorted(
        coverage,
        key=lambda item: (str(item.get("family")), int(item.get("key", -1))),
    )
    if actual_coverage != expected_coverage:
        fail(f"final coverage is {actual_coverage!r}, expected {expected_coverage!r}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
