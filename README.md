# Flyology.DB

Flyology.DB is an experimental embedded, object-native transactional key-value database for Ada. Its Alire crate
is `flyology_db`, and its public Ada namespace is `Flyology.DB`.

The design uses object storage as the authority for committed state. The initial topology has one fenced writer,
read-only replicas, a database-wide sequence and commit log, and independent physical state per column family.
Memory and local files are bounded caches or staging areas; removing them must not remove an acknowledged durable
transaction.

This repository is under active development. The current acceptance state and remaining work are recorded in
[the milestone plan](docs/architecture/milestones.md). No production qualification or performance claim is made.
The current operational slice covers provider-neutral memory/files backends, HEAD-v2, manifest-v2 roots with explicit
LSM limits, stable column-family handles, and a synchronous owned-byte runtime sized from persisted per-family/
database limits. Public synchronous `Flush` publishes and reconciles a complete checkpoint; later calls append one
canonical suffix-delta run for each affected family while retaining every current run oldest-to-newest. Tombstones
remain explicit, and cacheless recovery merges all named runs before replaying only the latest checkpoint's later log
suffix. Live activation replaces the coordinator without invalidating family handles or active transactions. An
additive caller-owned `Flush_Operation` drives that same checkpoint protocol directly through a bounded completion
set, moving one caller-sized unique-buffer token until typed `Finish`. Client-bound synchronous `Flush` is a literal
owner-driven wait over that operation; memory/files retain the backend-neutral synchronous publisher. Neither path
creates a helper task, and both preserve the same receipt and certainty mapping. The private operational
compaction spine now drives both a synchronous publisher and a test-qualified caller-composable replacement through
the same owner stack, receipt, and certainty machinery. It builds complete live-state runs and publishes a successor
manifest naming only those fresh outputs. It retains superseded immutable objects and adds no public trigger,
automatic scheduling, or physical-GC policy. Remote-provider qualification, the public compaction surface, run
pruning, and dynamic family changes remain separate review units.
The LSM read-equivalence lane independently checks that a complete live-state replacement emits one Put for each
live key, no entry for absence, reconstructs every captured point read exactly, and remains equivalent after any
later delta containing Puts, Deletes, or untouched keys. This closes concrete replacement-read semantics without
claiming an Ada refinement theorem or selecting compaction policy.
A separate partial-merge lane places two selected consecutive runs between retained older and newer runs. It proves
that replacing the selected pair with its newest mutation per key preserves every read, including the essential rule
that a newest selected tombstone remains present to mask older retained values. It selects no compaction trigger,
fanout, level sizing, schedule, capacity, or public API. The private operational coalescing kernel takes the more
conservative snapshot-safe step: it merges two ordered nonoverlapping SSTs while retaining every version and
tombstone. It derives exact output extents from the validated inputs and does not yet select or publish runs.
The formal cache boundary now binds every read, verified immutable entry, in-flight fetch, joined waiter, and result
to one exact object generation. It proves that corruption and complete local loss cannot change durable authority or
produce stale results, without selecting a cache capacity, eviction policy, disk layout, or operational Ada surface.
The formal retention boundary separately requires both explicit age eligibility and a live reachability recheck
before immutable-object deletion. Current authority, active snapshots, replica pins, required predecessors, and
unresolved publication attempts remain protected; provider listing alone grants no deletion authority. No age
horizon, delete batch policy, or operational collector is selected.
The private replica-refresh spine now performs one caller-triggered, complete recovery under the existing exclusive
lifecycle gate and installs only a strictly newer `(HEAD ordinal, writer epoch)` pair. Same or older observations are
discarded, allocation failure leaves the prior view intact, and a fenced writer cannot refresh itself into a promoted
writer. No public replica API, polling task, lease duration, retry, or promotion policy is selected.
Transactions now capture a Begin-time sequence
and reject exact written keys changed by later committed history. Fixed-snapshot point reads are operational;
explicit serializable transactions retain and validate exact successful and absent point reads plus caller-observed
half-open scan predicates. `Observe_Range` records conflict authority without reading rows. The bounded synchronous
`Scan` materializes a complete selected-family interval at the transaction's fixed snapshot in unsigned-byte key
order; persisted live-entry/live-byte limits bound its owned result, and Serializable success retains the same
predicate only after complete materialization. Transaction-owned predicates now normalize same-family overlap and
endpoint contact into exact unions before the persisted component count is enforced. Cross-family predicates remain
separate; full-capacity merges succeed, while capacity or allocation failure leaves the prior set exact.

## Durability rule

A transaction is durably committed only after its complete immutable batch object is published and `meta/HEAD` is
conditionally advanced from the exact expected generation. A lost response is reconciled by reading the head and
matching the transition identity; unresolved storage failure remains `Outcome_Unknown`.

The normative architecture is in [overview.md](docs/architecture/overview.md), and persisted format requirements
are in [persisted-formats.md](docs/architecture/persisted-formats.md). Differential engines are comparative oracles;
the [workload contract](oracles/contract/README.md) and Ada/SPARK model define Flyology.DB semantics.

## Build and verification

The ignored `.deps/flyology-object-storage` directory is a clean clone of the local Object Storage author checkout.
The root manifest path-pins it for development while leaving its indexed HTTP dependency unchanged.

```sh
alr build
./tests/scripts/test.sh
./scripts/prove.sh
./scripts/check-tla.sh
./scripts/check-repository.sh
```

The exact Object Storage commit used by the current campaign is recorded in
[dependency-provenance.md](docs/qualification/dependency-provenance.md).

The TLA+ gate exhausts the bounded commit-publication state machine, checks the unbounded safety kernel with TLAPS,
and regenerates a workload witness for later replay against the Ada model, Flyology.DB, and comparative oracles.

## Agent setup

Flyology.DB provisions shared Ada agent instructions and skills through
[APM](https://microsoft.github.io/apm/). Install the validated APM release and the exact dependency revision
recorded in `apm.lock.yaml`, then generate resources for Codex and Claude:

```sh
curl -sSL https://aka.ms/apm-unix | sh -s -- @v0.28.0
apm --version

apm install --frozen
apm compile --target codex
```

The compiled `AGENTS.md` is committed so Codex can use the repository without a setup step. Claude rules and
both clients' native skill trees are generated locally from the same locked package graph. Repository-specific
rules remain in `agent-packages/repository`; general Ada and workflow resources come from the shared profile.

APM 0.28.0 compilation must run before materializing `.deps`, or while that ignored directory is temporarily outside
the workspace. The Object Storage clone contains its own repository instruction package, and this APM release scans
that nested package despite `.gitignore`; compiling with the clone present can select the wrong root guide. Always
require `git diff --exit-code -- AGENTS.md apm.lock.yaml` after compilation so scope contamination fails visibly.

The root package follows the shared profile's `main` update channel, while `apm.lock.yaml` pins the exact reviewed
commit used by normal and frozen installs. Upgrade that lock deliberately, never as part of validation CI:

```sh
apm outdated
apm update flyology-ada/agents
apm compile --target codex
apm compile --validate
apm install --frozen
apm audit --ci
git diff --check
```
