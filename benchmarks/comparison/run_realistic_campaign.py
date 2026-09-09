#!/usr/bin/env python3
"""Collect one retained flyology_bench workload matrix."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
import tomllib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PANEL = HERE / "bin" / "flyology_db_benchmark_panel"
POWER_DETECTOR = (
    ROOT / ".agents" / "skills" / "performance-testing" / "scripts" / "check-power-profile.sh"
)
INDEXED_FOS = HERE / ".deps" / "flyology_object_storage_0.1.0_5eaf79cf"
INDEXED_FOS_COMMIT = "5eaf79cf12358c1402b5b7d7ed0a6ec74df6a628"
INDEXED_FOS_ORIGIN = "git+https://github.com/flyology-ada/flyology-object-storage.git"
SOURCE_TREE_DIGEST = HERE / "aws" / "source-tree-digest.py"

# These exact points are a benchmark fixture, not product limits. Each axis
# changes one factor from baseline; sustained-8960 repeats the largest batch
# across 35 durable transactions in one measured logical operation.
WORKLOADS = (
    {"id": "baseline", "key_bytes": 16, "value_bytes": 1024, "mutations": 1, "transactions": 1},
    {"id": "key-8", "key_bytes": 8, "value_bytes": 1024, "mutations": 1, "transactions": 1},
    {"id": "key-64", "key_bytes": 64, "value_bytes": 1024, "mutations": 1, "transactions": 1},
    {"id": "key-256", "key_bytes": 256, "value_bytes": 1024, "mutations": 1, "transactions": 1},
    {"id": "value-64", "key_bytes": 16, "value_bytes": 64, "mutations": 1, "transactions": 1},
    {"id": "value-16384", "key_bytes": 16, "value_bytes": 16384, "mutations": 1, "transactions": 1},
    {"id": "value-65536", "key_bytes": 16, "value_bytes": 65536, "mutations": 1, "transactions": 1},
    {"id": "batch-16", "key_bytes": 16, "value_bytes": 1024, "mutations": 16, "transactions": 1},
    {"id": "batch-64", "key_bytes": 16, "value_bytes": 1024, "mutations": 64, "transactions": 1},
    {"id": "batch-256", "key_bytes": 16, "value_bytes": 1024, "mutations": 256, "transactions": 1},
    {"id": "sustained-8960", "key_bytes": 16, "value_bytes": 1024, "mutations": 256, "transactions": 35},
)

LOCAL_PAIRS = (
    ("flyology-db-files", "tidesdb-full-sync"),
    ("flyology-db-files", "slatedb-default"),
    ("flyology-db-files", "slatedb-1ms"),
)
REMOTE_PAIRS = (
    ("flyology-db-rustfs", "slatedb-rustfs-default"),
    ("flyology-db-rustfs", "slatedb-rustfs-1ms"),
)
REMOTE_WORKLOADS = frozenset(("baseline", "value-16384", "batch-16", "sustained-8960"))
INDEPENDENT_COHORT_PREFIX = "flyology-db-files-independent-cohort-width"


def run(command: list[str], *, environment: dict[str, str] | None = None) -> str:
    completed = subprocess.run(
        command,
        cwd=HERE,
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


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def json_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def write_json_atomic(path: Path, value: Any) -> None:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as temporary:
        temporary.write(json.dumps(value, indent=2) + "\n")
        temporary_path = Path(temporary.name)
    temporary_path.replace(path)


def flyology_index_provenance() -> dict[str, str]:
    rows = run(["alr", "index"]).splitlines()
    matches = [row for row in rows if row.split()[1:2] == ["flyology"]]
    if len(matches) != 1:
        raise RuntimeError("configured Flyology Alire index is missing or ambiguous")
    index_path = Path(matches[0].split()[-1])
    status = run(["git", "-C", str(index_path), "status", "--short"]).strip()
    if status:
        raise RuntimeError("configured Flyology Alire index is dirty")
    entry = (
        index_path
        / "index"
        / "fl"
        / "flyology_object_storage"
        / "flyology_object_storage-0.1.0-dev.toml"
    )
    release = tomllib.loads(entry.read_text(encoding="utf-8"))
    origin = release.get("origin", {})
    if origin.get("commit") != INDEXED_FOS_COMMIT or origin.get("url") != INDEXED_FOS_ORIGIN:
        raise RuntimeError("Flyology index Object Storage origin does not match the benchmark pin")
    return {
        "flyology_alire_index_commit": run(
            ["git", "-C", str(index_path), "rev-parse", "HEAD"]
        ).strip(),
        "object_storage_index_entry_sha256": sha256(entry),
        "object_storage_commit": origin["commit"],
        "object_storage_origin": origin["url"],
    }


def power_profile() -> dict[str, str | None]:
    completed = subprocess.run(
        [str(POWER_DETECTOR)],
        cwd=HERE,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    allow_reduced = os.environ.get("FLYOLOGY_DB_BENCHMARK_ALLOW_REDUCED") == "1"
    accepted = (0, 2, 10) if allow_reduced else (0, 2)
    if completed.returncode not in accepted:
        raise RuntimeError(
            f"power detector exited {completed.returncode}:\n{completed.stdout}"
        )
    output = completed.stdout
    fields: dict[str, str | None] = {}
    for line in output.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = None if value == "unknown" else value
    required = {"os", "detector", "profile", "power_source"}
    if not required <= fields.keys():
        raise RuntimeError(f"power detector output is incomplete:\n{output}")
    result = {key: fields[key] for key in sorted(required)}
    result["detector_exit_status"] = str(completed.returncode)
    return result


def host(power: dict[str, str | None]) -> dict[str, Any]:
    if platform.system() == "Darwin":
        cpu = run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        memory_bytes = int(run(["sysctl", "-n", "hw.memsize"]).strip())
    elif platform.system() == "Linux":
        cpu_rows = {
            row["data"].strip()
            for row in json.loads(run(["lscpu", "--json"]))["lscpu"]
            if row.get("field", "").rstrip(":") == "Model name"
            and isinstance(row.get("data"), str)
            and row["data"].strip()
        }
        if len(cpu_rows) != 1:
            raise RuntimeError("Linux CPU model is missing or ambiguous")
        cpu = cpu_rows.pop()
        memory_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    else:
        raise RuntimeError(f"unsupported benchmark host {platform.system()}")
    return {
        "os": platform.platform(),
        "architecture": platform.machine(),
        "cpu": cpu,
        "memory_bytes": memory_bytes,
        "power": power,
    }


def provenance() -> dict[str, Any]:
    index = flyology_index_provenance()
    return {
        "repository_commit": run(["git", "rev-parse", "HEAD"]).strip(),
        "repository_diff_sha256": hashlib.sha256(
            run(["git", "diff", "--binary", "HEAD", "--"]).encode()
        ).hexdigest(),
        "flyology_bench_version": "0.1.1-dev",
        "flyology_bench_commit": "bd95746d5c9c31f5b41b611db9ba82a016ceaaa4",
        "flyology_bench_lock_sha256": sha256(HERE / "alire" / "alire.lock"),
        "flyology_db_adapter_spec_sha256": sha256(
            HERE / "src" / "flyology_db_benchmark_flyology.ads"
        ),
        "flyology_db_adapter_body_sha256": sha256(
            HERE / "src" / "flyology_db_benchmark_flyology.adb"
        ),
        "panel_adapter_sha256": sha256(HERE / "src" / "flyology_db_benchmark_panel.adb"),
        "panel_executable_sha256": sha256(PANEL),
        "campaign_driver_sha256": sha256(Path(__file__)),
        "slatedb_adapter_sha256": sha256(HERE / "slatedb" / "src" / "lib.rs"),
        "slatedb_lock_sha256": sha256(HERE / "slatedb" / "Cargo.lock"),
        "tidesdb_adapter_spec_sha256": sha256(
            HERE / "src" / "flyology_db_benchmark_tidesdb.ads"
        ),
        "tidesdb_adapter_body_sha256": sha256(
            HERE / "src" / "flyology_db_benchmark_tidesdb.adb"
        ),
        "slatedb_commit": run(["git", "-C", str(ROOT / ".deps" / "slatedb"), "rev-parse", "HEAD"]).strip(),
        "tidesdb_commit": run(["git", "-C", str(ROOT / ".deps" / "tidesdb"), "rev-parse", "HEAD"]).strip(),
        **index,
        "object_storage_manifest_sha256": sha256(INDEXED_FOS / "alire.toml"),
        "object_storage_source_sha256": run(
            [sys.executable, str(SOURCE_TREE_DIGEST), str(INDEXED_FOS)]
        ).strip(),
    }


def method() -> dict[str, Any]:
    return {
        "framework": "flyology_bench 0.1.1-dev",
        "samples": 10,
        "bootstrap_resamples": 2000,
        "confidence_percent": 95,
        "cpu_quiescence": {
            "maximum_average_percent": 25,
            "maximum_core_percent": 60,
            "stable_seconds": 2,
            "timeout_seconds": 300,
        },
        "timed_region": "begin, all puts, durable commit outcome",
        "verification": (
            "close, reopen, byte-compare every key, participant SHA-256, harness SHA-256"
        ),
        "comparison_batching": "shared logical iteration count with balanced pair order",
        "resumption": (
            "Each pair is sealed immediately with its request, collection-time identity, and raw hashes. "
            "A resumed campaign accepts only byte-identical sealed pairs under the same campaign identity."
        ),
        "in_process_adapter_note": (
            "Each batch uses an in-process engine adapter and a fresh database. Setup, close, reopen, and "
            "verification are visible as harness wall time but excluded from primary_time."
        ),
    }


def campaign_identity(
    lane: str,
    pairs: tuple[tuple[str, str], ...],
    workloads: tuple[dict[str, Any], ...],
    power: dict[str, str | None],
) -> dict[str, Any]:
    return {
        "lane": lane,
        "host": host(power),
        "power": power,
        "method": method(),
        "provenance": provenance(),
        "remote_server": {
            "implementation": os.environ.get("FLYOLOGY_S3_IMPLEMENTATION"),
            "revision": os.environ.get("FLYOLOGY_S3_SERVER_REVISION"),
            "transport": "loopback-http" if lane == "rustfs" else None,
        },
        "plan": {
            "pairs": [list(pair) for pair in pairs],
            "workloads": list(workloads),
        },
    }


def load_or_create_campaign(
    raw: Path,
    lane: str,
    pairs: tuple[tuple[str, str], ...],
    workloads: tuple[dict[str, Any], ...],
    resume: bool,
) -> dict[str, Any]:
    path = raw / "campaign.json"
    observed_identity = campaign_identity(
        lane, pairs, workloads, power_profile()
    )
    observed_digest = json_sha256(observed_identity)
    if resume:
        retained = json.loads(path.read_text(encoding="utf-8"))
        if (
            retained.get("schema_version") != "flyology.db.benchmark.campaign.v1"
            or retained.get("identity_sha256") != observed_digest
            or retained.get("identity") != observed_identity
        ):
            raise RuntimeError("retained campaign identity no longer matches the executable tree")
        return retained
    campaign = {
        "schema_version": "flyology.db.benchmark.campaign.v1",
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "identity_sha256": observed_digest,
        "identity": observed_identity,
    }
    write_json_atomic(path, campaign)
    return campaign


def load_pair(
    json_path: Path,
    metrics_path: Path,
    reference: str,
    contender: str,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Load one complete pair, rejecting partial or mismatched retained data."""
    comparison = json.loads(json_path.read_text(encoding="utf-8"))
    metrics = [
        json.loads(line)
        for line in metrics_path.read_text(encoding="utf-8").splitlines()
        if line
    ]
    if (
        comparison.get("type") != "comparison"
        or comparison.get("reference") != reference
        or comparison.get("contender") != contender
        or comparison.get("samples") != 10
    ):
        raise RuntimeError(f"retained comparison has the wrong identity: {json_path}")
    primary = [
        metric
        for metric in metrics
        if metric.get("kind") == "custom"
        and metric.get("axis") == "primary_time"
        and metric.get("reference") == reference
        and metric.get("contender") == contender
    ]
    if (
        len(primary) != 1
        or primary[0].get("available") is not True
        or primary[0].get("status") != "collected"
        or primary[0].get("timing_source") != "engine_adapter_monotonic_clock"
        or not isinstance(primary[0].get("reference_median"), (int, float))
        or not isinstance(primary[0].get("contender_median"), (int, float))
        or primary[0]["reference_median"] <= 0
        or primary[0]["contender_median"] <= 0
    ):
        raise RuntimeError(f"retained primary metric is incomplete: {metrics_path}")
    flyology_participants = {
        participant
        for participant in (reference, contender)
        if participant.startswith("flyology-db-")
    }
    configurations = [
        metric
        for metric in metrics
        if metric.get("kind") == "flyology_db_execution_configuration"
    ]
    if not configurations or {
        configuration.get("participant") for configuration in configurations
    } != flyology_participants:
        raise RuntimeError(f"retained Flyology configuration is incomplete: {metrics_path}")
    configuration_by_execution: dict[tuple[str, int], dict[str, Any]] = {}
    configuration_ordinals: set[int] = set()
    for configuration in configurations:
        participant = configuration["participant"]
        execution_profile = participant.removesuffix("-waves").removesuffix("-diagnostics")
        independent_cohort_width = 0
        if execution_profile.startswith(INDEPENDENT_COHORT_PREFIX):
            width_text = execution_profile.removeprefix(INDEPENDENT_COHORT_PREFIX)
            if not width_text.isascii() or not width_text.isdigit():
                raise RuntimeError(
                    f"retained independent cohort width is malformed: {metrics_path}"
                )
            independent_cohort_width = int(width_text)
            #  The maintained panel profile parser admits canonical widths 1 through 8.
            if (
                independent_cohort_width <= 0
                or independent_cohort_width > 8
                or str(independent_cohort_width) != width_text
            ):
                raise RuntimeError(
                    f"retained independent cohort width is not canonical: {metrics_path}"
                )
        counts_are_valid = (
            type(configuration.get("transactions")) is int
            and configuration["transactions"] > 0
            and type(configuration.get("batch_publications")) is int
            and configuration["batch_publications"] > 0
            and type(configuration.get("manifest_publications")) is int
            and configuration["manifest_publications"] == 0
            and type(configuration.get("head_publications")) is int
        )
        publication_geometry_is_valid = False
        if counts_are_valid:
            if independent_cohort_width > 0:
                publication_geometry_is_valid = (
                    configuration["batch_publications"] == configuration["transactions"]
                    and configuration["transactions"] % independent_cohort_width == 0
                    and configuration["head_publications"]
                    == configuration["transactions"] // independent_cohort_width
                )
            else:
                publication_geometry_is_valid = (
                    configuration["head_publications"]
                    == configuration["batch_publications"]
                )
        if (
            configuration.get("schema")
            != "flyology.db.benchmark.execution_configuration.v1"
            or type(configuration.get("execution_ordinal")) is not int
            or configuration["execution_ordinal"] <= 0
            or not publication_geometry_is_valid
        ):
            raise RuntimeError(
                f"retained Flyology configuration disagrees with its participant: {metrics_path}"
            )
        key = (participant, configuration["execution_ordinal"])
        if key in configuration_by_execution or configuration["execution_ordinal"] in configuration_ordinals:
            raise RuntimeError(f"retained Flyology configuration is duplicated: {metrics_path}")
        configuration_by_execution[key] = configuration
        configuration_ordinals.add(configuration["execution_ordinal"])
    paired = [
        metric
        for metric in metrics
        if metric.get("schema") == "flyology.db.benchmark.paired_primary_sample.v1"
    ]
    if len(paired) != comparison["samples"]:
        raise RuntimeError(f"retained paired samples are incomplete: {metrics_path}")
    measured_configurations: set[tuple[str, int]] = set()
    for sample in paired:
        if (
            sample.get("reference") != reference
            or sample.get("contender") != contender
            or type(sample.get("transactions_per_operation")) is not int
            or sample["transactions_per_operation"] <= 0
        ):
            raise RuntimeError(f"retained paired sample identity is invalid: {metrics_path}")
        sample_configurations: dict[str, dict[str, Any]] = {}
        for side, participant in (("reference", reference), ("contender", contender)):
            if participant not in flyology_participants:
                continue
            ordinal_value = sample.get(f"{side}_execution_ordinal")
            iterations = sample.get(f"{side}_iterations")
            if (
                isinstance(ordinal_value, bool)
                or not isinstance(ordinal_value, (int, float))
                or ordinal_value <= 0
                or int(ordinal_value) != ordinal_value
                or type(iterations) is not int
                or iterations <= 0
            ):
                raise RuntimeError(f"retained paired sample geometry is invalid: {metrics_path}")
            key = (participant, int(ordinal_value))
            if key in measured_configurations or key not in configuration_by_execution:
                raise RuntimeError(
                    f"retained paired sample has missing or reused Flyology configuration: {metrics_path}"
                )
            if configuration_by_execution[key]["transactions"] != (
                iterations * sample["transactions_per_operation"]
            ):
                raise RuntimeError(
                    f"retained Flyology configuration has the wrong transaction count: {metrics_path}"
                )
            measured_configurations.add(key)
            sample_configurations[side] = configuration_by_execution[key]
    return comparison, metrics


