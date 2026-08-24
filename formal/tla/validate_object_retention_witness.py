#!/usr/bin/env python3
"""Validate the immutable-object retention witness emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "ListObject",
    "MarkOld",
    "AcquireSnapshot",
    "PinReplica",
    "Store",
    "BeginUnknown",
    "ListObject",
    "MarkOld",
    "Advance",
    "ResolveUnknown",
    "ReleaseSnapshot",
    "ReleaseReplica",
    "ReleasePredecessor",
    "DeleteEligible",
    "Store",
    "ListObject",
    "MarkOld",
    "BeginUnknown",
    "DiscardDiscovery",
    "ListObject",
    "MarkOld",
    "ResolveUnknown",
    "DeleteEligible",
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid object-retention witness: {message}")


def record(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        fail(f"{label} is not a record")
    return value


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


def validate(states: list[dict[str, object]]) -> None:
    actions = [state.get("action") for state in states]
    if actions != EXPECTED_ACTIONS:
        fail(f"unexpected action path: {actions!r}")
    if [state.get("step") for state in states] != list(range(24)):
        fail("witness steps are not exact and contiguous")

    fully_pinned = states[9]
    if fully_pinned.get("current") != ["O1"]:
        fail("authority did not advance to O1")
    protection = record(fully_pinned.get("protected"), "post-advance protection")
    if protection != {
        "snapshots": ["O0"],
        "replicas": ["O0"],
        "predecessors": ["O0"],
        "unknown": ["O1"],
    }:
        fail(f"post-advance protection is incomplete: {protection!r}")

    first_delete = states[14]
    if first_delete.get("stored") != ["O1"] or first_delete.get("deleted") != ["O0"]:
        fail("O0 was not deleted exactly after all protections were released")

    lost = states[19]
    if lost.get("listed") != [] or lost.get("aged") != []:
        fail("discovery loss did not clear listing and age evidence")
    lost_protection = record(lost.get("protected"), "post-loss protection")
    if lost_protection.get("unknown") != ["O2"]:
        fail("discovery loss discarded the unresolved O2 protection")

    final = states[-1]
    if final.get("stored") != ["O1"] or final.get("current") != ["O1"]:
        fail("final current authority is not exact")
    if final.get("deleted") != ["O0", "O2"]:
        fail("only the released predecessor and resolved orphan were not deleted")
    final_protection = record(final.get("protected"), "final protection")
    if final_protection != {
        "snapshots": [],
        "replicas": [],
        "predecessors": [],
        "unknown": [],
    }:
        fail(f"final non-current protections remain: {final_protection!r}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
