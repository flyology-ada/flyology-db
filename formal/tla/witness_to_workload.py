#!/usr/bin/env python3
"""Validate a TLC publication witness and project it to workload NDJSON."""

from __future__ import annotations

import json
import sys
from pathlib import Path


EXPECTED_ACTIONS = [
    "Init",
    "PreparePooled",
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
    if head.get("sequence") != 2 or head.get("latest_batch") != "B1":
        fail("published HEAD does not name sequence 2 and B1")
    if published.get("remote_batches") != ["B1"]:
        fail("published batch is not remotely present")

    batch = published.get("batch")
    if not isinstance(batch, dict):
        fail("published state has no batch record")
    if batch.get("transactions") != ["T1", "T2"]:
        fail("published batch does not contain both transactions")
    if batch.get("first_sequence") != 1 or batch.get("last_sequence") != 2:
        fail("published batch does not span commit sequences 1 through 2")

    unknown_transactions = unknown.get("transactions")
    if not isinstance(unknown_transactions, dict):
        fail("lost response has no transaction map")
    resolved_transactions = resolved.get("transactions")
    if not isinstance(resolved_transactions, dict):
        fail("reconciliation has no transaction map")
    expected_families = {"T1": ["F1", "F2"], "T2": ["F2"]}
    for transaction_id, families in expected_families.items():
        transaction = unknown_transactions.get(transaction_id)
        if not isinstance(transaction, dict) or transaction.get("receipt") != "Unknown":
            fail(f"lost response did not make {transaction_id} unknown")
        if transaction.get("was_unknown") is not True:
            fail(f"unknown-outcome history was not retained for {transaction_id}")
        if transaction.get("families") != families:
            fail(f"{transaction_id} has unexpected families")
        transaction = resolved_transactions.get(transaction_id)
        if not isinstance(transaction, dict) or transaction.get("receipt") != "Committed":
            fail(f"reconciliation did not commit {transaction_id}")

    if crashed.get("local_batches") != [] or crashed.get("crash_observed") is not True:
        fail("crash did not discard local state")
    if recovered.get("local_batches") != []:
        fail("recovery unexpectedly depended on a local batch")
    if recovered.get("recovered_batches") != ["B1"]:
        fail("cacheless recovery did not reconstruct B1")
    if recovered.get("recovered_sequence") != 2:
        fail("cacheless recovery did not reconstruct sequence 2")
    if recovered.get("recovered_transactions") != ["T1", "T2"]:
        fail("cacheless recovery did not reconstruct both transactions")
    if any(state.get("stale_publication_observed") is not False for state in states):
        fail("witness contains a stale-writer publication")


def workload() -> list[dict[str, object]]:
    transaction_1 = "404142434445464748494a4b4c4d4e4f"
    transaction_2 = "505152535455565758595a5b5c5d5e5f"
    receipt_1 = "606162636465666768696a6b6c6d6e6f"
    reader = "707172737475767778797a7b7c7d7e7f"
    receipt_2 = "808182838485868788898a8b8c8d8e8f"
    commit_group = "909192939495969798999a9b9c9d9e9f"
    tuples = [
        {"column_family_id": "1", "key": "61", "value": "31"},
        {
            "column_family_id": "2",
            "key": "61",
            "value": "636f6d6d6974746564",
        },
        {"column_family_id": "2", "key": "62", "value": "32"},
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
                "group_commit",
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
            "transaction": transaction_1,
            "operation": "begin",
            "isolation": "Snapshot",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 2,
            "client": "writer",
            "transaction": transaction_1,
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
            "transaction": transaction_1,
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
            "transaction": transaction_2,
            "operation": "begin",
            "isolation": "Snapshot",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 5,
            "client": "writer",
            "transaction": transaction_2,
            "operation": "put",
            "column_family_id": "2",
            "key": "62",
            "value": "32",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 6,
            "client": "writer",
            "transaction": transaction_1,
            "operation": "commit",
            "receipt": receipt_1,
            "commit_group": commit_group,
            "durability": "remote",
            "expected": "Outcome_Unknown",
        },
        {
            "record": "operation",
            "step": 7,
            "client": "writer",
            "transaction": transaction_2,
            "operation": "commit",
            "receipt": receipt_2,
            "commit_group": commit_group,
            "durability": "remote",
            "expected": "Outcome_Unknown",
        },
        {
            "record": "operation",
            "step": 8,
            "client": "writer",
            "operation": "resolve",
            "receipt": receipt_1,
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 9,
            "client": "writer",
            "operation": "resolve",
            "receipt": receipt_2,
            "expected": "Success",
        },
        {
            "record": "checkpoint",
            "step": 10,
            "name": "tla-resolved-publication",
            "durability_barrier": True,
            "expected_tuples": tuples,
        },
        {"record": "operation", "step": 11, "client": "writer", "operation": "crash"},
        {
            "record": "operation",
            "step": 12,
            "client": "writer",
            "operation": "reopen",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 13,
            "client": "reader",
            "transaction": reader,
            "operation": "begin",
            "isolation": "Snapshot",
            "expected": "Success",
        },
        {
            "record": "operation",
            "step": 14,
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
            "step": 15,
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
            "step": 16,
            "client": "reader",
            "transaction": reader,
            "operation": "get",
            "column_family_id": "2",
            "key": "62",
            "expected": "Success",
            "expected_value": "32",
        },
        {
            "record": "operation",
            "step": 17,
            "client": "reader",
            "transaction": reader,
            "operation": "rollback",
            "expected": "Success",
        },
        {
            "record": "checkpoint",
            "step": 18,
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
