#!/usr/bin/env python3
"""Reference Flyology.DB oracle logical-state digest and golden-vector gate."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
from typing import Any, Iterable

DOMAIN = b"flyology.db.oracle.state.v1\0"
SCHEMA = "flyology.db.oracle.canonical-state.v1"
FAMILY_ID = re.compile(r"[1-9][0-9]{0,9}")
LOWER_HEX = re.compile(r"(?:[0-9a-f]{2})*")


class InvalidVector(Exception):
    pass


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for name, item in pairs:
        if name in value:
            raise InvalidVector(f"duplicate member {name}")
        value[name] = item
    return value


def exact_object(value: Any, fields: set[str], context: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise InvalidVector(f"{context} fields are invalid")
    return value


def parsed_tuple(value: Any) -> tuple[int, bytes, bytes, bytes]:
    item = exact_object(
        value,
        {"column_family_id", "key", "value"},
        "tuple",
    )
    family = item["column_family_id"]
    if not isinstance(family, str) or FAMILY_ID.fullmatch(family) is None:
        raise InvalidVector("tuple family ID is not canonical decimal u32")
    family_number = int(family)
    if family_number > 0xFFFF_FFFF:
        raise InvalidVector("tuple family ID exceeds u32")
    fields: list[bytes] = []
    for name in ("key", "value"):
        encoded = item[name]
        if not isinstance(encoded, str) or LOWER_HEX.fullmatch(encoded) is None:
            raise InvalidVector(f"tuple {name} is not canonical lowercase hex")
        fields.append(bytes.fromhex(encoded))
    return family_number, family.encode("ascii"), fields[0], fields[1]


def digest_in_order(tuples: Iterable[tuple[int, bytes, bytes, bytes]]) -> str:
    digest = hashlib.sha256(DOMAIN)
    for _, family, key, value in tuples:
        for field in (family, key, value):
            digest.update(len(field).to_bytes(8, "big"))
            digest.update(field)
    return digest.hexdigest()


def canonical_digest(tuples: Iterable[dict[str, str]]) -> str:
    parsed = [parsed_tuple(item) for item in tuples]
    require_unique_keys(parsed)
    parsed.sort(key=lambda item: (item[0], item[2]))
    return digest_in_order(parsed)


def require_unique_keys(tuples: Iterable[tuple[int, bytes, bytes, bytes]]) -> None:
    keys: set[tuple[int, bytes]] = set()
    for family, _, key, _ in tuples:
        if (family, key) in keys:
            raise InvalidVector("canonical state contains a duplicate key")
        keys.add((family, key))


def validate_vectors(path: Path) -> None:
    root = exact_object(
        json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object),
        {"schema", "vectors"},
        "root",
    )
    if root["schema"] != SCHEMA or not isinstance(root["vectors"], list):
        raise InvalidVector("unsupported canonical-state vector schema")
    names: set[str] = set()
    seen_orderings: set[str] = set()
    for position, raw_vector in enumerate(root["vectors"]):
        vector = exact_object(
            raw_vector,
            {"name", "ordering", "tuples", "sha256"},
            f"vector {position}",
        )
        name = vector["name"]
        if not isinstance(name, str) or not name or name in names:
            raise InvalidVector(f"vector {position} has an invalid name")
        names.add(name)
        if vector["ordering"] not in {"canonical", "input_order"}:
            raise InvalidVector(f"vector {name} has an invalid ordering")
        seen_orderings.add(vector["ordering"])
        if not isinstance(vector["tuples"], list):
            raise InvalidVector(f"vector {name} tuples are not an array")
        parsed = [parsed_tuple(item) for item in vector["tuples"]]
        require_unique_keys(parsed)
        canonical = sorted(parsed, key=lambda item: (item[0], item[2]))
        if vector["ordering"] == "canonical" and parsed != canonical:
            raise InvalidVector(f"vector {name} is not canonically ordered")
        if vector["ordering"] == "input_order" and parsed == canonical:
            raise InvalidVector(f"vector {name} does not witness input ordering")
        expected = vector["sha256"]
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise InvalidVector(f"vector {name} digest is invalid")
        if digest_in_order(parsed) != expected:
            raise InvalidVector(f"vector {name} digest mismatch")
    if seen_orderings != {"canonical", "input_order"} or "empty" not in names:
        raise InvalidVector("golden corpus lacks required ordering and empty-state coverage")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vectors", type=Path)
    arguments = parser.parse_args()
    try:
        validate_vectors(arguments.vectors)
    except (OSError, json.JSONDecodeError, InvalidVector) as error:
        print(f"invalid canonical-state vectors: {error}")
        return 1
    print(f"validated {arguments.vectors}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
