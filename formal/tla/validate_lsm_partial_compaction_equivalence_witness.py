#!/usr/bin/env python3
"""Validate the partial-LSM-compaction equivalence trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = ["Init", "BuildPartialMerge", "RecoverMergedRuns"]


def fail(message: str) -> None:
    raise SystemExit(f"invalid partial-LSM-compaction witness: {message}")


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
    if final.get("phase") != "Recovered":
        fail("witness did not reach recovered state")
    exact_map(final.get("older"), {"K1": "V1", "K2": "V1"}, "older run")
    exact_map(final.get("first"), {"K1": "V2", "K2": "Tombstone"}, "first selected run")
    exact_map(final.get("second"), {"K1": "Tombstone", "K2": "V2"}, "second selected run")
    exact_map(final.get("merged"), {"K1": "Tombstone", "K2": "V2"}, "merged run")
    exact_map(final.get("newer"), {"K1": "V1", "K2": "NoMutation"}, "newer run")
    expected_suffix = {"K1": "NoMutation", "K2": "V1"}
    exact_map(final.get("suffix"), expected_suffix, "source suffix")
    exact_map(final.get("transferredSuffix"), expected_suffix, "transferred suffix")
    if final.get("identityRetained") is not True:
        fail("suffix transaction identity was not retained")
    expected_view = {"K1": "V1", "K2": "V1"}
    exact_map(final.get("before"), expected_view, "pre-merge view")
    exact_map(final.get("after"), expected_view, "post-merge view")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
