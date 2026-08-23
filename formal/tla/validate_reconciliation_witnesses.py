#!/usr/bin/env python3
"""Validate deliberate deep-descendant reconciliation traces emitted by TLC."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = {
    "committed": [
        "Init",
        "PreparePooled",
        "StoreBatch",
        "PublishHead",
        "LoseAcceptedResponse",
        "AcquireWriter",
        "AcquireWriter",
        "ResolveCommitted",
    ],
    "failed": [
        "Init",
        "PreparePooled",
        "StoreBatch",
        "LoseUnacceptedResponse",
        "AcquireWriter",
        "AcquireWriter",
        "ResolvePreconditionFailure",
    ],
}


def fail(message: str) -> None:
    raise SystemExit(f"invalid reconciliation witness: {message}")


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


def validate(mode: str, states: list[dict[str, object]]) -> None:
    actions = [state.get("action") for state in states]
    if actions != EXPECTED_ACTIONS[mode]:
        fail(f"unexpected {mode} action sequence: {actions!r}")

    final = states[-1]
    head = final.get("head")
    batch = final.get("attempted_batch")
    transactions = final.get("transactions")
    if not isinstance(head, dict) or not isinstance(batch, dict):
        fail(f"{mode} final state lacks HEAD or attempted batch")
    if not isinstance(transactions, dict):
        fail(f"{mode} final state lacks transactions")
    if batch.get("transactions") != ["T1", "T2"]:
        fail(f"{mode} witness is not genuinely pooled")

    head_ordinal = head.get("ordinal")
    publication_ordinal = batch.get("publication_ordinal")
    if not isinstance(head_ordinal, int) or not isinstance(publication_ordinal, int):
        fail(f"{mode} witness lacks ordinal evidence")

    expected_receipt = "Committed" if mode == "committed" else "PreconditionFailed"
    expected_reachable = mode == "committed"
    if batch.get("reachable") is not expected_reachable:
        fail(f"{mode} witness has wrong reachability conclusion")
    for transaction_id in ("T1", "T2"):
        transaction = transactions.get(transaction_id)
        if not isinstance(transaction, dict):
            fail(f"{mode} witness lacks {transaction_id}")
        if transaction.get("was_unknown") is not True:
            fail(f"{mode} witness did not retain unknown history for {transaction_id}")
        if transaction.get("receipt") != expected_receipt:
            fail(f"{mode} witness has wrong receipt for {transaction_id}")

    minimum_gap = 2 if mode == "committed" else 1
    if head_ordinal - publication_ordinal < minimum_gap:
        fail(f"{mode} witness did not advance through two later transitions")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in EXPECTED_ACTIONS:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} committed|failed TLC_TRACE.json"
        )
    validate(sys.argv[1], load_states(Path(sys.argv[2])))


if __name__ == "__main__":
    main()
