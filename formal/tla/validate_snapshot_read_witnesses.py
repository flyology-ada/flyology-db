#!/usr/bin/env python3
"""Validate the three fixed-snapshot read traces emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = {
    "old": ["Init", "Begin", "Begin", "BufferPut", "Commit", "Read"],
    "own": ["Init", "Begin", "Begin", "BufferPut", "BufferPut", "Commit", "Read"],
    "too-old": [
        "Init",
        "Begin",
        "Begin",
        "BufferPut",
        "Commit",
        "Checkpoint",
        "Read",
    ],
}
# These exact paths are the reviewed witness corpus, not production ordering or
# retry policy. A path change requires revalidating the scenario authority.


def fail(message: str) -> None:
    raise SystemExit(f"invalid snapshot-read witness: {message}")


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

    final = states[-1]
    if final.get("badReadObserved") is not False:
        fail("valid witness tripped the bad-read monitor")
    if mapping(final, "snapshot").get("T1") != 1:
        fail("T1 did not retain its Begin-time snapshot")
    if mapping(final, "phase").get("T1") != "Active":
        fail("read consumed the transaction")

    observed = mapping(final, "observed").get("T1")
    if mode == "old":
        if final.get("latestSeq") != 2 or final.get("latestValue") != "V2":
            fail("old-value witness lacks the later committed value")
        if final.get("previousSeq") != 1 or final.get("previousValue") != "V1":
            fail("old-value witness lacks the exact prior committed value")
        if final.get("checkpointBoundary") != 0 or observed != "V1":
            fail("old snapshot observed the later commit")
        return

    if mode == "own":
        if mapping(final, "bufferKind").get("T1") != "Put":
            fail("own-write witness lacks a buffered Put")
        if mapping(final, "bufferValue").get("T1") != "V1" or observed != "V1":
            fail("read did not prefer the transaction's buffered value")
        if final.get("latestValue") != "V2":
            fail("own-write witness lacks the later external value")
        return

    if final.get("checkpointBoundary") != 2 or observed != "TooOld":
        fail("history-incomplete snapshot did not return TooOld")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in EXPECTED_ACTIONS:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} old|own|too-old TLC_TRACE.json"
        )
    validate(sys.argv[1], load_states(Path(sys.argv[2])))


if __name__ == "__main__":
    main()
