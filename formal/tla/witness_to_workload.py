#!/usr/bin/env python3
"""Validate a TLC publication witness and project it to workload NDJSON."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "Prepare",
    "StoreBatch",
    "PublishHead",
    "LoseAcceptedResponse",
    "ResolveCommitted",
    "Crash",
    "Recover",
]


def fail(message: str) -> None:
    raise SystemExit(f"invalid TLC witness: {message}")


def load_states(path: Path) -> list[dict[str, object]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        states = document["counterexample"]["state"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        fail(str(error))

    if not isinstance(states, list):
        fail("counterexample.state is not an array")

    result: list[dict[str, object]] = []
    for expected_index, entry in enumerate(states, start=1):
        if (
            not isinstance(entry, list)
            or len(entry) != 2
            or entry[0] != expected_index
            or not isinstance(entry[1], dict)
        ):
            fail(f"state {expected_index} has an invalid envelope")
        result.append(entry[1])
    return result


def validate(states: list[dict[str, object]]) -> None:
    actions = [state.get("action") for state in states]
    if actions != EXPECTED_ACTIONS:
        fail(f"unexpected action sequence: {actions!r}")

    published = states[3]
    unknown = states[4]
    resolved = states[5]
    crashed = states[6]
    recovered = states[7]

    head = published.get("head")
    if not isinstance(head, dict):
        fail("published state has no HEAD record")
    if head.get("sequence") != 1 or head.get("latest_batch") != "B1":
        fail("published HEAD does not name sequence 1 and B1")
    if published.get("remote_batches") != ["B1"]:
        fail("published batch is not remotely present")

    transaction = unknown.get("transaction")
    if not isinstance(transaction, dict) or transaction.get("receipt") != "Unknown":
        fail("lost response did not produce an unknown receipt")
    if transaction.get("was_unknown") is not True:
        fail("unknown-outcome history was not retained")
    if transaction.get("families") != ["F1", "F2"]:
        fail("witness transaction does not span exactly F1 and F2")

    transaction = resolved.get("transaction")
    if not isinstance(transaction, dict) or transaction.get("receipt") != "Committed":
        fail("reconciliation did not confirm the committed receipt")

    if crashed.get("local_batches") != [] or crashed.get("crash_observed") is not True:
        fail("crash did not discard local state")
    if recovered.get("local_batches") != []:
        fail("recovery unexpectedly depended on a local batch")
    if recovered.get("recovered_batches") != ["B1"]:
        fail("cacheless recovery did not reconstruct B1")
    if recovered.get("recovered_sequence") != 1:
        fail("cacheless recovery did not reconstruct sequence 1")
    if any(state.get("stale_publication_observed") is not False for state in states):
        fail("witness contains a stale-writer publication")


def workload() -> list[dict[str, object]]:
    transaction = "404142434445464748494a4b4c4d4e4f"
    reader = "505152535455565758595a5b5c5d5e5f"
    receipt = "606162636465666768696a6b6c6d6e6f"
    tuples = [
        {"column_family_id": "1", "key": "61", "value": "31"},
        {
            "column_family_id": "2",
            "key": "61",
            "value": "636f6d6d6974746564",
        },
    ]
    return [
        {
            "record": "workload",
            "schema": "flyology.db.workload.v1",
            "seed": "8675309",
            "database_id": "303132333435363738393a3b3c3d3e3f",
            "limits": {
                "transactions": 2,
                "mutations_per_transaction": 2,
                "key_bytes": 1,
                "value_bytes": 9,
            },
            "column_families": [
                {"id": "1", "name": "accounts"},
                {"id": "2", "name": "audit"},
            ],
            "required_capabilities": [
                "multi_column_family",
                "remote_durable",
                "crash_recovery",
                "outcome_resolution",
            ],
        },
        {
            "record": "operation",
            "step": 0,
            "client": "writer",
            "operation": "create",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 1,
            "client": "writer",
            "transaction": transaction,
            "operation": "begin",
            "isolation": "Snapshot",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 2,
            "client": "writer",
            "transaction": transaction,
            "operation": "put",
            "column_family_id": "1",
            "key": "61",
            "value": "31",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 3,
            "client": "writer",
            "transaction": transaction,
            "operation": "put",
            "column_family_id": "2",
            "key": "61",
            "value": "636f6d6d6974746564",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 4,
            "client": "writer",
            "transaction": transaction,
            "operation": "commit",
            "receipt": receipt,
            "durability": "remote",
            "expected": "Outcome_Unknown",
        },
        {
            "record": "operation",
            "step": 5,
            "client": "writer",
            "operation": "resolve",
            "receipt": receipt,
            "expected": "Success",
        },
        {
            "record": "checkpoint",
            "step": 6,
            "name": "tla-resolved-publication",
            "durability_barrier": True,
            "expected_tuples": tuples,
        },
        {"record": "operation", "step": 7, "client": "writer", "operation": "crash"},
        {
            "record": "operation",
            "step": 8,
            "client": "writer",
            "operation": "reopen",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 9,
            "client": "reader",
            "transaction": reader,
            "operation": "begin",
            "isolation": "Snapshot",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 10,
            "client": "reader",
            "transaction": reader,
            "operation": "get",
            "column_family_id": "1",
            "key": "61",
            "expected": "Success",
            "expected_value": "31",
        },
        {
            "record": "operation",
            "step": 11,
            "client": "reader",
            "transaction": reader,
            "operation": "get",
            "column_family_id": "2",
            "key": "61",
            "expected": "Success",
            "expected_value": "636f6d6d6974746564",
        },
        {
            "record": "operation",
            "step": 12,
            "client": "reader",
            "transaction": reader,
            "operation": "rollback",
            "expected": "Success",
        },
        {
            "record": "checkpoint",
            "step": 13,
            "name": "tla-cacheless-recovery",
            "durability_barrier": True,
            "expected_tuples": tuples,
        },
    ]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} TLC_TRACE.json")
    states = load_states(Path(sys.argv[1]))
    validate(states)
    for record in workload():
        print(json.dumps(record, separators=(",", ":"), sort_keys=False))


if __name__ == "__main__":
    main()
