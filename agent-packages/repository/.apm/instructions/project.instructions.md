---
description: Flyology.DB repository architecture, ownership, format, and qualification rules.
---

# Flyology.DB agent guide

This guide specializes the parent Flyology rules for the experimental `flyology_db` crate and the public
`Flyology.DB` Ada namespace. `README.md` describes the user-facing architecture; executable runners are
authoritative for verification.

## Before changing anything

- Run `git status --short --branch` and preserve unrelated work.
- Read the relevant architecture, format, compatibility, and qualification documents plus the implementation.
- Read a sibling repository's own `AGENTS.md` before adopting one of its patterns.
- Use `rg` and `rg --files` for discovery and `apply_patch` for hand edits.
- Keep handwritten Ada to 110 columns. Run `gnatformat -P flyology_db.gpr` on changed Ada sources.
- Run `gh` outside the sandbox. Repository: `flyology-ada/flyology-db`.
- Keep changes focused. Use one Problem/Solution commit for one reviewable semantic unit.

## Product and semantic invariants

- Flyology.DB is experimental. Make no production, portability, real-time, durability, or performance claim
  without a reproducible gate and retained evidence.
- Object storage is the sole authority for acknowledged durable state. Memory, local files, and caches are
  disposable accelerators.
- A durable transaction requires a complete immutable commit object, a successful conditional `meta/HEAD`
  transition from its exact predecessor generation, and confirmation or reconciliation of publication.
- Listing is for discovery and garbage collection only. It never establishes visibility or normal recovery.
- Commit batches, manifests, SSTs, snapshots, and compaction outputs are immutable. Only small metadata heads
  are conditionally replaced.
- One fenced writer, one global commit sequence, one database-wide transaction log, stable never-reused column
  family IDs, and any number of read-only replicas are the initial topology.
- A stale writer must stop when its expected head generation or writer epoch is no longer current.
- An unknown publication outcome remains unknown until the attempted transition ID or a conclusive successor is
  observed. Never replay an application transaction under a new idempotency identity.
- Publication ordering must prevent unreachable or partially published transaction data from becoming visible.
- Snapshot isolation rejects post-snapshot write/write conflicts. Serializable mode also rejects post-snapshot
  writes intersecting recorded point reads or normalized scan ranges.
- Keys and values are arbitrary bytes. Clocks governing TTL and workload semantics are injected; deadlines use a
  monotonic clock.
- Every queue, mutation set, read set, scan range set, cache, in-flight request set, task set, and byte budget is
  explicitly bounded and applies backpressure at capacity.
- DB allocations may be sized dynamically from persisted `Database_Limits` and per-column-family limits. Use
  checked arithmetic and lazy allocation, classify allocation failure safely, and publish no partial state.
- Synchronous convenience calls and caller-composable operations use the same state machines and certainty
  rules. Do not document them as different semantic paths.
- Maintenance is explicit: callers choose `Flush` and `Compact`. The current profile has no automatic
  compaction, garbage collection, cleanup, retention, or retry policy.
- Installed column-family configuration is read-only. The current API has no family rename, drop,
  reconfiguration, migration, TTL, or codec-policy operation.
- Replica refresh is caller-triggered. It is not registration, polling, leasing, retention coordination, or
  automatic promotion.
- Keep Files and S3-compatible provider evidence within the exact maintained matrix. Compatible-provider
  evidence is not general cloud or production qualification.
- Durable Commit authority is a bearer blob containing application keys and values. Its CRC detects corruption,
  not substitution, so it requires authenticated confidential storage and higher-level request binding. This
  authority begins only after `Commit` returns `Outcome_Unknown`; it does not cover termination inside
  `Commit` or another receipt family.

## Persisted formats

- Encode integers and byte sequences explicitly; never persist native addresses, Ada access values, unchecked
  record images, enumeration positions, padding, or compiler-dependent layout.
- Every object carries magic, format version, object kind, database UUID, exact lengths, and integrity data.
- Decoders fail closed on unknown versions, wrong database identity or kind, malformed lengths, overflow,
  invalid ordering, trailing bytes, and checksum failure.
- ETags and provider versions are opaque generations, not content checksums.
- Format changes require a documented compatibility decision, golden byte fixtures, corruption tests, and SPARK
  proof for deterministic bounds and transition policy where applicable.

