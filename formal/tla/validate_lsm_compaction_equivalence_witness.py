#!/usr/bin/env python3
"""Validate the LSM compaction read-equivalence trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "BuildCompactedRun",
    "RecoverCompactedRun",
    "ReplayLaterDelta",
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid LSM-compaction-equivalence witness: {message}")


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


def exact_map(value: object, expected: dict[str, str], label: str) -> None:
    if value != expected:
        fail(f"{label} is {value!r}, expected {expected!r}")


def validate(states: list[dict[str, object]]) -> None:
    actions = [state.get("action") for state in states]
    if actions != EXPECTED_ACTIONS:
        fail(f"unexpected action path: {actions!r}")

    final = states[-1]
    if final.get("phase") != "Replayed":
        fail("witness did not reach replayed state")
    exact_map(final.get("source"), {"K1": "V1", "K2": "NoValue"}, "source view")
    exact_map(
        final.get("compacted"),
        {"K1": "V1", "K2": "NoMutation"},
        "compacted run",
    )
    exact_map(final.get("recovered"), {"K1": "V1", "K2": "NoValue"}, "recovered view")
    exact_map(
        final.get("delta"),
        {"K1": "Tombstone", "K2": "V2"},
        "later delta",
    )
    exact_map(final.get("replayed"), {"K1": "NoValue", "K2": "V2"}, "replayed view")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
