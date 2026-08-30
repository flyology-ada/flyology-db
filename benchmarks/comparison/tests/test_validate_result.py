#!/usr/bin/env python3
"""Focused tests for the dependency-free benchmark result validator."""

from __future__ import annotations

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("validate_result", ROOT / "validate_result.py")
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


def valid_result() -> dict[str, object]:
    elapsed = [2_000_000_000, 1_000_000_000, 4_000_000_000]
    samples = [
        {
            "repetition": index,
            "operations": 100,
            "bytes": 104_000,
            "elapsed_nanoseconds": duration,
            "errors": 0,
            "checksum": f"{index:064x}",
        }
        for index, duration in enumerate(elapsed, start=1)
    ]
    return {
        "schema_version": "flyology.db.benchmark.result.v1",
        "contract_sha256": VALIDATOR.contract_digest(),
        "campaign": {
            "id": "fixture",
            "classification": "directional",
            "started_at_utc": "2026-08-30T00:00:00Z",
        },
        "host": {
            "os": "fixture-os",
            "architecture": "fixture-arch",
            "cpu": "fixture-cpu",
            "memory_bytes": 1,
            "power": {
                "os": "fixture-os",
                "detector": "fixture-detector",
                "profile": "fixture-profile",
                "power_source": "fixture-source",
            },
        },
        "workload": {
            "id": "durable-single-writer-v1",
            "sha256": VALIDATOR.workload_contract()[1],
            "seed": 0,
            "key_bytes": 16,
            "value_bytes": 1024,
            "key_count": 110,
            "transaction_mutations": 1,
            "concurrency": 1,
            "warmup_operations": 10,
            "measured_operations": 100,
            "repetitions": 3,
        },
        "results": [
            {
                "lane": "local_durable",
                "participant": "flyology-db-files",
                "engine_source": "fixture-engine",
                "adapter_source": "fixture-adapter",
                "compiler": "fixture-compiler",
                "build_flags": ["-O2"],
                "storage_revision": "fixture-storage",
                "storage_configuration": {"sync": "power-loss-durable"},
                "correctness_gate": "fixture correctness gate",
                "correctness_evidence": "a" * 64,
                "dependency_sources": {"fixture": "fixture-source"},
                "power": {
                    "os": "fixture-os",
                    "detector": "fixture-detector",
                    "profile": "fixture-profile",
                    "power_source": "fixture-source",
                },
                "samples": samples,
                "median_operations_per_second": 50.0,
            },
            {
                "lane": "local_durable",
                "participant": "slatedb-local-fsync",
                "engine_source": "fixture-engine",
                "adapter_source": "fixture-adapter",
                "compiler": "fixture-compiler",
                "build_flags": ["--release"],
                "storage_revision": "fixture-storage",
                "storage_configuration": {"sync": "fsync"},
                "correctness_gate": "fixture correctness gate",
                "correctness_evidence": "b" * 64,
                "dependency_sources": {"fixture": "fixture-source"},
                "power": {
                    "os": "fixture-os",
                    "detector": "fixture-detector",
                    "profile": "fixture-profile",
                    "power_source": "fixture-source",
                },
                "samples": copy.deepcopy(samples),
                "median_operations_per_second": 50.0,
            },
            {
                "lane": "local_durable",
                "participant": "tidesdb-unified-full-sync",
                "engine_source": "fixture-engine",
                "adapter_source": "fixture-adapter",
                "compiler": "fixture-compiler",
                "build_flags": ["-O2"],
                "storage_revision": "fixture-storage",
                "storage_configuration": {"sync": "full"},
                "correctness_gate": "fixture correctness gate",
                "correctness_evidence": "c" * 64,
                "dependency_sources": {"fixture": "fixture-source"},
                "power": {
                    "os": "fixture-os",
                    "detector": "fixture-detector",
                    "profile": "fixture-profile",
                    "power_source": "fixture-source",
                },
                "samples": copy.deepcopy(samples),
                "median_operations_per_second": 50.0,
            },
        ],
    }


class ValidatorTests(unittest.TestCase):
    def validate(self, value: dict[str, object]) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            VALIDATOR.validate(path)

    def rejected(self, value: dict[str, object], message: str) -> None:
        with self.assertRaisesRegex(VALIDATOR.InvalidResult, message):
            self.validate(value)

    def test_accepts_complete_eligible_result(self) -> None:
        self.validate(valid_result())

    def test_rejects_unsupported_remote_tidesdb_result(self) -> None:
        value = valid_result()
        measurement = value["results"][0]
        measurement["lane"] = "remote_durable_rustfs"
        measurement["participant"] = "tidesdb-rustfs"
        self.rejected(value, "unsupported participant")

    def test_rejects_incomplete_lane(self) -> None:
        value = valid_result()
        value["results"].pop()
        self.rejected(value, "every eligible participant")

    def test_rejects_wrong_contract(self) -> None:
        value = valid_result()
        value["contract_sha256"] = "0" * 64
        self.rejected(value, "current panel contract")

    def test_rejects_wrong_workload(self) -> None:
        value = valid_result()
        value["workload"]["value_bytes"] = 512
        self.rejected(value, "workload contract")

    def test_rejects_missing_provenance(self) -> None:
        value = valid_result()
        del value["results"][0]["compiler"]
        self.rejected(value, "missing members")

    def test_rejects_duplicate_measurement(self) -> None:
        value = valid_result()
        value["results"].append(copy.deepcopy(value["results"][0]))
        self.rejected(value, "duplicate measurement")

    def test_rejects_noncontiguous_repetitions(self) -> None:
        value = valid_result()
        value["results"][0]["samples"][1]["repetition"] = 3
        self.rejected(value, "not contiguous")

    def test_rejects_errors(self) -> None:
        value = valid_result()
        value["results"][0]["samples"][0]["errors"] = 1
        self.rejected(value, "errors must be zero")

    def test_rejects_invented_summary(self) -> None:
        value = valid_result()
        value["results"][0]["median_operations_per_second"] = 999.0
        self.rejected(value, "does not match samples")

    def test_rejects_mismatched_power_profile(self) -> None:
        value = valid_result()
        value["results"][1]["power"]["profile"] = "reduced"
        self.rejected(value, "campaign power profile")

    def test_rejects_divergent_state_checksum(self) -> None:
        value = valid_result()
        value["results"][1]["samples"][0]["checksum"] = "f" * 64
        self.rejected(value, "state checksums do not match")


if __name__ == "__main__":
    unittest.main()