## Object Storage dependency

- The author checkout `../flyology-object-storage` is read-only coordination state, never a build dependency.
- Build through the ignored clean clone `.deps/flyology-object-storage` and the root Alire filesystem path pin.
- Record the exact dependency commit in verification and benchmark artifacts.
- Update the clone only by fast-forward from its local origin, between campaigns and never during a deterministic
  test, proof, or benchmark run. If it becomes dirty, diagnose it; do not reset or discard it.
- Do not edit the clone as a workaround and do not path-pin its indexed `flyology_http` dependency.
- Request missing atomic storage semantics from the Object Storage author with exact outcomes and conformance
  tests. Keep S3, HTTP, SigV4, retries, and provider policy out of Flyology.DB.

## Ada, execution, and ownership

- Preserve ordinary synchronous Ada semantics. A lightweight call may suspend only its task; a native call may
  block its pthread.
- Use Flyology scoped operations, bounded completion sets, channels, and unique buffers for sustained object I/O.
  Do not create one helper task per transaction, object, or block.
- Keep sustained sort, compression, and merge work off shared event-loop pthreads through bounded native offload.
- Public ownership uses limited controlled types where needed. Join internal tasks and classify every admitted
  operation during close, cancellation, abort, and finalization.
- Ada owns policy, validation, retries, state machines, cleanup, formats, and scheduling. Native C is permitted only
  for an unavoidable narrow ABI mechanism with focused ABI tests and review.
- Only `Flyology.DB` and deliberate application children are public API. Persisted formats, transition policy,
  reference models, provider adapters, and test hooks are private descendants.
- Public specifications use GNATdoc leading comments with exact tag names and no blank line before declarations.

## Repository map

- `src/`: public and internal Ada packages.
- `tests/`: nested test crate, fixtures, fault cases, recovery cases, and authoritative runner.
- `proof/`: development-only GNATprove crate and project.
- `docs/architecture/`: normative formats, protocols, ownership, recovery, and execution.
- `docs/qualification/`: dependency, proof, durability, review, and performance evidence.
- `docs/compatibility/`: object provider and comparative-engine capability matrices.
- `oracles/`: normative workload contract, reference model, adapters, histories, and minimized regressions.
- `benchmarks/`: deterministic campaigns and machine-readable artifact contracts.
- `showcases/`: small reproducible demonstrations.
- `tools/`: inspectors, generators, trace minimizers, and validation utilities.
- `scripts/`: repository-wide entry points. Generated `alire/`, `config/`, `obj/`, `lib/`, `build/`, API docs,
  downloaded engines, datasets, and benchmark results remain untracked.

## Verification and review

- `./tests/scripts/test.sh`: authoritative build and deterministic test suite.
- `./scripts/prove.sh`: authoritative SPARK gate. Every reported check in selected units must prove.
- `./scripts/check-repository.sh`: manifest, provenance, format, and repository-shape checks.
- Public contract or deterministic policy changes require tests and proof. Persisted I/O changes also require
  corruption, truncation, wrong-identity, overflow, and golden-byte tests.
- Publication changes require pre/post-upload, pre/post-head, lost-response, stale-generation, crash/reopen, and
  complete-local-loss cases. Cache changes require cold, warm, eviction, corruption, and complete-loss cases.
- Keep trusted proof boundaries narrow and documented. Do not use `SPARK_Mode => Off`, `pragma Assume`, imported
  ghost axioms, or false-positive suppression to bypass proof work.
- Each focused commit is reviewed against its parent for correctness, crash safety, concurrency, ownership,
  bounds, formats, storage assumptions, isolation, tests, proof, documentation, and unnecessary surface.
- Fix all P0/P1 findings before proceeding. Normally fix P2 in the unit; disposition any deferred P2/P3 explicitly.
  Reverify and amend the current unit, then re-review the amended commit.

## Commits

Use the repository Problem/Solution format:

```text
Problem: <one-line present-tense problem>

<Affected component, failure mode, and impact.>

Solution: <one-line solution>

<Changes, invariants, tests, and proof.>
```

Before committing, run `git diff --check`, inspect every staged path, and report the exact verification performed.
