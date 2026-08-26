#!/usr/bin/env python3
"""Validate the generation-bound lazy SST read trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "Begin",
    "ReadIndex",
    "RejectAllocation",
    "ReadFrame",
    "ReplaceObject",
    "PublishSuccess",
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid lazy-sst-read witness: {message}")


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
    actions = [state.get("lastAction") for state in states]
    if actions != EXPECTED_ACTIONS:
        fail(f"unexpected action path: {actions!r}")

    captured = states[1].get("capturedGeneration")
    if captured != "G1" or states[2].get("indexGeneration") != captured:
        fail("header and index generations are not exact")

    before_rejection = states[2]
    after_rejection = states[3]
    for field in (
        "capturedGeneration",
        "indexGeneration",
        "frameGeneration",
        "frameKey",
        "frameValue",
        "phase",
        "output",
    ):
        if before_rejection.get(field) != after_rejection.get(field):
            fail(f"allocation rejection changed {field}")
    if after_rejection.get("result") != "CapacityExceeded":
        fail("allocation rejection lost its typed result")

    frame = states[4]
    if (
        frame.get("frameGeneration") != "G1"
        or frame.get("frameKey") != 2
        or frame.get("frameValue") != "B1"
    ):
        fail("frame is not bound to the authenticated index entry")

    replaced = states[5]
    if replaced.get("currentGeneration") != "G2" or replaced.get("output") != "Prior":
        fail("provider replacement changed output before publication")

    final = states[6]
    if final.get("result") != "Success" or final.get("output") != "B1":
        fail("publication did not preserve the owned G1 frame")
    if final.get("currentGeneration") == final.get("capturedGeneration"):
        fail("witness did not exercise post-frame provider replacement")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
