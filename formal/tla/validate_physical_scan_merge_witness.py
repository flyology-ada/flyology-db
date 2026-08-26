#!/usr/bin/env python3
"""Validate the owned physical scan-merge execution trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "Begin",
    "AdvanceVisible",
    "ConcurrentChange",
    "RejectAllocation",
    "AdvanceVisible",
    "AdvanceTombstone",
]

FIRST_ROW = [{"key": 1, "value": "B"}]
SECOND_ROW = [{"key": 2, "value": "C"}]
COMPLETE_ROWS = FIRST_ROW + SECOND_ROW


def fail(message: str) -> None:
    raise SystemExit(f"invalid physical-scan-merge witness: {message}")


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

    if states[2].get("page") != FIRST_ROW or states[2].get("emitted") != FIRST_ROW:
        fail("transaction-local key one did not win")

    before_rejection = states[3]
    after_rejection = states[4]
    for field in ("positions", "lastKey", "page", "emitted", "done"):
        if before_rejection.get(field) != after_rejection.get(field):
            fail(f"allocation rejection changed {field}")
    if after_rejection.get("result") != "CapacityExceeded":
        fail("allocation rejection lost its typed result")

    if states[5].get("page") != SECOND_ROW:
        fail("newest suffix value for key two did not win")
    final = states[6]
    if final.get("emitted") != COMPLETE_ROWS:
        fail("final rows include a gap, duplicate, stale value, or tombstone")
    if final.get("done") is not True or final.get("lastKey") != 3:
        fail("final tombstone advance did not complete the merge")
    if final.get("captured") == final.get("current"):
        fail("witness did not retain a fixed source snapshot")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
