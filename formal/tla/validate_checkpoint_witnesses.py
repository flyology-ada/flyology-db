#!/usr/bin/env python3
"""Validate the three first-LSM checkpoint traces emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = {
    "committed": [
        "Init",
        "ReserveFailedIdentity",
        "CommitPrefix",
        "CommitPrefix",
        "BeginFlush",
        "StoreRun",
        "StoreRun",
        "ConfirmRun",
        "ConfirmRun",
        "StoreManifest",
        "ConfirmManifest",
        "PublishFlush",
        "LoseAcceptedFlushResponse",
        "ResolveCommitted",
    ],
    "rejected": [
        "Init",
        "ReserveFailedIdentity",
        "CommitPrefix",
        "CommitPrefix",
        "BeginFlush",
        "StoreRun",
        "StoreRun",
        "ConfirmRun",
        "ConfirmRun",
        "StoreManifest",
        "ConfirmManifest",
        "LoseUnacceptedFlushResponse",
        "RivalTransition",
        "ResolveRejected",
    ],
    "recovery": [
        "Init",
        "ReserveFailedIdentity",
        "CommitPrefix",
        "CommitPrefix",
        "BeginFlush",
        "StoreRun",
        "StoreRun",
        "ConfirmRun",
        "ConfirmRun",
        "StoreManifest",
        "ConfirmManifest",
        "PublishFlush",
        "LoseAcceptedFlushResponse",
        "ExternalCommitLater",
        "ResolveCommitted",
        "Crash",
        "Recover",
    ],
}


def fail(message: str) -> None:
    raise SystemExit(f"invalid checkpoint witness: {message}")


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


def record(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        fail(f"{label} is not a record")
    return value


def exact_list(value: object, expected: list[str], label: str) -> None:
    if value != expected:
        fail(f"{label} is {value!r}, expected {expected!r}")


def validate(mode: str, states: list[dict[str, object]]) -> None:
    actions = [state.get("action") for state in states]
    if actions != EXPECTED_ACTIONS[mode]:
        fail(f"unexpected action path for {mode}: {actions!r}")

    final = states[-1]
    head = record(final.get("head"), "HEAD")
    flush = record(final.get("flush"), "flush receipt")
    store = record(final.get("store"), "store")
    runs_by_family = record(
        store.get("checkpoint_runs_by_family"), "checkpoint runs by family"
    )
    authority = record(final.get("authority"), "identity authority")
    cache = record(final.get("cache"), "cache")

    if final.get("capacity") != "Enough":
        fail("witness bypassed the admitted-capacity scenario")
    if flush.get("boundary") != 2:
        fail("flush did not snapshot the exact committed replay boundary")
    if flush.get("expected_ordinal") != 3 or flush.get("expected_id") != "H2":
        fail("receipt lost the exact expected HEAD identity")
    if flush.get("attempted_ordinal") != 4 or flush.get("attempted_id") != "HF":
        fail("receipt lost the exact attempted HEAD identity")
    if flush.get("was_unknown") is not True:
        fail("witness did not pass through an ambiguous HEAD response")

    for field in ("stored_runs", "confirmed_runs", "complete_runs", "sorted_runs"):
        exact_list(store.get(field), ["R1", "R2"], field)
    exact_list(store.get("checkpoint_runs"), ["R1", "R2"], "manifest runs")
    exact_list(runs_by_family.get("F1"), ["R1"], "F1 manifest runs")
    exact_list(runs_by_family.get("F2"), ["R2"], "F2 manifest runs")
    exact_list(store.get("checkpoint_ledger"), ["I1", "I2", "IX"], "checkpoint ledger")
    exact_list(authority.get("confirmed_batches"), ["T1", "T2"]
               if mode != "recovery" else ["T1", "T2", "T3"],
               "confirmed batches")

    if mode == "rejected":
        if flush.get("phase") != "Rejected" or flush.get("resolved_rejected") is not True:
            fail("unaccepted response was not conclusively rejected")
        if head != {"manifest": "M0", "highest": 2, "ordinal": 4, "id": "HR"}:
            fail("rejected witness lacks the exact rival HEAD")
        exact_list(authority.get("admitted_ids"), ["I1", "I2", "IX"], "used IDs")
        return

    if flush.get("phase") != "Success" or flush.get("resolved_committed") is not True:
        fail("accepted lost response was not resolved committed")
    if head.get("manifest") != "M1":
        fail("committed HEAD does not name the checkpoint manifest")

    if mode == "committed":
        if head != {"manifest": "M1", "highest": 2, "ordinal": 4, "id": "HF"}:
            fail("committed witness has the wrong exact HEAD")
        exact_list(authority.get("admitted_ids"), ["I1", "I2", "IX"], "used IDs")
        return

    if head != {"manifest": "M1", "highest": 3, "ordinal": 5, "id": "HL"}:
        fail("recovery witness lacks the later manifest-preserving commit")
    if cache.get("crash_observed") is not True or cache.get("recovery_phase") != "Recovered":
        fail("recovery witness did not crash and recover")
    for field in ("local_runs", "local_manifests", "local_state", "local_ids"):
        exact_list(cache.get(field), [], field)
    if cache.get("recovered_manifest") != "M1":
        fail("cacheless recovery did not start from HEAD")
    exact_list(cache.get("recovered_state"), ["T1", "T2", "T3"], "recovered state")
    exact_list(cache.get("recovered_ids"), ["I1", "I2", "I3", "IX"], "recovered IDs")
    exact_list(cache.get("replayed"), ["T3"], "post-checkpoint replay")
    exact_list(authority.get("admitted_ids"), ["I1", "I2", "I3", "IX"], "used IDs")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in EXPECTED_ACTIONS:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} committed|rejected|recovery TLC_TRACE.json"
        )
    validate(sys.argv[1], load_states(Path(sys.argv[2])))


if __name__ == "__main__":
    main()
