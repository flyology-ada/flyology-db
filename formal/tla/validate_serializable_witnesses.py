#!/usr/bin/env python3
"""Validate the serializable point/range/snapshot traces emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = {
    "point": [
        "Init",
        "Begin",
        "Begin",
        "BufferWrite",
        "RecordPoint",
        "Commit",
        "RejectConflict",
    ],
    "range": [
        "Init",
        "Begin",
        "Begin",
        "BufferWrite",
        "RecordRange",
        "Commit",
        "RejectConflict",
    ],
    "snapshot": [
        "Init",
        "Begin",
        "RecordPoint",
        "Begin",
        "BufferWrite",
        "Commit",
        "Commit",
    ],
    "own": [
        "Init",
        "Begin",
        "RecordPoint",
        "BufferWrite",
        "RecordPoint",
    ],
}
# These exact paths are reviewed scenario witnesses, not product scheduling,
# admission, capacity, or retry policy.


def fail(message: str) -> None:
    raise SystemExit(f"invalid serializable witness: {message}")


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


def members(state: dict[str, object], name: str, transaction: str) -> set[str]:
    value = mapping(state, name).get(transaction)
    if value == "{}":
        return set()
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return set(value)
    if isinstance(value, str):
        return {value}
    fail(f"{name}[{transaction}] is not a finite symbolic set")


def validate(mode: str, states: list[dict[str, object]]) -> None:
    actions = [state.get("lastAction") for state in states]
    if actions != EXPECTED_ACTIONS[mode]:
        fail(f"unexpected action path for {mode}: {actions!r}")

    final = states[-1]
    if final.get("badCommitObserved") is not False:
        fail("valid witness tripped the invalid-commit monitor")

    phase = mapping(final, "phase")
    result = mapping(final, "result")
    if mode != "own" and mapping(final, "lastWrite").get("K1") != 1:
        fail("witness lacks the post-snapshot K1 write")
    if mode == "point":
        if members(final, "pointReads", "T1") != {"K1"}:
            fail("point witness did not retain K1")
    elif mode == "range":
        if members(final, "rangeReads", "T1") != {"R1"}:
            fail("range witness did not retain R1")
    elif mode == "snapshot":
        if members(final, "pointReads", "T1"):
            fail("snapshot transaction retained a serializable point")
        if phase.get("T1") != "Committed" or result.get("T1") != "Success":
            fail("snapshot read-only transaction did not remain admissible")
        if members(final, "writes", "T1") or members(final, "writes", "T2") != {"K1"}:
            fail("snapshot witness has the wrong writer")
        return
    else:
        if members(final, "pointReads", "T1") != {"K1"}:
            fail("own-write witness changed the full point set")
        if members(final, "writes", "T1") != {"K2"}:
            fail("own-write witness did not retain K2 as a mutation")
        if phase.get("T1") != "Active" or result.get("T1") != "Success":
            fail("own-write read failed at point capacity")
        return

    if phase.get("T1") != "Rejected" or result.get("T1") != "SerializationFailure":
        fail("serializable reader did not reject with serialization failure")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in EXPECTED_ACTIONS:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} point|range|snapshot|own TLC_TRACE.json"
        )
    validate(sys.argv[1], load_states(Path(sys.argv[2])))


if __name__ == "__main__":
    main()
