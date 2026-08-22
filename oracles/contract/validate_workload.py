#!/usr/bin/env python3
"""Validate Flyology.DB v1 NDJSON workloads without third-party packages."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

HEX = re.compile(r"^(?:[0-9a-f]{2})*$")
IDENTIFIER = re.compile(r"^[0-9a-f]{32}$")
FAMILY_ID = re.compile(r"^[1-9][0-9]*$")
OUTCOMES = {
    "Success",
    "Not_Found",
    "Conflict",
    "Serialization_Failure",
    "Timed_Out",
    "Cancelled",
    "Outcome_Unknown",
    "Corrupt",
    "Unsupported",
}
CAPABILITIES = {
    "multi_column_family",
    "remote_durable",
    "snapshot",
    "serializable",
    "crash_recovery",
    "outcome_resolution",
}
BASE = {"record", "step", "client", "operation"}
RULES = {
    "create": (BASE | {"expected"}, BASE | {"expected"}),
    "open": (BASE | {"expected"}, BASE | {"expected"}),
    "reopen": (BASE | {"expected"}, BASE | {"expected"}),
    "flush": (BASE | {"expected"}, BASE | {"expected"}),
    "checkpoint": (BASE | {"expected"}, BASE | {"expected"}),
    "begin": (
        BASE | {"transaction", "isolation", "expected"},
        BASE | {"transaction", "isolation", "expected"},
    ),
    "get": (
        BASE
        | {"transaction", "column_family_id", "key", "expected", "expected_value"},
        BASE | {"transaction", "column_family_id", "key", "expected"},
    ),
    "scan": (
        BASE
        | {
            "transaction",
            "column_family_id",
            "lower",
            "upper",
            "maximum_items",
            "expected",
        },
        BASE
        | {
            "transaction",
            "column_family_id",
            "lower",
            "upper",
            "maximum_items",
            "expected",
        },
    ),
    "put": (
        BASE | {"transaction", "column_family_id", "key", "value", "expected"},
        BASE | {"transaction", "column_family_id", "key", "value", "expected"},
    ),
    "delete": (
        BASE | {"transaction", "column_family_id", "key", "expected"},
        BASE | {"transaction", "column_family_id", "key", "expected"},
    ),
    "rollback": (
        BASE | {"transaction", "expected"},
        BASE | {"transaction", "expected"},
    ),
    "commit": (
        BASE | {"transaction", "receipt", "durability", "expected"},
        BASE | {"transaction", "durability", "expected"},
    ),
    "resolve": (
        BASE | {"receipt", "expected"},
        BASE | {"receipt", "expected"},
    ),
    "crash": (BASE, BASE),
}


class InvalidWorkload(Exception):
    """One deterministic workload-contract violation."""


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidWorkload(f"duplicate JSON member {key!r}")
        result[key] = value
    return result


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InvalidWorkload(message)


def require_exact_fields(
    record: dict[str, Any], allowed: set[str], required: set[str], context: str
) -> None:
    missing = required - record.keys()
    extra = record.keys() - allowed
    require(not missing, f"{context}: missing fields {sorted(missing)}")
    require(not extra, f"{context}: unsupported fields {sorted(extra)}")


def require_hex(value: Any, maximum: int, context: str) -> None:
    require(isinstance(value, str) and HEX.fullmatch(value) is not None, context)
    require(len(value) // 2 <= maximum, f"{context}: exceeds declared byte limit")


def require_identifier(value: Any, context: str) -> None:
    require(
        isinstance(value, str) and IDENTIFIER.fullmatch(value) is not None,
        context,
    )


def validate_schema_contract(schema: dict[str, Any]) -> None:
    """Prove that the checked-in schema and executable field rules agree."""
    require(
        schema.get("$schema") == "https://json-schema.org/draft/2020-12/schema",
        "workload schema is not draft 2020-12",
    )
    definitions = schema.get("$defs")
    require(isinstance(definitions, dict), "workload schema has no $defs")
    require(definitions.get("hex", {}).get("pattern") == HEX.pattern, "hex schema drift")
    require(
        definitions.get("id", {}).get("pattern") == IDENTIFIER.pattern,
        "identifier schema drift",
    )
    require(
        definitions.get("family_id", {}).get("pattern") == FAMILY_ID.pattern,
        "family-ID schema drift",
    )
    require(
        set(definitions.get("outcome", {}).get("enum", [])) == OUTCOMES,
        "outcome schema drift",
    )

    workload = definitions.get("workload", {})
    workload_fields = {
        "record",
        "schema",
        "seed",
        "database_id",
        "limits",
        "column_families",
        "required_capabilities",
    }
    require(workload.get("additionalProperties") is False, "workload schema is open")
    require(set(workload.get("required", [])) == workload_fields, "workload required drift")
    require(
        set(workload.get("properties", {})) == workload_fields,
        "workload field schema drift",
    )
    capability_schema = workload["properties"]["required_capabilities"]["items"]
    require(set(capability_schema.get("enum", [])) == CAPABILITIES, "capability drift")

    operation_union = definitions.get("operation", {}).get("oneOf", [])
    references = [item.get("$ref", "") for item in operation_union]
    require(len(references) == len(set(references)), "duplicate operation schema branch")
    covered: set[str] = set()
    for reference in references:
        prefix = "#/$defs/"
        require(reference.startswith(prefix), "operation schema uses an external branch")
        branch = definitions.get(reference[len(prefix) :], {})
        require(branch.get("type") == "object", "operation branch is not an object")
        require(branch.get("additionalProperties") is False, "operation branch is open")
        properties = branch.get("properties", {})
        operation_schema = properties.get("operation", {})
        if "const" in operation_schema:
            operations = {operation_schema["const"]}
        else:
            operations = set(operation_schema.get("enum", []))
        require(bool(operations), "operation branch has no discriminator")
        for operation in operations:
            require(operation in RULES, f"schema has unknown operation {operation!r}")
            require(operation not in covered, f"schema repeats operation {operation!r}")
            allowed, required = RULES[operation]
            require(set(properties) == allowed, f"{operation} allowed-field schema drift")
            require(set(branch.get("required", [])) == required, f"{operation} required drift")
            covered.add(operation)
    require(covered == set(RULES), "schema omits an executable operation")

    get_condition = definitions["get_operation"].get("allOf")
    require(
        get_condition
        == [
            {
                "if": {"properties": {"expected": {"const": "Success"}}},
                "then": {"required": ["expected_value"]},
                "else": {"not": {"required": ["expected_value"]}},
            }
        ],
        "get expected-value condition drift",
    )
    commit_condition = definitions["commit_operation"].get("allOf")
    require(
        commit_condition
        == [
            {
                "if": {
                    "properties": {
                        "expected": {"enum": ["Success", "Outcome_Unknown"]}
                    }
                },
                "then": {"required": ["receipt"]},
                "else": {"not": {"required": ["receipt"]}},
            }
        ],
        "commit receipt condition drift",
    )

    checkpoint = definitions.get("checkpoint", {})
    checkpoint_fields = {
        "record",
        "step",
        "name",
        "digest",
        "durability_barrier",
        "expected_tuples",
    }
    require(checkpoint.get("additionalProperties") is False, "checkpoint schema is open")
    require(
        set(checkpoint.get("properties", {})) == checkpoint_fields,
        "checkpoint field schema drift",
    )
    require(
        set(checkpoint.get("required", [])) == {"record", "step", "name"},
        "checkpoint required-field drift",
    )


def load_records(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        require(bool(text.strip()), f"{path}:{line_number}: blank lines are not allowed")
        try:
            value = json.loads(text, object_pairs_hook=unique_object)
        except (json.JSONDecodeError, InvalidWorkload) as exc:
            raise InvalidWorkload(f"{path}:{line_number}: {exc}") from exc
        require(isinstance(value, dict), f"{path}:{line_number}: record is not an object")
        records.append(value)
    require(bool(records), f"{path}: workload is empty")
    return records


def validate_header(record: dict[str, Any]) -> tuple[set[str], dict[str, int]]:
    allowed = {
        "record",
        "schema",
        "seed",
        "database_id",
        "limits",
        "column_families",
        "required_capabilities",
    }
    require_exact_fields(record, allowed, allowed, "workload")
    require(record["record"] == "workload", "first record must be workload")
    require(record["schema"] == "flyology.db.workload.v1", "unsupported schema")
    require(
        isinstance(record["seed"], str) and record["seed"].isdigit(),
        "seed must be an unsigned decimal string",
    )
    require_identifier(record["database_id"], "invalid database_id")

    limits = record["limits"]
    limit_fields = {
        "transactions",
        "mutations_per_transaction",
        "key_bytes",
        "value_bytes",
    }
    require(isinstance(limits, dict), "limits must be an object")
    require_exact_fields(limits, limit_fields, limit_fields, "limits")
    for name in ("transactions", "mutations_per_transaction"):
        require(
            isinstance(limits[name], int)
            and not isinstance(limits[name], bool)
            and limits[name] >= 1,
            f"{name} must be a positive integer",
        )
    for name in ("key_bytes", "value_bytes"):
        require(
            isinstance(limits[name], int)
            and not isinstance(limits[name], bool)
            and limits[name] >= 0,
            f"{name} must be a nonnegative integer",
        )

    families = record["column_families"]
    require(isinstance(families, list) and families, "column_families must be nonempty")
    ids: set[str] = set()
    names: set[str] = set()
    for position, family in enumerate(families):
        require(isinstance(family, dict), f"column family {position} is not an object")
        require_exact_fields(family, {"id", "name"}, {"id", "name"}, "column family")
        require(
            isinstance(family["id"], str)
            and FAMILY_ID.fullmatch(family["id"]) is not None,
            "invalid column-family ID",
        )
        require(
            isinstance(family["name"], str) and bool(family["name"]),
            "column-family name is empty",
        )
        require(family["id"] not in ids, "duplicate column-family ID")
        require(family["name"] not in names, "duplicate column-family name")
        ids.add(family["id"])
        names.add(family["name"])

    capabilities = record["required_capabilities"]
    require(isinstance(capabilities, list), "required_capabilities must be an array")
    require(all(item in CAPABILITIES for item in capabilities), "unknown capability")
    require(len(capabilities) == len(set(capabilities)), "duplicate required capability")
    return ids, limits


def validate_checkpoint(
    record: dict[str, Any],
    families: set[str],
    key_limit: int,
    value_limit: int,
) -> None:
    allowed = {"record", "step", "name", "digest", "durability_barrier", "expected_tuples"}
    require_exact_fields(record, allowed, {"record", "step", "name"}, "checkpoint")
    require(isinstance(record["name"], str) and bool(record["name"]), "empty checkpoint name")
    require(
        "digest" in record or "expected_tuples" in record,
        "checkpoint must assert a digest or expected_tuples",
    )
    if "digest" in record:
        digest = record["digest"]
        require(
            isinstance(digest, str)
            and len(digest) == 64
            and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
            "invalid checkpoint digest",
        )
    if "durability_barrier" in record:
        require(
            isinstance(record["durability_barrier"], bool),
            "durability_barrier must be boolean",
        )
    if "expected_tuples" not in record:
        return

    tuples = record["expected_tuples"]
    require(isinstance(tuples, list), "expected_tuples must be an array")
    order: list[tuple[int, bytes]] = []
    for item in tuples:
        require(isinstance(item, dict), "expected tuple is not an object")
        require_exact_fields(
            item,
            {"column_family_id", "key", "value"},
            {"column_family_id", "key", "value"},
            "expected tuple",
        )
        family = item["column_family_id"]
        require(family in families, "expected tuple uses an unknown family")
        require_hex(item["key"], key_limit, "invalid expected tuple key")
        require_hex(item["value"], value_limit, "invalid expected tuple value")
        order.append((int(family), bytes.fromhex(item["key"])))
    require(order == sorted(order), "expected_tuples are not in canonical order")
    require(len(order) == len(set(order)), "duplicate expected tuple key")


def validate_operation(
    record: dict[str, Any],
    families: set[str],
    limits: dict[str, int],
    active: dict[str, int],
    unknown_receipts: set[str],
    seen_receipts: set[str],
) -> None:
    operation = record.get("operation")
    require(operation in RULES, f"unknown operation {operation!r}")
    allowed, required = RULES[operation]
    require_exact_fields(record, allowed, required, f"operation {operation}")
    require(record["record"] == "operation", "operation record has wrong discriminator")
    require(isinstance(record["client"], str) and bool(record["client"]), "empty client")

    if "expected" in record:
        require(record["expected"] in OUTCOMES, "unknown expected outcome")
    if "transaction" in record:
        require_identifier(record["transaction"], "invalid transaction ID")
    if "receipt" in record:
        require_identifier(record["receipt"], "invalid receipt ID")
    if "column_family_id" in record:
        require(record["column_family_id"] in families, "operation uses unknown family")
    if "key" in record:
        require_hex(record["key"], limits["key_bytes"], "invalid operation key")
    if "value" in record:
        require_hex(record["value"], limits["value_bytes"], "invalid operation value")
    if "expected_value" in record:
        require_hex(
            record["expected_value"],
            limits["value_bytes"],
            "invalid expected value",
        )

    if operation == "begin":
        require(record["isolation"] in {"Snapshot", "Serializable"}, "invalid isolation")
        transaction = record["transaction"]
        require(transaction not in active, "transaction ID is already active")
        if record["expected"] == "Success":
            require(
                len(active) < limits["transactions"],
                "successful begin exceeds transaction limit",
            )
            active[transaction] = 0
    elif operation in {"get", "scan", "put", "delete", "rollback", "commit"}:
        transaction = record["transaction"]
        require(transaction in active, f"{operation} uses an inactive transaction")
        if operation in {"put", "delete"} and record["expected"] == "Success":
            active[transaction] += 1
            require(
                active[transaction] <= limits["mutations_per_transaction"],
                "successful mutation exceeds transaction limit",
            )
        if operation == "rollback" and record["expected"] == "Success":
            del active[transaction]

    if operation == "get":
        if record["expected"] == "Success":
            require("expected_value" in record, "successful get lacks expected_value")
        else:
            require("expected_value" not in record, "failed get has expected_value")
    elif operation == "scan":
        require_hex(record["lower"], limits["key_bytes"], "invalid scan lower bound")
        require_hex(record["upper"], limits["key_bytes"], "invalid scan upper bound")
        require(bytes.fromhex(record["lower"]) < bytes.fromhex(record["upper"]), "empty scan")
        require(
            isinstance(record["maximum_items"], int)
            and not isinstance(record["maximum_items"], bool)
            and record["maximum_items"] >= 1,
            "invalid scan maximum_items",
        )
    elif operation == "commit":
        require(record["durability"] == "remote", "unsupported commit durability")
        if record["expected"] in {"Success", "Outcome_Unknown"}:
            require("receipt" in record, "published or unknown commit lacks receipt")
            receipt = record["receipt"]
            require(receipt not in seen_receipts, "commit receipt was reused")
            seen_receipts.add(receipt)
            del active[record["transaction"]]
            if record["expected"] == "Outcome_Unknown":
                unknown_receipts.add(receipt)
        else:
            require("receipt" not in record, "definite failed commit has a receipt")
    elif operation == "resolve":
        receipt = record["receipt"]
        require(receipt in unknown_receipts, "resolve uses no unknown receipt")
        if record["expected"] in {"Success", "Not_Found", "Conflict"}:
            unknown_receipts.remove(receipt)
    elif operation == "crash":
        active.clear()


def validate(path: Path, schema_path: Path) -> None:
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except (json.JSONDecodeError, InvalidWorkload) as exc:
        raise InvalidWorkload(f"{schema_path}: {exc}") from exc
    require(isinstance(schema, dict), "workload schema is not an object")
    validate_schema_contract(schema)

    records = load_records(path)
    families, limits = validate_header(records[0])
    active: dict[str, int] = {}
    unknown_receipts: set[str] = set()
    seen_receipts: set[str] = set()
    last_step = -1
    for record in records[1:]:
        step = record.get("step")
        require(
            isinstance(step, int) and not isinstance(step, bool) and step > last_step,
            "steps must be strictly increasing integers",
        )
        last_step = step
        if record.get("record") == "operation":
            validate_operation(
                record,
                families,
                limits,
                active,
                unknown_receipts,
                seen_receipts,
            )
        elif record.get("record") == "checkpoint":
            validate_checkpoint(
                record,
                families,
                limits["key_bytes"],
                limits["value_bytes"],
            )
        else:
            raise InvalidWorkload(f"unknown record discriminator {record.get('record')!r}")
    require(not active, "workload ends with active transactions")


def main(arguments: list[str]) -> int:
    if len(arguments) < 2:
        print("usage: validate_workload.py SCHEMA WORKLOAD...", file=sys.stderr)
        return 2
    schema_path = Path(arguments[0])
    try:
        for name in arguments[1:]:
            path = Path(name)
            validate(path, schema_path)
            print(f"validated {path}")
    except (InvalidWorkload, OSError) as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
