#!/usr/bin/env python3
"""Validate committed and failed manifest-publication traces emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_SUBSEQUENCES = {
    "committed": [
        "Init",
        "LoseRootPutResponseStored",
        "ConfirmRootBytes",
        "PublishRoot",
        "LoseAcceptedRootResponse",
        "ExternalStoreSuccessor",
        "ExternalPublishSuccessor",
        "ResolveCommitted",
        "Recover",
    ],
    "failed": [
        "Init",
        "StoreRoot",
        "LoseUnacceptedRootResponse",
        "StoreCompetingRoot",
        "PublishCompetingRoot",
        "ResolveFailed",
        "Recover",
    ],
}


def fail(message: str) -> None:
    raise SystemExit(f"invalid manifest witness: {message}")


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


def require_subsequence(actions: list[object], expected: list[str]) -> None:
    cursor = 0
    for action in actions:
        if cursor < len(expected) and action == expected[cursor]:
            cursor += 1
    if cursor != len(expected):
        fail(f"missing ordered action subsequence {expected!r}; got {actions!r}")


def manifest(final: dict[str, object], name: str) -> dict[str, object]:
    manifests = final.get("manifests")
    if not isinstance(manifests, dict) or not isinstance(manifests.get(name), dict):
        fail(f"final state lacks manifest {name}")
    return manifests[name]  # type: ignore[return-value]


def validate(mode: str, states: list[dict[str, object]]) -> None:
    actions = [state.get("action") for state in states]
    require_subsequence(actions, EXPECTED_SUBSEQUENCES[mode])
    if "Crash" not in actions or actions.index("Crash") > actions.index("Recover"):
        fail("witness does not discard local state before recovery")

    final = states[-1]
    head = final.get("head")
    cache = final.get("cache")
    if not isinstance(head, dict) or not isinstance(cache, dict):
        fail("final state lacks HEAD or cache projection")
    if cache.get("local") != [] or cache.get("crash_observed") is not True:
        fail("final state did not retain complete local-state loss")
    if cache.get("recovered_manifest") != head.get("latest_manifest"):
        fail("cacheless recovery did not start from the current HEAD")

    attempted = manifest(final, "M1")
    winner = manifest(final, "M2")
    if attempted.get("head_was_unknown") is not True:
        fail("attempted manifest did not retain ambiguous HEAD history")
    if winner.get("bytes_confirmed") is not True:
        fail("winning manifest bytes were not confirmed before publication")

    if mode == "committed":
        if attempted.get("put_was_unknown") is not True:
            fail("committed witness skipped ambiguous immutable Put")
        if attempted.get("bytes_confirmed") is not True:
            fail("ambiguous immutable Put was not confirmed byte-for-byte")
        if attempted.get("resolved_committed") is not True:
            fail("accepted lost response did not resolve committed")
        if winner.get("previous") != "M1" or head.get("ordinal") != 2:
            fail("committed witness lacks the later reachable successor")
        expected_registry = {"F1": "C1", "F2": "C2"}
    else:
        if attempted.get("resolved_failed") is not True:
            fail("unaccepted lost response did not resolve failed")
        if attempted.get("phase") != "Failed":
            fail("failed witness retained a nonterminal attempted manifest")
        if winner.get("previous") != "NoManifest" or head.get("ordinal") != 1:
            fail("failure witness lacks competing ordinal evidence")
        expected_registry = {"F1": "C1", "F2": "NoConfig"}
    if cache.get("recovered_registry") != expected_registry:
        fail("cacheless recovery produced the wrong exact registry")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in EXPECTED_SUBSEQUENCES:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} committed|failed TLC_TRACE.json"
        )
    validate(sys.argv[1], load_states(Path(sys.argv[2])))


if __name__ == "__main__":
    main()
