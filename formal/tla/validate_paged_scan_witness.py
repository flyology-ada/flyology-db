#!/usr/bin/env python3
"""Validate the fixed-snapshot paged-scan execution trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "Begin",
    "ProducePage",
    "ConcurrentAdvance",
    "RejectCapacity",
    "RejectAllocation",
    "ProducePage",
    "ProducePage",
]

FIRST_PAGE = [{"key": 1, "value": "A"}]
SECOND_PAGE = [{"key": 3, "value": "B"}]
FINAL_PAGE = [{"key": 4, "value": "A"}]
COMPLETE_ROWS = FIRST_PAGE + SECOND_PAGE + FINAL_PAGE


def fail(message: str) -> None:
    raise SystemExit(f"invalid paged-scan witness: {message}")


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

    if states[2].get("page") != FIRST_PAGE or states[2].get("emitted") != FIRST_PAGE:
        fail("first page is not the frozen first row")

    before_capacity = states[3]
    after_capacity = states[4]
    if before_capacity.get("emitted") != after_capacity.get("emitted"):
        fail("capacity rejection advanced the cursor")
    if before_capacity.get("page") != after_capacity.get("page"):
        fail("capacity rejection replaced the prior page")
    if after_capacity.get("result") != "CapacityExceeded":
        fail("capacity rejection lost its typed result")

    before_allocation = states[4]
    after_allocation = states[5]
    if before_allocation.get("emitted") != after_allocation.get("emitted"):
        fail("allocation rejection advanced the cursor")
    if before_allocation.get("page") != after_allocation.get("page"):
        fail("allocation rejection replaced the prior page")

    if states[6].get("page") != SECOND_PAGE:
        fail("second page did not retain the pre-delete snapshot row")
    final = states[7]
    if final.get("page") != FINAL_PAGE or final.get("emitted") != COMPLETE_ROWS:
        fail("final reconstruction is not exact")
    if final.get("done") is not True or final.get("predicate") is not True:
        fail("final page did not publish completion and predicate authority")
    if final.get("emptyView") is not False:
        fail("witness unexpectedly selected the valid empty view")

    snapshot = final.get("snapshot")
    current = final.get("current")
    if not isinstance(snapshot, list) or not isinstance(current, list):
        fail("snapshot/current functions are missing")
    if snapshot == current:
        fail("witness did not separate frozen snapshot from current authority")
    if current[:3] != ["C", "C", "Tombstone"]:
        fail(f"unexpected final current authority: {current!r}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
