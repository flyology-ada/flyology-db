#!/usr/bin/env python3
"""Focused tests for benchmark output and deterministic state helpers."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


COMPARISON = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(COMPARISON))

from run_local_campaign import parse_output, state_checksum  # noqa: E402


class CampaignHelperTests(unittest.TestCase):
    def test_state_checksum_is_frozen_for_two_rows(self) -> None:
        self.assertEqual(
            state_checksum(2),
            "dc2393c86b09617949264cf050acc2fb07b010e88e288ffb0a867af97e7db6f7",
        )

    def test_participant_output_accepts_ada_image_spacing(self) -> None:
        self.assertEqual(
            parse_output("elapsed_nanoseconds= 123\nverified_keys= 2\n", 2),
            123,
        )

    def test_participant_output_rejects_duplicate_fields(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "duplicate"):
            parse_output(
                "elapsed_nanoseconds=1\nelapsed_nanoseconds=2\nverified_keys=2\n",
                2,
            )

    def test_participant_output_rejects_wrong_verification_count(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "wrong key count"):
            parse_output("elapsed_nanoseconds=123\nverified_keys=1\n", 2)


if __name__ == "__main__":
    unittest.main()
