#!/usr/bin/env python3
"""Validate the immutable-cache witness trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "BeginRead",
    "StartFetch",
    "BeginRead",
    "JoinFetch",
    "CompleteFetch",
    "FinishRead",
    "FinishRead",
    "AdvanceAuthority",
    "BeginRead",
    "StartFetch",
    "LocalLoss",
    "StartFetch",
    "CompleteFetch",
    "FinishRead",
    "CorruptCache",
    "BeginRead",
    "RejectCorruptHit",
    "StartFetch",
    "CompleteFetch",
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid immutable-cache witness: {message}")


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
    if [state.get("step") for state in states] != list(range(20)):
        fail("witness steps are not exact and contiguous")

    joined = states[4]
    if joined.get("joined") != ["R2"]:
        fail("R2 did not join R1's E0 fetch")
    first_complete = states[5]
    first_results = record(first_complete.get("results"), "first results")
    if first_results != {"R1": "E0", "R2": "E0"}:
        fail(f"coalesced fetch did not complete both readers: {first_results!r}")

    lost = states[11]
    if lost.get("cache") != {"valid": [], "corrupt": [], "capacity": 1}:
        fail("local loss did not clear every cache entry")
    if lost.get("fetch") != {"E0": "NoReader", "E1": "NoReader"}:
        fail("local loss did not clear the in-flight fetch")
    if record(lost.get("requested"), "post-loss requests").get("R1") != "E1":
        fail("local loss discarded the pending exact-generation request")

    corrupt = states[15]
    if corrupt.get("cache") != {"valid": [], "corrupt": ["E1"], "capacity": 1}:
        fail("witness did not mark the exact E1 cache entry corrupt")
    rejected = states[17]
    if rejected.get("cache") != {"valid": [], "corrupt": [], "capacity": 1}:
        fail("corrupt cache hit was not rejected as a miss")
    if record(rejected.get("results"), "post-rejection results").get("R2") != "NoEntry":
        fail("corrupt cache bytes became a read result")

    final = states[-1]
    if final.get("store") != ["E0", "E1"] or final.get("current") != "E1":
        fail("final object-store authority is not exact")
    if final.get("cache") != {"valid": ["E1"], "corrupt": [], "capacity": 1}:
        fail("final cache is not the verified E1 entry")
    if record(final.get("results"), "final results").get("R2") != "E1":
        fail("final refetch did not return the requested E1 generation")
    if record(final.get("requested"), "final requests").get("R2") != "E1":
        fail("final result is not bound to R2's captured generation")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
