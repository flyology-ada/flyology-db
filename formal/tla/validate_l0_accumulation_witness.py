#!/usr/bin/env python3
"""Validate the additive L0 recovery trace emitted by TLC."""

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
    raise SystemExit(f"invalid L0-accumulation witness: {message}")


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


def exact_view(value: object, expected: dict[str, str], label: str) -> None:
    if value != expected:
        fail(f"{label} is {value!r}, expected {expected!r}")


def validate(states: list[dict[str, object]]) -> None:
    actions = [state.get("action") for state in states]
    if actions != EXPECTED_ACTIONS:
        fail(f"unexpected action path: {actions!r}")

    final = states[-1]
    if final.get("phase") != "Recovered":
        fail("witness did not reach recovered state")

    limits = record(final.get("limits"), "limits")
    if limits != {"family_runs": 2, "total_runs": 2}:
        fail(f"witness did not use admitted persisted run limits: {limits!r}")

    head = record(final.get("head"), "HEAD")
    if head.get("manifest") != "M2" or head.get("boundary") != 2 or head.get("generation") != 2:
        fail(f"final HEAD is not the exact additive authority: {head!r}")
    exact_list(head.get("runs"), ["R1", "R2"], "HEAD runs")

    store = record(final.get("store"), "store")
    exact_list(store.get("runs"), ["R1", "R2"], "stored runs")
    exact_list(store.get("confirmed_runs"), ["R1", "R2"], "confirmed runs")
    exact_list(store.get("manifests"), ["M0", "M1", "M2"], "stored manifests")
    exact_list(
        store.get("confirmed_manifests"),
        ["M0", "M1", "M2"],
        "confirmed manifests",
    )

    manifest = record(final.get("manifest"), "manifest")
    exact_list(manifest.get("runs"), ["R1", "R2"], "M2 runs")
    if manifest.get("previous") != "M1":
        fail("M2 does not retain M1 as its immutable predecessor")

    expected_view = {"K1": "NoValue", "K2": "V2"}
    views = record(final.get("views"), "views")
    exact_view(views.get("checkpoint"), expected_view, "checkpoint view")
    exact_view(views.get("later"), {"K1": "NoValue", "K2": "NoValue"}, "later view")
    exact_view(views.get("recovered"), expected_view, "recovered view")
    exact_view(views.get("local"), expected_view, "local view")

    identities = record(final.get("identities"), "identities")
    exact_list(identities.get("checkpoint"), ["I1", "I2"], "checkpoint IDs")
    exact_list(identities.get("later"), [], "later IDs")
    exact_list(identities.get("recovered"), ["I1", "I2"], "recovered IDs")
    exact_list(identities.get("local"), ["I1", "I2"], "local IDs")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    validate(load_states(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
