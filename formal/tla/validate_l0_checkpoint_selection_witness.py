#!/usr/bin/env python3
"""Validate the complete-compaction decision witness emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"invalid L0-checkpoint-selection witness: {message}")


def load_states(path: Path) -> list[dict[str, object]]:
    try:
        entries = json.loads(path.read_text(encoding="utf-8"))["counterexample"]["state"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        fail(str(error))
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
    if len(states) != 2:
        fail(f"expected a two-state observation path, got {len(states)} states")
    initial, observed = states
    if initial.get("phase") != "Ready" or initial.get("action") != "Unobserved":
        fail("initial state is not a ready unobserved authority")
    if observed.get("phase") != "Observed" or observed.get("action") != "Complete":
        fail("witness did not select complete compaction")
    if observed.get("current") != {"F1": 1, "F2": 1}:
        fail(f"unexpected current runs: {observed.get('current')!r}")
    if observed.get("maximum") != {"F1": 2, "F2": 2}:
        fail(f"unexpected family maxima: {observed.get('maximum')!r}")
    if observed.get("changed") != ["F1", "F2"] or observed.get("nonempty") != ["F1", "F2"]:
        fail("witness did not retain both changed/nonempty families")
    if observed.get("totalMaximum") != 3 or observed.get("dirty") is not True:
        fail("witness did not retain the exact aggregate limit and dirty boundary")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
