#!/usr/bin/env python3
"""Run one remote-durability campaign inside the pinned RustFS harness."""

from __future__ import annotations

import hashlib
import json
import os
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from run_local_campaign import (
    FLYOLOGY_EXECUTABLE,
    HERE,
    INDEXED_FOS,
    INDEXED_FOS_COMMIT,
    KEY_BYTES,
    MAXIMUM_OPERATIONS,
    ROOT,
    SLATEDB_EXECUTABLE,
    VALUE_BYTES,
    contract_digest,
    flyology_index_commit,
    host_metadata,
    parse_output,
    power_profile,
    run,
    sha256_file,
    state_checksum,
)


def positive_environment(name: str, default: int) -> int:
    value = int(os.environ.get(name, str(default)))
    if value <= 0:
        raise RuntimeError(f"{name} must be positive")
    return value


def command(
    participant: str,
    endpoint: str,
    bucket: str,
    prefix: str,
    access_key: str,
    secret_key: str,
    warmup: int,
    measured: int,
) -> list[str]:
    if participant == "flyology-db-rustfs":
        return [
            str(FLYOLOGY_EXECUTABLE),
            "s3",
            endpoint,
            bucket,
            prefix,
            str(warmup),
            str(measured),
        ]
    if participant == "slatedb-rustfs":
        return [
            str(SLATEDB_EXECUTABLE),
            "s3",
            endpoint,
            bucket,
            access_key,
            secret_key,
            prefix,
            str(warmup),
            str(measured),
        ]
    raise RuntimeError(f"unknown participant {participant}")


def measure(
    participant: str,
    endpoint: str,
    bucket: str,
    access_key: str,
    secret_key: str,
    campaign_id: str,
    warmup: int,
    measured: int,
    repetitions: int,
    allow_reduced: bool,
) -> tuple[dict[str, str | None], list[dict[str, Any]], str]:
    environment = os.environ.copy()
    environment["AWS_ACCESS_KEY_ID"] = access_key
    environment["AWS_SECRET_ACCESS_KEY"] = secret_key
    preflight_prefix = f"{campaign_id}/{participant}/preflight"
    preflight = run(
        command(
            participant,
            endpoint,
            bucket,
            preflight_prefix,
            access_key,
            secret_key,
            0,
            1,
        ),
        environment=environment,
    )
    parse_output(preflight, 1)
    evidence = hashlib.sha256(preflight.encode()).hexdigest()

    power = power_profile(allow_reduced)
    checksum = state_checksum(warmup + measured)
    samples = []
    for repetition in range(1, repetitions + 1):
        prefix = f"{campaign_id}/{participant}/repetition-{repetition}"
        output = run(
            command(
                participant,
                endpoint,
                bucket,
                prefix,
                access_key,
                secret_key,
                warmup,
                measured,
            ),
            environment=environment,
        )
        elapsed = parse_output(output, warmup + measured)
        samples.append(
            {
                "repetition": repetition,
                "operations": measured,
                "bytes": measured * (KEY_BYTES + VALUE_BYTES),
                "elapsed_nanoseconds": elapsed,
                "errors": 0,
                "checksum": checksum,
            }
        )
    return power, samples, evidence


def metadata(
    participant: str,
    power: dict[str, str | None],
    samples: list[dict[str, Any]],
    evidence: str,
    rustfs_revision: str,
) -> dict[str, Any]:
    repository_head = run(["git", "rev-parse", "HEAD"]).strip()
    slatedb_head = run(["git", "-C", ".deps/slatedb", "rev-parse", "HEAD"]).strip()
    rates = [sample["operations"] * 1_000_000_000.0 / sample["elapsed_nanoseconds"] for sample in samples]
    common: dict[str, Any] = {
        "lane": "remote_durable_rustfs",
        "participant": participant,
        "storage_revision": rustfs_revision,
        "storage_configuration": {
            "provider": "RustFS",
            "endpoint": "loopback HTTP",
            "addressing": "path-style",
            "region": "us-east-1",
        },
        "correctness_gate": "benchmark close/reopen/read-every-key preflight on the same RustFS instance",
        "correctness_evidence": evidence,
        "power": power,
        "samples": samples,
        "median_operations_per_second": statistics.median(rates),
    }
    if participant == "flyology-db-rustfs":
        return common | {
            "engine_source": f"git:{repository_head}",
            "adapter_source": f"sha256:{sha256_file(HERE / 'src' / 'flyology_db_benchmark.adb')}",
            "compiler": run(
                ["alr", "exec", "--", "gnatls", "--version"], directory=HERE
            ).splitlines()[0],
            "build_flags": ["-O3", "-gnat2022", "-gnatW8", "-gnatw.e", "-gnatyM110"],
            "dependency_sources": {
                "flyology_db": repository_head,
                "flyology_object_storage": INDEXED_FOS_COMMIT,
                "flyology_object_storage_manifest": sha256_file(INDEXED_FOS / "alire.toml"),
                "flyology_alire_index": flyology_index_commit(),
            },
        }
    return common | {
        "engine_source": slatedb_head,
        "adapter_source": f"sha256:{sha256_file(HERE / 'slatedb' / 'src' / 'main.rs')}",
        "compiler": run(["rustc", "--version"]).strip(),
        "build_flags": ["cargo build --release --locked", "slatedb feature aws"],
        "dependency_sources": {
            "slatedb": slatedb_head,
            "cargo_lock": sha256_file(HERE / "slatedb" / "Cargo.lock"),
        },
    }


