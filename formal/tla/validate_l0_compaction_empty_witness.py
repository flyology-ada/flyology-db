#!/usr/bin/env python3
"""Validate the canonical empty-output L0 compaction trace emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "BeginCompaction",
    "ConfirmNoOutput",
    "StoreManifest",
    "ConfirmManifest",
    "LoseAcceptedResponse",
    "ResolvePublication",
    "Crash",
    "Recover",
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid empty-output L0-compaction witness: {message}")


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
    if final.get("phase") != "Recovered" or final.get("empty_output") is not True:
        fail("witness did not recover through the empty-output branch")
    if final.get("output_capacity") != 0:
        fail("empty-output compaction consumed output capacity")

    head = record(final.get("head"), "HEAD")
    if head.get("manifest") != "M3" or head.get("boundary") != 2:
        fail(f"final HEAD is not the replacement authority: {head!r}")
    if head.get("generation") != 3:
        fail(f"final HEAD has the wrong generation: {head!r}")
    exact_list(head.get("runs"), [], "HEAD runs")

    store = record(final.get("store"), "store")
    expected_runs = ["R1", "R2"]
    exact_list(store.get("runs"), expected_runs, "stored runs")
    exact_list(store.get("confirmed_runs"), expected_runs, "confirmed runs")
    exact_list(store.get("available_runs"), expected_runs, "available runs")
    exact_list(store.get("manifests"), ["M2", "M3"], "stored manifests")
    exact_list(
        store.get("confirmed_manifests"),
        ["M2", "M3"],
        "confirmed manifests",
    )

    manifest = record(final.get("manifest"), "manifest")
    exact_list(manifest.get("runs"), [], "M3 runs")
    if manifest.get("previous") != "M2":
        fail("M3 does not retain M2 as its immutable predecessor")

    expected_view = {"K1": "NoValue", "K2": "NoValue"}
    views = record(final.get("views"), "views")
    for name in ("checkpoint", "recovered", "local"):
        if views.get(name) != expected_view:
            fail(f"{name} view is not exactly empty: {views.get(name)!r}")

    identities = record(final.get("identities"), "identities")
    for name in ("checkpoint", "recovered", "local"):
        exact_list(identities.get(name), ["I1", "I2"], f"{name} IDs")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
