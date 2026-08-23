from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ADAPTER_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = ADAPTER_ROOT.parents[2]
RUNNER = ADAPTER_ROOT / "run_workload.py"
sys.path.insert(0, str(ADAPTER_ROOT))

from adapter import TIDES_FAMILY_PATH_RESERVE  # noqa: E402


class WorkloadRunnerTests(unittest.TestCase):
    def test_remote_workload_fails_preflight_without_creating_database(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(REPOSITORY_ROOT / "oracles" / "workloads" / "log_only_cross_family.ndjson"),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertEqual(response["outcome"], "Unsupported")
            self.assertIn("remote_durable", response["unsupported_capabilities"])
            self.assertFalse(database.exists())

    def test_explicit_unsupported_remote_commit_is_comparable(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "database"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "unsupported_remote_commit.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"outcome": "Success"})
            self.assertTrue(database.exists())

    def test_serializable_scan_fails_preflight_without_creating_database(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "serializable_scan_unsupported.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertIn(
                "serializable_range_phantoms",
                response["unsupported_capabilities"],
            )
            self.assertFalse(database.exists())

    def test_empty_key_fails_preflight_without_creating_database(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "empty_key_unsupported.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertIn("empty_keys", response["unsupported_capabilities"])
            self.assertFalse(database.exists())

    def test_oversized_declared_limit_fails_preflight_without_effects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "oversized_limit_unsupported.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertIn(
                "limit.transactions",
                response["unsupported_capabilities"],
            )
            self.assertFalse(database.exists())

    def test_unsafe_family_name_fails_preflight_without_effects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "unsafe_family_name_unsupported.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertIn(
                "invalid.column_family_name",
                response["unsupported_capabilities"],
            )
            self.assertFalse(database.exists())

    def test_out_of_range_family_id_fails_preflight_without_effects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "out_of_range_family_id_unsupported.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertIn(
                "invalid.column_family_id",
                response["unsupported_capabilities"],
            )
            self.assertFalse(database.exists())

    def test_long_family_id_fails_preflight_without_effects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "long_family_id_unsupported.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertIn(
                "invalid.column_family_id",
                response["unsupported_capabilities"],
            )
            self.assertFalse(database.exists())

    def test_reserved_family_name_fails_preflight_without_effects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            database = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "reserved_family_name_unsupported.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertIn(
                "invalid.column_family_name",
                response["unsupported_capabilities"],
            )
            self.assertFalse(database.exists())

    def test_constructed_path_budget_fails_preflight_without_effects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            base = str(Path(temporary) / "must-not-exist")
            rejected_length = (
                4095 - 1 - len("default") - TIDES_FAMILY_PATH_RESERVE + 1
            )
            database = Path(base + "x" * (rejected_length - len(base)))
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "unsupported_remote_commit.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertIn(
                "invalid.database_layout",
                response["unsupported_capabilities"],
            )
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_checkpoint_path_budget_fails_preflight_without_effects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="flyology-tides-runner-") as temporary:
            parent_length = 4040
            parent_text = temporary
            remaining = parent_length - len(parent_text)
            components: list[str] = []
            while remaining > 201:
                components.append("x" * 200)
                remaining -= 201
            if remaining == 1:
                components[-1] = components[-1][:-1]
                remaining = 2
            if remaining:
                components.append("x" * (remaining - 1))
            parent_text += "".join("/" + component for component in components)
            self.assertEqual(len(parent_text), parent_length)
            self.assertLessEqual(max(map(len, components)), 200)
            parent = Path(parent_text)
            database = parent / "d"
            result = subprocess.run(
                [
                    str(RUNNER),
                    str(
                        ADAPTER_ROOT
                        / "tests"
                        / "fixtures"
                        / "checkpoint_path_unsupported.ndjson"
                    ),
                    str(database),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            response = json.loads(result.stdout)
            self.assertNotIn(
                "invalid.database_layout",
                response["unsupported_capabilities"],
            )
            self.assertIn(
                "invalid.checkpoint_layout",
                response["unsupported_capabilities"],
            )
            self.assertEqual(list(Path(temporary).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
