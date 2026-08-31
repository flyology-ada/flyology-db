#!/usr/bin/env python3
"""Create a filename-safe archive of authorized untracked benchmark source."""

from __future__ import annotations

import hashlib
import io
import json
import os
import stat
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath


def fail(message: str) -> None:
    raise SystemExit(message)


def safe_relative_name(raw: bytes) -> str:
    name = os.fsdecode(raw)
    path = PurePosixPath(name)
    if not name or path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail(f"unsafe untracked source path: {name!r}")
    return name


def file_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
    )


def main() -> None:
    if len(sys.argv) < 4:
        fail(
            "usage: package-source.py REPOSITORY MANIFEST ARCHIVE "
            "[--allow-manifest MANIFEST | PATH ...]"
        )
    repository = Path(sys.argv[1]).resolve()
    manifest_path = Path(sys.argv[2])
    archive_path = Path(sys.argv[3])
    completed = subprocess.run(
        ["git", "ls-files", "-z", "--others", "--exclude-standard"],
        cwd=repository,
        stdout=subprocess.PIPE,
        check=True,
    )
    observed = sorted(
        safe_relative_name(raw)
        for raw in completed.stdout.split(b"\0")
        if raw and not raw.startswith(b"benchmarks/comparison/results/")
    )
    arguments = sys.argv[4:]
    if arguments[:1] == ["--allow-manifest"]:
        if len(arguments) != 2:
            fail("--allow-manifest requires exactly one manifest")
        retained = json.loads(Path(arguments[1]).read_text(encoding="ascii"))
        names = sorted(
            safe_relative_name(os.fsencode(row["path"])) for row in retained
        )
    else:
        names = sorted(safe_relative_name(os.fsencode(name)) for name in arguments)
    if len(names) != len(set(names)):
        fail("duplicate admitted untracked source path")
    if observed != names:
        fail(
            "untracked source admission mismatch: "
            f"observed={observed!r} admitted={names!r}"
        )

    manifest = []
    with tarfile.open(archive_path, "w:gz", dereference=False) as archive:
        for name in names:
            source = repository / name
            metadata = source.lstat()
            if stat.S_ISREG(metadata.st_mode):
                content = source.read_bytes()
                if file_identity(source.lstat()) != file_identity(metadata):
                    fail(f"untracked source changed while reading: {name!r}")
                information = archive.gettarinfo(str(source), arcname=name)
                if information.size != len(content):
                    fail(f"untracked source size changed while archiving: {name!r}")
                digest = hashlib.sha256(content).hexdigest()
                kind = "regular"
                target = None
                archive.addfile(information, io.BytesIO(content))
            elif stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(source)
                if file_identity(source.lstat()) != file_identity(metadata):
                    fail(f"untracked source changed while reading: {name!r}")
                target_path = PurePosixPath(target)
                if target_path.is_absolute() or ".." in target_path.parts:
                    fail(f"unsafe untracked source symlink: {name!r} -> {target!r}")
                information = archive.gettarinfo(str(source), arcname=name)
                if information.linkname != target:
                    fail(f"untracked source link changed while archiving: {name!r}")
                digest = None
                kind = "symlink"
                archive.addfile(information)
            else:
                fail(f"unsupported untracked source type: {name!r}")
            manifest.append(
                {
                    "path": name,
                    "kind": kind,
                    "mode": stat.S_IMODE(metadata.st_mode),
                    "sha256": digest,
                    "target": target,
                }
            )

    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
        encoding="ascii",
    )


if __name__ == "__main__":
    main()
