#!/usr/bin/env python3
"""Bridge the pinned RustFS harness to the realistic flyology_bench matrix."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent


def main() -> int:
    if len(sys.argv) != 5:
        raise RuntimeError("usage: run_realistic_rustfs.py ENDPOINT BUCKET ACCESS SECRET")
    endpoint, bucket, access_key, secret_key = sys.argv[1:]
    if endpoint.startswith("http://host.docker.internal:"):
        endpoint = f"http://127.0.0.1:{endpoint.rsplit(':', 1)[1]}"
    if not endpoint.startswith("http://127.0.0.1:"):
        raise RuntimeError(f"unexpected RustFS endpoint {endpoint}")

    subprocess.run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--fail",
            "--aws-sigv4",
            "aws:amz:us-east-1:s3",
            "--user",
            f"{access_key}:{secret_key}",
            "--request",
            "PUT",
            f"{endpoint}/{bucket}",
        ],
        check=True,
    )
    environment = os.environ.copy()
    environment.update(
        {
            "AWS_ACCESS_KEY_ID": access_key,
            "AWS_SECRET_ACCESS_KEY": secret_key,
            "FLYOLOGY_DB_BENCH_ENDPOINT": endpoint,
            "FLYOLOGY_DB_BENCH_BUCKET": bucket,
        }
    )
    output = Path(environment["FLYOLOGY_DB_BENCHMARK_OUTPUT"])
    raw = output.parent / f"{output.stem}-raw"
    arguments = [
        sys.executable,
        str(HERE / "run_realistic_campaign.py"),
        "--lane",
        "rustfs",
        "--output",
        str(output),
    ]
    if not output.exists() and (raw / "campaign.json").is_file():
        arguments.append("--resume")
    completed = subprocess.run(
        arguments,
        cwd=HERE,
        env=environment,
        check=False,
    )
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
