#!/usr/bin/env python3
"""Validate the successive whole-state checkpoint trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "CommitPrefix",
    "BeginFirst",
    "StoreFirstRun",
    "ConfirmFirstRun",
    "StoreFirstManifest",
    "ConfirmFirstManifest",
    "PublishFirst",
    "CommitSuffix",
    "BeginSecond",
    "StoreSecondRun",
    "ConfirmSecondRun",
    "StoreSecondManifest",
    "ConfirmSecondManifest",
    "LoseAcceptedSecondResponse",
    "ResolveSecond",
    "Crash",
    "Recover",
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid successive-checkpoint witness: {message}")


def exact_list(value: object, expected: list[str], label: str) -> None:
    if value != expected:
        fail(f"{label} is {value!r}, expected {expected!r}")


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

    final = states[-1]
    if final.get("phase") != "Recovered" or final.get("history_capacity") != 3:
        fail("witness did not use the admitted replacement/recovery branch")

    head = record(final.get("head"), "HEAD")
    if head != {"manifest": "M2", "run": "R2", "boundary": 2, "generation": 2}:
        fail(f"final HEAD is not the exact replacement authority: {head!r}")

    store = record(final.get("store"), "store")
    exact_list(store.get("runs"), ["R1", "R2"], "stored runs")
    exact_list(store.get("confirmed_runs"), ["R1", "R2"], "confirmed runs")
    exact_list(store.get("manifests"), ["M0", "M1", "M2"], "stored manifests")
    exact_list(
        store.get("confirmed_manifests"),
        ["M0", "M1", "M2"],
        "confirmed manifests",
    )

    authority = record(final.get("authority"), "authority")
    exact_list(authority.get("checkpoint_state"), ["T1", "T2"], "checkpoint state")
    exact_list(authority.get("checkpoint_ids"), ["I1", "I2"], "checkpoint IDs")
    exact_list(authority.get("later_state"), [], "later state")
    exact_list(authority.get("later_ids"), [], "later IDs")

    recovery = record(final.get("recovery"), "recovery")
    exact_list(recovery.get("state"), ["T1", "T2"], "recovered state")
    exact_list(recovery.get("ids"), ["I1", "I2"], "recovered IDs")
    exact_list(recovery.get("replayed_state"), [], "replayed state")
    exact_list(recovery.get("replayed_ids"), [], "replayed IDs")
    exact_list(recovery.get("local_state"), ["T1", "T2"], "local state")
    exact_list(recovery.get("local_ids"), ["I1", "I2"], "local IDs")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
