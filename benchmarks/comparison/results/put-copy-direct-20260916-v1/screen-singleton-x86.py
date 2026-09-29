#!/usr/bin/env python3
"""Hold publication geometry at one batch/HEAD per transaction."""

import importlib.util
from pathlib import Path


BASE = Path(__file__).with_name("screen-x86.py")
SPEC = importlib.util.spec_from_file_location("put_copy_screen", BASE)
assert SPEC is not None and SPEC.loader is not None
SCREEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCREEN)

SCREEN.CONTENDER = "flyology-db-files-singleton-depth8"
SCREEN.OUT = SCREEN.ROOT / "evidence/singleton-screen-v2"
SCREEN.SCRATCH = SCREEN.ROOT / "singleton-scratch-v2"
SCREEN.ORDER = ("baseline", "direct", "direct", "baseline")

ORIGINAL_INSPECT = SCREEN.inspect_metrics


def inspect_singleton(json_path, path, validator):
    result = ORIGINAL_INSPECT(json_path, path, validator)
    SCREEN.require(all(count == 35 for count in result["batch_counts"]),
                   "singleton comparison changed batch/HEAD geometry")
    return result


SCREEN.inspect_metrics = inspect_singleton
SCREEN.main()
