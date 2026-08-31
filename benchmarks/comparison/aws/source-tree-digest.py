#!/usr/bin/env python3
"""Hash the immutable source portion of an Alire materialization."""

from __future__ import annotations

import hashlib
import os
import stat
import sys
from pathlib import Path


GENERATED_ROOTS = frozenset((".git", "alire", "build", "config", "lib", "obj"))


def add_field(digest: hashlib._Hash, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: source-tree-digest.py MATERIALIZED_SOURCE")
    root = Path(sys.argv[1]).resolve()
    digest = hashlib.sha256()
    paths = sorted(
        path
        for path in root.rglob("*")
        if path.relative_to(root).parts[0] not in GENERATED_ROOTS
        and not stat.S_ISDIR(path.lstat().st_mode)
    )
    for path in paths:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        metadata = path.lstat()
        add_field(digest, relative)
        add_field(digest, str(stat.S_IMODE(metadata.st_mode)).encode("ascii"))
        if path.is_symlink():
            add_field(digest, b"link")
            add_field(digest, os.readlink(path).encode("utf-8"))
        elif path.is_file():
            add_field(digest, b"file")
            add_field(digest, hashlib.sha256(path.read_bytes()).digest())
        else:
            raise SystemExit(f"unsupported source path type: {relative!r}")
    print(digest.hexdigest())


if __name__ == "__main__":
    main()