def pair_request(
    campaign: dict[str, Any],
    identity: str,
    workload: dict[str, Any],
    reference: str,
    contender: str,
    json_path: Path,
    metrics_path: Path,
) -> dict[str, Any]:
    return {
        "schema_version": "flyology.db.benchmark.pair-request.v1",
        "campaign_identity_sha256": campaign["identity_sha256"],
        "identity": identity,
        "workload": workload,
        "reference": reference,
        "contender": contender,
        "power": campaign["identity"]["power"],
        "environment": {
            "FLYOLOGY_DB_BENCH_NAMESPACE": identity,
        },
        "command_argv": [
            str(PANEL),
            reference,
            contender,
            str(workload["key_bytes"]),
            str(workload["value_bytes"]),
            str(workload["mutations"]),
            str(workload["transactions"]),
            str(json_path),
            str(metrics_path),
        ],
    }


def collect(lane: str, output: Path, resume: bool) -> None:
    pairs = LOCAL_PAIRS if lane == "local" else REMOTE_PAIRS
    workloads = WORKLOADS if lane == "local" else tuple(
        workload for workload in WORKLOADS if workload["id"] in REMOTE_WORKLOADS
    )
    raw = output.parent / f"{output.stem}-raw"
    raw.mkdir(parents=True, exist_ok=resume)
    campaign = load_or_create_campaign(raw, lane, pairs, workloads, resume)
    records: list[dict[str, Any]] = []
    environment = os.environ.copy()

    for workload in workloads:
        for reference, contender in pairs:
            pair_power = power_profile()
            if pair_power != campaign["identity"]["power"]:
                raise RuntimeError(
                    "power profile changed during campaign: "
                    f"{campaign['identity']['power']!r} -> {pair_power!r}"
                )
            identity = f"{lane}--{workload['id']}--{reference}--{contender}"
            json_path = raw / f"{identity}.json"
            metrics_path = raw / f"{identity}.metrics.ndjson"
            request_path = raw / f"{identity}.request.json"
            seal_path = raw / f"{identity}.seal.json"
            expected_request = pair_request(
                campaign,
                identity,
                workload,
                reference,
                contender,
                json_path,
                metrics_path,
            )
            if seal_path.exists():
                if not (request_path.is_file() and json_path.is_file() and metrics_path.is_file()):
                    raise RuntimeError(f"sealed pair is incomplete: {identity}")
                retained_request = json.loads(request_path.read_text(encoding="utf-8"))
                if retained_request != expected_request:
                    raise RuntimeError(f"sealed request identity changed: {identity}")
                retained_seal = json.loads(seal_path.read_text(encoding="utf-8"))
                if (
                    retained_seal.get("schema_version")
                    != "flyology.db.benchmark.pair-seal.v1"
                    or retained_seal.get("request_sha256") != sha256(request_path)
                    or retained_seal.get("comparison_sha256") != sha256(json_path)
                    or retained_seal.get("metrics_sha256") != sha256(metrics_path)
                ):
                    raise RuntimeError(f"sealed pair hash mismatch: {identity}")
                print(f"retaining sealed {identity}", flush=True)
            else:
                if json_path.exists() or metrics_path.exists():
                    raise RuntimeError(f"unsealed pair output must not be resumed: {identity}")
                if request_path.exists():
                    retained_request = json.loads(request_path.read_text(encoding="utf-8"))
                    if retained_request != expected_request:
                        raise RuntimeError(f"pending request identity changed: {identity}")
                else:
                    write_json_atomic(request_path, expected_request)
                print(f"collecting {identity}", flush=True)
                pair_environment = environment.copy()
                pair_environment.update(expected_request["environment"])
                run(expected_request["command_argv"], environment=pair_environment)
                comparison, metrics = load_pair(
                    json_path, metrics_path, reference, contender
                )
                write_json_atomic(
                    seal_path,
                    {
                        "schema_version": "flyology.db.benchmark.pair-seal.v1",
                        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
                        "request_sha256": sha256(request_path),
                        "comparison_sha256": sha256(json_path),
                        "metrics_sha256": sha256(metrics_path),
                        "primary_metric_sha256": json_sha256(
                            next(
                                metric
                                for metric in metrics
                                if metric.get("kind") == "custom"
                                and metric.get("axis") == "primary_time"
                            )
                        ),
                    },
                )
            comparison, metrics = load_pair(
                json_path, metrics_path, reference, contender
            )
            records.append(
                {
                    "lane": lane,
                    "workload": workload,
                    "reference": reference,
                    "contender": contender,
                    "power": pair_power,
                    "comparison": comparison,
                    "metrics": metrics,
                    "request_sha256": sha256(request_path),
                    "seal_sha256": sha256(seal_path),
                    "raw": {
                        "comparison": json_path.name,
                        "comparison_sha256": sha256(json_path),
                        "metrics": metrics_path.name,
                        "metrics_sha256": sha256(metrics_path),
                    },
                }
            )

    detector_status = campaign["identity"]["host"]["power"]["detector_exit_status"]
    classification = "exploratory" if detector_status == "2" else "directional"
    artifact = {
        "schema_version": "flyology.db.benchmark.matrix.v3",
        "classification": classification,
        "campaign_created_at_utc": campaign["created_at_utc"],
        "assembled_at_utc": datetime.now(timezone.utc).isoformat(),
        "lane": lane,
        "campaign_identity_sha256": campaign["identity_sha256"],
        "host": campaign["identity"]["host"],
        "method": campaign["identity"]["method"],
        "provenance": campaign["identity"]["provenance"],
        "records": records,
    }
    write_json_atomic(output, artifact)
    print(f"wrote {output} sha256={sha256(output)}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lane", choices=("local", "rustfs"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resume", action="store_true")
    arguments = parser.parse_args()
    output = arguments.output.resolve()
    raw = output.parent / f"{output.stem}-raw"
    if output.exists() or (raw.exists() and not arguments.resume):
        parser.error("output must be absent; raw directory requires --resume")
    if arguments.resume and not (raw / "campaign.json").is_file():
        parser.error("--resume requires a sealed campaign directory")
    collect(arguments.lane, output, arguments.resume)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
