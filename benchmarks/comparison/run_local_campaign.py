#!/usr/bin/env python3
"""Run and retain one capability-matched local-durability campaign."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PANEL = HERE / "panel.json"
WORKLOAD = HERE / "workload.json"
SCHEMA = HERE / "result.schema.json"
INDEXED_FOS = HERE / ".deps" / "flyology_object_storage_0.1.0_5eaf79cf"
INDEXED_FOS_COMMIT = "5eaf79cf12358c1402b5b7d7ed0a6ec74df6a628"
POWER_DETECTOR = ROOT / ".agents" / "skills" / "performance-testing" / "scripts" / "check-power-profile.sh"
FLYOLOGY_EXECUTABLE = HERE / "bin" / "flyology_db_benchmark"
SLATEDB_EXECUTABLE = HERE / "slatedb" / "target" / "release" / "flyology-db-slatedb-benchmark"
TIDESDB_BENCHMARK = HERE / "tidesdb_benchmark.py"
TIDESDB_LIBRARY = ROOT / "oracles" / "adapters" / "tidesdb" / "build" / "libflyology_tidesdb_oracle.dylib"
KEY_BYTES = 16
VALUE_BYTES = 1024
MAXIMUM_OPERATIONS = 63


def run(
    command: list[str],
    *,
    environment: dict[str, str] | None = None,
    directory: Path = ROOT,
) -> str:
    completed = subprocess.run(
        command,
        cwd=directory,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"command exited {completed.returncode}: {' '.join(command)}\n{completed.stdout}"
        )
    return completed.stdout


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def contract_digest() -> str:
    digest = hashlib.sha256()
    for path in (PANEL, WORKLOAD, SCHEMA):
        digest.update(path.name.encode("ascii"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def flyology_index_commit() -> str:
    rows = run(["alr", "index"], directory=HERE).splitlines()
    matches = [row for row in rows if row.split()[1:2] == ["flyology"]]
    if len(matches) != 1:
        raise RuntimeError("configured Flyology Alire index is missing or ambiguous")
    index_path = Path(matches[0].split()[-1])
    status = run(["git", "-C", str(index_path), "status", "--short"]).strip()
    if status:
        raise RuntimeError("configured Flyology Alire index is dirty")
    return run(["git", "-C", str(index_path), "rev-parse", "HEAD"]).strip()


def state_checksum(total: int) -> str:
    digest = hashlib.sha256()
    for index in range(1, total + 1):
        digest.update(index.to_bytes(KEY_BYTES, "big"))
        digest.update(
            bytes((index + position * 31) % 256 for position in range(1, VALUE_BYTES + 1))
        )
    return digest.hexdigest()


def parse_output(output: str, expected_keys: int) -> int:
    values: dict[str, str] = {}
    for line in output.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key in values:
                raise RuntimeError(f"duplicate participant output field {key}")
            values[key] = value.strip()
    if set(values) != {"elapsed_nanoseconds", "verified_keys"}:
        raise RuntimeError(f"unexpected participant output:\n{output}")
    if int(values["verified_keys"]) != expected_keys:
        raise RuntimeError("participant verified the wrong key count")
    elapsed = int(values["elapsed_nanoseconds"])
    if elapsed <= 0:
        raise RuntimeError("participant reported a nonpositive elapsed time")
    return elapsed


def power_profile(allow_reduced: bool) -> dict[str, str | None]:
    completed = subprocess.run(
        [str(POWER_DETECTOR)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode not in ({0, 10} if allow_reduced else {0}):
        raise RuntimeError(
            f"power-profile detector exited {completed.returncode}:\n{completed.stdout}"
        )
    fields: dict[str, str | None] = {}
    for line in completed.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = None if value == "unknown" else value
    required = {"os", "detector", "profile", "power_source"}
    if not required <= fields.keys():
        raise RuntimeError(f"power-profile detector output is incomplete:\n{completed.stdout}")
    return {key: fields[key] for key in required}


def participant_command(participant: str, root: Path, warmup: int, measured: int) -> list[str]:
    if participant == "flyology-db-files":
        return [str(FLYOLOGY_EXECUTABLE), "local", str(root), str(warmup), str(measured)]
    if participant == "slatedb-local-fsync":
        return [str(SLATEDB_EXECUTABLE), "local", str(root), "database", str(warmup), str(measured)]
    if participant == "tidesdb-unified-full-sync":
        return [
            sys.executable,
            str(TIDESDB_BENCHMARK),
            "--library",
            str(TIDESDB_LIBRARY),
            "--root",
            str(root),
            "--warmup",
            str(warmup),
            "--measured",
            str(measured),
        ]
    raise RuntimeError(f"unknown participant {participant}")


def measure(
    participant: str,
    warmup: int,
    measured: int,
    repetitions: int,
    allow_reduced: bool,
) -> tuple[dict[str, str | None], list[dict[str, Any]], str]:
    with tempfile.TemporaryDirectory(prefix=f"flyology-db-{participant}-preflight.") as directory:
        output = run(participant_command(participant, Path(directory) / "database", 0, 1))
        parse_output(output, 1)
        correctness_evidence = sha256_bytes(output.encode())

    power = power_profile(allow_reduced)
    checksum = state_checksum(warmup + measured)
    samples = []
    for repetition in range(1, repetitions + 1):
        with tempfile.TemporaryDirectory(prefix=f"flyology-db-{participant}-{repetition}.") as directory:
            output = run(
                participant_command(
                    participant,
                    Path(directory) / "database",
                    warmup,
                    measured,
                )
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
    return power, samples, correctness_evidence


def metadata(
    participant: str,
    power: dict[str, str | None],
    samples: list[dict[str, Any]],
    evidence: str,
) -> dict[str, Any]:
    repository_head = run(["git", "rev-parse", "HEAD"]).strip()
    rates = [sample["operations"] * 1_000_000_000.0 / sample["elapsed_nanoseconds"] for sample in samples]
    common: dict[str, Any] = {
        "lane": "local_durable",
        "participant": participant,
        "power": power,
        "samples": samples,
        "median_operations_per_second": statistics.median(rates),
        "correctness_evidence": evidence,
    }
    if participant == "flyology-db-files":
        return common | {
            "engine_source": f"git:{repository_head}",
            "adapter_source": f"sha256:{sha256_file(HERE / 'src' / 'flyology_db_benchmark.adb')}",
            "compiler": run(
                ["alr", "exec", "--", "gnatls", "--version"], directory=HERE
            ).splitlines()[0],
            "build_flags": ["-O3", "-gnat2022", "-gnatW8", "-gnatw.e", "-gnatyM110"],
            "storage_revision": "Flyology Object Storage Files at the pinned Alire dependency source",
            "storage_configuration": {
                "backend": "Files",
                "commit_policy": "Power_Loss_Durable",
            },
            "correctness_gate": "benchmark close/reopen/read-every-key preflight",
            "dependency_sources": {
                "flyology_db": repository_head,
                "flyology_object_storage": INDEXED_FOS_COMMIT,
                "flyology_object_storage_manifest": sha256_file(INDEXED_FOS / "alire.toml"),
                "flyology_alire_index": flyology_index_commit(),
            },
        }
    if participant == "slatedb-local-fsync":
        return common | {
            "engine_source": run(["git", "-C", ".deps/slatedb", "rev-parse", "HEAD"]).strip(),
            "adapter_source": f"sha256:{sha256_file(HERE / 'slatedb' / 'src' / 'main.rs')}",
            "compiler": run(["rustc", "--version"]).strip(),
            "build_flags": ["cargo build --release --locked"],
            "storage_revision": "object_store 0.14.0",
            "storage_configuration": {
                "backend": "LocalFileSystem",
                "fsync": "true",
                "wal_enabled": "true",
                "durability_wait": "WriteHandle.await_durable",
            },
            "correctness_gate": "benchmark close/reopen/read-every-key preflight",
            "dependency_sources": {
                "slatedb": run(["git", "-C", ".deps/slatedb", "rev-parse", "HEAD"]).strip(),
                "cargo_lock": sha256_file(HERE / "slatedb" / "Cargo.lock"),
            },
        }
    return common | {
        "engine_source": run(["git", "-C", ".deps/tidesdb", "rev-parse", "HEAD"]).strip(),
        "adapter_source": f"sha256:{sha256_file(TIDESDB_BENCHMARK)}",
        "compiler": f"{run(['cc', '--version']).splitlines()[0]}; Python {platform.python_version()}",
        "build_flags": ["CMAKE_BUILD_TYPE=Release", "TIDESDB_WITH_S3=OFF", "ctypes direct API"],
        "storage_revision": "TidesDB 23a67a6531bc6c0b537d3696758c7879586dcfce",
        "storage_configuration": {
            "memtable": "unified",
            "unified_wal_sync": "TDB_SYNC_FULL",
            "column_family_sync": "TDB_SYNC_FULL",
            "compression": "none",
        },
        "correctness_gate": "benchmark close/reopen/read-every-key preflight",
        "dependency_sources": {
            "tidesdb": run(["git", "-C", ".deps/tidesdb", "rev-parse", "HEAD"]).strip(),
            "oracle_shim": sha256_file(ROOT / "oracles" / "adapters" / "tidesdb" / "oracle_shim.c"),
        },
    }


def host_metadata(power: dict[str, str | None]) -> dict[str, Any]:
    cpu = run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
    memory = int(run(["sysctl", "-n", "hw.memsize"]).strip())
    return {
        "os": platform.platform(),
        "architecture": platform.machine(),
        "cpu": cpu,
        "memory_bytes": memory,
        "power": power,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--measured", type=int, default=30)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--allow-reduced-performance", action="store_true")
    arguments = parser.parse_args()
    if arguments.warmup < 0 or arguments.measured <= 0 or arguments.repetitions <= 0:
        parser.error("operation geometry must be nonnegative/positive")
    if arguments.warmup + arguments.measured > MAXIMUM_OPERATIONS:
        parser.error("operation geometry exceeds the manifest-v1 history fixture")

    participants = [
        "flyology-db-files",
        "slatedb-local-fsync",
        "tidesdb-unified-full-sync",
    ]
    started = datetime.now(timezone.utc)
    results = []
    campaign_power = None
    for participant in participants:
        power, samples, evidence = measure(
            participant,
            arguments.warmup,
            arguments.measured,
            arguments.repetitions,
            arguments.allow_reduced_performance,
        )
        if campaign_power is None:
            campaign_power = power
        elif power != campaign_power:
            raise RuntimeError("participant power profiles do not match")
        results.append(metadata(participant, power, samples, evidence))

    workload_contract = json.loads(WORKLOAD.read_text())
    artifact = {
        "schema_version": "flyology.db.benchmark.result.v1",
        "contract_sha256": contract_digest(),
        "campaign": {
            "id": started.strftime("local-durable-%Y%m%dT%H%M%SZ"),
            "classification": "directional",
            "started_at_utc": started.isoformat().replace("+00:00", "Z"),
        },
        "host": host_metadata(campaign_power),
        "workload": {
            "id": workload_contract["id"],
            "sha256": sha256_file(WORKLOAD),
            "seed": workload_contract["seed"],
            "key_bytes": workload_contract["key_bytes"],
            "value_bytes": workload_contract["value_bytes"],
            "key_count": arguments.warmup + arguments.measured,
            "transaction_mutations": workload_contract["transaction_mutations"],
            "concurrency": workload_contract["concurrency"],
            "warmup_operations": arguments.warmup,
            "measured_operations": arguments.measured,
            "repetitions": arguments.repetitions,
        },
        "results": results,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(artifact, indent=2) + "\n")
    print(arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
