#!/usr/bin/env python3
"""Validate the three snapshot-isolation traces emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = {
    "conflict": [
        "Init",
        "Begin",
        "Begin",
        "BufferWrite",
        "BufferWrite",
        "Commit",
        "RejectConflict",
    ],
    "disjoint": [
        "Init",
        "Begin",
        "Begin",
        "BufferWrite",
        "BufferWrite",
        "Commit",
        "Commit",
    ],
    "checkpoint": [
        "Init",
        "Begin",
        "Begin",
        "BufferWrite",
        "BufferWrite",
        "Commit",
        "Checkpoint",
        "RejectConflict",
    ],
}


def fail(message: str) -> None:
    raise SystemExit(f"invalid snapshot-isolation witness: {message}")


def load_states(path: Path) -> list[dict[str, object]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        entries = document["counterexample"]["state"]
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


def mapping(state: dict[str, object], name: str) -> dict[str, object]:
    value = state.get(name)
    if not isinstance(value, dict):
        fail(f"{name} is not a record")
    return value


def validate(mode: str, states: list[dict[str, object]]) -> None:
    actions = [state.get("lastAction") for state in states]
    if actions != EXPECTED_ACTIONS[mode]:
        fail(f"unexpected action path for {mode}: {actions!r}")

    before_first_commit = states[4]
    first_commit = states[5]
    final = states[-1]
    snapshots = mapping(final, "snapshot")
    phases = mapping(final, "phase")
    writes = mapping(final, "writes")
    last_write = mapping(final, "lastWrite")

    if mapping(before_first_commit, "snapshot") != {"T1": 0, "T2": 0}:
        fail("transactions did not begin at the same fixed snapshot")
    if first_commit.get("sequence") != 1 or final.get("invalidCommitObserved") is not False:
        fail("first commit or invalid-commit monitor is wrong")
    if snapshots != {"T1": 0, "T2": 0}:
        fail("transaction snapshots changed after Begin")

    if mode == "conflict":
        if writes != {"T1": ["K1"], "T2": ["K1"]}:
            fail("same-key witness has the wrong write sets")
        if phases != {"T1": "Committed", "T2": "Conflict"}:
            fail("post-snapshot same-key write was not rejected")
        if last_write != {"K1": 1, "K2": 0}:
            fail("same-key witness has the wrong last-write authority")
        return

    if mode == "disjoint":
        if writes != {"T1": ["K1"], "T2": ["K2"]}:
            fail("disjoint witness has the wrong write sets")
        if phases != {"T1": "Committed", "T2": "Committed"}:
            fail("disjoint writers did not both commit")
        if final.get("sequence") != 2 or last_write != {"K1": 1, "K2": 2}:
            fail("disjoint commits did not advance exact key authority")
        return

    if writes != {"T1": ["K1"], "T2": ["K2"]}:
        fail("checkpoint witness has the wrong disjoint write sets")
    if phases != {"T1": "Committed", "T2": "Conflict"}:
        fail("transaction older than retained history was not rejected")
    if final.get("checkpointBoundary") != 1 or last_write != {"K1": 1, "K2": 0}:
        fail("checkpoint witness lacks the exact compacted-history boundary")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in EXPECTED_ACTIONS:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} conflict|disjoint|checkpoint TLC_TRACE.json"
        )
    validate(sys.argv[1], load_states(Path(sys.argv[2])))


if __name__ == "__main__":
    main()
