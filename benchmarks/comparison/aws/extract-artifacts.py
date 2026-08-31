#!/usr/bin/env python3
"""Extract a remote evidence archive without links or path traversal."""

from __future__ import annotations

import os
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: extract-artifacts.py ARCHIVE NEW_DESTINATION")
    archive_path = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    destination.mkdir(mode=0o700, parents=False, exist_ok=False)
    seen: set[str] = set()
    top_level: set[str] = set()
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive.getmembers():
            if member.name in (".", "./"):
                continue
            name = member.name.removeprefix("./")
            path = PurePosixPath(name)
            if not name or path.is_absolute() or ".." in path.parts or name in seen:
                fail(f"unsafe or duplicate artifact member: {member.name!r}")
            seen.add(name)
            top_level.add(path.parts[0])
            target = destination / name
            if member.isdir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    fail(f"artifact member has no content: {member.name!r}")
                descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "wb") as output:
                    while chunk := source.read(1024 * 1024):
                        output.write(chunk)
                os.chmod(target, stat.S_IMODE(member.mode) & 0o777)
            else:
                fail(f"artifact member type is not permitted: {member.name!r}")
    if not {"campaign.log", "exit-status"} <= top_level or not top_level <= {
        "campaign.log",
        "evidence",
        "exit-status",
    }:
        fail(f"unexpected artifact top-level inventory: {sorted(top_level)!r}")


if __name__ == "__main__":
    main()
