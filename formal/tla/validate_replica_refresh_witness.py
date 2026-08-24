#!/usr/bin/env python3
"""Validate the replica refresh and writer-fencing witness emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "ConfirmSuccessor",
    "BeginWriter",
    "FenceEpoch",
    "CancelWriter",
    "BeginWriter",
    "Publish",
    "BeginRefresh",
    "ConfirmSuccessor",
    "BeginWriter",
    "Publish",
    "CompleteLoad",
    "InstallRefresh",
    "BeginRefresh",
    "CompleteLoad",
    "InstallRefresh",
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid replica-refresh witness: {message}")


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
    if [state.get("step") for state in states] != list(range(16)):
        fail("witness steps are not exact and contiguous")

    fenced = states[3]
    if record(fenced.get("authority"), "fenced authority").get("epoch") != 1:
        fail("authority did not advance to writer epoch one")
    fenced_writer = record(fenced.get("writer"), "fenced writer")
    if fenced_writer.get("phase") != "Ready" or fenced_writer.get("capturedEpoch") != 0:
        fail("the epoch-zero writer was not retained stale before cancellation")

    advanced = states[10]
    if record(advanced.get("authority"), "advanced authority").get("ordinal") != 2:
        fail("authority did not advance to ordinal two")
    old_refresh = record(advanced.get("refresh"), "lagging refresh")
    if old_refresh != {"phase": "Loading", "ordinal": 1, "epoch": 1}:
        fail(f"lagging ordinal-one refresh was not preserved: {old_refresh!r}")

    lagging_install = states[12]
    lagging_replica = record(lagging_install.get("replica"), "lagging replica")
    if lagging_replica.get("ordinal") != 1 or lagging_replica.get("highOrdinal") != 1:
        fail("the validated ordinal-one refresh was not installed monotonically")
    if record(lagging_install.get("authority"), "authority after lag install").get("ordinal") != 2:
        fail("lagging replica installation changed authority")

    final = states[-1]
    authority = record(final.get("authority"), "final authority")
    replica = record(final.get("replica"), "final replica")
    if authority.get("ordinal") != 2 or authority.get("epoch") != 1:
        fail("final authority pair is not exact")
    if replica != {"ordinal": 2, "epoch": 1, "highOrdinal": 2, "highEpoch": 1}:
        fail(f"replica did not catch up monotonically: {replica!r}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