def main() -> int:
    if len(sys.argv) != 5:
        raise RuntimeError("usage: run_rustfs_campaign.py ENDPOINT BUCKET ACCESS_KEY SECRET_KEY")
    endpoint, bucket, access_key, secret_key = sys.argv[1:]
    if endpoint.startswith("http://host.docker.internal:"):
        endpoint = f"http://127.0.0.1:{endpoint.rsplit(':', 1)[1]}"
    if not endpoint.startswith("http://127.0.0.1:"):
        raise RuntimeError(f"unsupported benchmark endpoint {endpoint}")

    warmup = positive_environment("FLYOLOGY_DB_BENCHMARK_WARMUP", 5)
    measured = positive_environment("FLYOLOGY_DB_BENCHMARK_MEASURED", 30)
    repetitions = positive_environment("FLYOLOGY_DB_BENCHMARK_REPETITIONS", 5)
    if warmup + measured > MAXIMUM_OPERATIONS:
        raise RuntimeError("operation geometry exceeds the manifest-v1 history fixture")
    allow_reduced = os.environ.get("FLYOLOGY_DB_BENCHMARK_ALLOW_REDUCED") == "1"
    rustfs_revision = os.environ.get("FLYOLOGY_S3_SERVER_REVISION", "")
    if not rustfs_revision:
        raise RuntimeError("immutable RustFS revision is absent")

    run(
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
        ]
    )

    if os.environ.get("FLYOLOGY_DB_BENCHMARK_PREFLIGHT_ONLY") == "1":
        environment = os.environ.copy()
        environment["AWS_ACCESS_KEY_ID"] = access_key
        environment["AWS_SECRET_ACCESS_KEY"] = secret_key
        for participant in ("flyology-db-rustfs", "slatedb-rustfs"):
            participant_output = run(
                command(
                    participant,
                    endpoint,
                    bucket,
                    f"preflight-only/{participant}",
                    access_key,
                    secret_key,
                    0,
                    1,
                ),
                environment=environment,
            )
            parse_output(participant_output, 1)
        print("Flyology.DB RustFS benchmark participant preflight passed")
        return 0

    output = Path(os.environ["FLYOLOGY_DB_BENCHMARK_OUTPUT"])
    started = datetime.now(timezone.utc)
    campaign_id = started.strftime("remote-rustfs-%Y%m%dT%H%M%SZ")
    results = []
    campaign_power = None
    for participant in ("flyology-db-rustfs", "slatedb-rustfs"):
        power, samples, evidence = measure(
            participant,
            endpoint,
            bucket,
            access_key,
            secret_key,
            campaign_id,
            warmup,
            measured,
            repetitions,
            allow_reduced,
        )
        if campaign_power is None:
            campaign_power = power
        elif power != campaign_power:
            raise RuntimeError("participant power profiles do not match")
        results.append(metadata(participant, power, samples, evidence, rustfs_revision))

    workload_contract = json.loads((HERE / "workload.json").read_text())
    artifact = {
        "schema_version": "flyology.db.benchmark.result.v1",
        "contract_sha256": contract_digest(),
        "campaign": {
            "id": campaign_id,
            "classification": "directional",
            "started_at_utc": started.isoformat().replace("+00:00", "Z"),
        },
        "host": host_metadata(campaign_power),
        "workload": {
            "id": workload_contract["id"],
            "sha256": sha256_file(HERE / "workload.json"),
            "seed": workload_contract["seed"],
            "key_bytes": workload_contract["key_bytes"],
            "value_bytes": workload_contract["value_bytes"],
            "key_count": warmup + measured,
            "transaction_mutations": workload_contract["transaction_mutations"],
            "concurrency": workload_contract["concurrency"],
            "warmup_operations": warmup,
            "measured_operations": measured,
            "repetitions": repetitions,
        },
        "results": results,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(artifact, indent=2) + "\n")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
