# Flyology.DB

Flyology.DB is an experimental embedded, object-native transactional key-value database for Ada. Its Alire crate
is `flyology_db`, and its public Ada namespace is `Flyology.DB`.

The design uses object storage as the authority for committed state. The initial topology has one fenced writer,
read-only replicas, a database-wide sequence and commit log, and independent physical state per column family.
Memory and local files are bounded caches or staging areas; removing them must not remove an acknowledged durable
transaction.

This repository is under active development. The current acceptance state and remaining work are recorded in
[the milestone plan](docs/architecture/milestones.md). No production qualification or performance claim is made.
The current usable boundary is the deliberately narrow
[limited end-to-end profile](docs/architecture/limited-profile.md): one writer, one checkpoint-bound append-only
family change, synchronous transactions, Flush, caller-selected adjacent compaction, exact close/local-loss/reopen
recovery, and no automatic maintenance or retry policy.
The current operational slice covers provider-neutral memory/files backends, HEAD-v2, manifest-v3 roots with explicit
LSM limits, stable column-family handles, and a synchronous owned-byte runtime sized from persisted per-family/
database limits. Public synchronous `Flush` publishes and reconciles a complete checkpoint; later calls append one
canonical suffix-delta run for each affected family while retaining every current run oldest-to-newest. Tombstones
remain explicit, and cacheless recovery merges all named runs before replaying only the latest checkpoint's later log
suffix. Live activation replaces the coordinator without invalidating family handles or active transactions. An
exact-checkpoint `Add_Column_Family` operation now appends one caller-configured higher-ID family, publishes one
immutable manifest and conditional HEAD, and retains exact same-identity reconciliation authority. Its additive
operation-last overload uses the existing caller-owned `Flush_Operation`; the client-backed synchronous form is a
literal wait over that state machine. It derives all
allocation extents from persisted database and family limits; fresh-root and unflushed-suffix calls reject before
publication because no caller-owned SST identity may be invented. The public files showcase observes additive work,
checkpoints one root family, confirms the clean boundary, appends a second, writes and observes additive work for
both, Flushes and confirms the clean boundary, compacts the exact adjacent root-family pair, discards all local
state, and recovers both families from object storage alone. An
additive caller-owned `Flush_Operation` drives that same checkpoint protocol directly through a bounded completion
set, moving one caller-sized unique-buffer token until typed `Finish`. Client-bound synchronous `Flush` is a literal
owner-driven wait over that operation; memory/files retain the backend-neutral synchronous publisher. Neither path
creates a helper task, and both preserve the same receipt and certainty mapping. Public `Start_Compaction` and
blocking `Compact` drive the complete-view replacement through that same owner stack, receipt, and certainty
machinery. They build one complete live-state run per nonempty family and publish a successor manifest naming only
those fresh outputs. The caller supplies the exact complete family/output map and stable manifest/transition
identities; the DB retains superseded immutable objects and selects no automatic trigger, level, fanout, schedule,
retry, or physical-GC policy. Overloaded public `Start_Compaction` and blocking `Compact` forms also accept either
one exact caller-selected adjacent run pair or one exact caller-selected three-run consecutive slice, plus fresh
output, manifest, and transition identities. They retain every version and tombstone, preserve surrounding runs and
any later committed suffix, and use the same operation, receipt, certainty, and reconciliation machinery. Three is
the qualified algorithm shape, not a fanout or maintenance default. Run selection, pruning, and broader family
evolution remain separate review units.
Public `Required_L0_Checkpoint_Action` now inspects one quiescent writer view and projects the persisted per-family
and database-wide L0 run ceilings into no work, additive Flush, or complete compaction. It performs no storage I/O,
reserves no identity, and schedules no work; callers still provide every immutable and transition identity, and the
chosen publication operation revalidates the observation. `Observe_L0_Checkpoint_Requirement` additionally retains
the exact affected family IDs from that same view in an owned limited value: changed families for additive Flush,
nonempty families for complete compaction, and none for no work. Failed replacement preserves the prior value.
The LSM read-equivalence lane independently checks that a complete live-state replacement emits one Put for each
live key, no entry for absence, reconstructs every captured point read exactly, and remains equivalent after any
later delta containing Puts, Deletes, or untouched keys. This closes concrete replacement-read semantics without
claiming an Ada refinement theorem or selecting compaction policy.
A separate partial-merge lane places two selected consecutive runs between retained older and newer runs. It proves
that replacing the selected pair with its newest mutation per key preserves every read, including the essential rule
that a newest selected tombstone remains present to mask older retained values. It selects no compaction trigger,
fanout, level sizing, schedule, or capacity. The operational coalescing kernel takes the more
conservative snapshot-safe step: it merges two ordered nonoverlapping SSTs while retaining every version and
tombstone. Its manifest-aware entry point admits only exact adjacent descriptors and rejects any output identity
already named by that manifest. An effect-free successor builder also requires the caller-prepared base to be the
exact next checkpoint transition, replaces only those two descriptors, and retains every family rule, replay
boundary, identity, limit, and surrounding run. It derives all output extents from validated authority and publishes
no partial candidate. The public caller-selected operation binds the retained manifest to the exact current
HEAD generation, authenticates its SSTs with header-first generation-bound reads, and sends the merged SST and
successor through the existing immutable confirmation, conditional HEAD, activation, and exact-identity resolution
machinery. The successor publisher also supports a later log suffix: before publication it clones the exact decoded
batch descriptors and shared immutable-image ownership, rebuilds the activation base strictly from successor SSTs,
and replays the suffix into the replacement coordinator. Cacheless recovery accepts the same topology only when the
validated manifest predecessor chain anchors
both the latest batch publication and the checkpoint boundary it follows. It still selects no trigger, schedule,
fanout, level policy, or automatic selection rule.
An additive exact-three-run kernel and public caller-selected overload qualify composition beyond the pair without
choosing automatic policy.
It accepts exactly three caller-selected adjacent descriptors, computes one checked exact output allocation, retains
every version and tombstone, and builds an effect-free successor that replaces only that slice. The exhaustive TLA+
lane covers the essential middle-tombstone case when the last selected run has no mutation for the key; its TLAPS
kernel proves associative composition and read equivalence with retained older/newer runs and any later suffix.
The operational publisher reads all three exact generation-bound inputs through the same owner-driven
Flush state machine as pair publication, publishes one immutable output and successor, conditionally advances HEAD,
and retains all three source identities in an uncertain receipt for exact-byte reconciliation. Cacheless activation
uses only the highest-sequence entry per key in each SST, so an admitted middle tombstone cannot resurrect an older
put retained in the merged object. Three is qualification geometry exposed only through an exact caller-selected
operation, not a fanout, trigger, level, capacity, retry, or automatic-maintenance policy.
The formal cache boundary now binds every read, verified immutable entry, in-flight fetch, joined waiter, and result
to one exact object generation. It proves that corruption and complete local loss cannot change durable authority or
produce stale results, without selecting a cache capacity, eviction policy, disk layout, or operational Ada surface.
The formal retention boundary separately requires both explicit age eligibility and a live reachability recheck
before immutable-object deletion. Current authority, active snapshots, replica pins, required predecessors, and
unresolved publication attempts remain protected; provider listing alone grants no deletion authority. No age
horizon, delete batch policy, or operational collector is selected.
Public `Refresh_Replica` now performs one caller-triggered, complete recovery of an open handle dedicated by its
caller to read-only use. Under the existing exclusive lifecycle gate it installs only a strictly newer
`(HEAD ordinal, writer epoch)` pair. Same or older observations are discarded, allocation failure leaves the prior
view intact, and a fenced writer cannot refresh itself into a promoted writer. The call supplies no polling task,
lease duration, retry, registration, retention, or promotion policy.
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
./showcases/run-limited-e2e.sh
./tests/scripts/test.sh
./tests/scripts/test-s3-matrix.sh
./scripts/prove.sh
./scripts/check-tla.sh
./scripts/check-repository.sh
```

The separate S3 matrix requires Docker and runs the authenticated DB probe three times against pinned RustFS,
SeaweedFS, MinIO, and Flyology memory, files, and SQLite servers. It reuses Object Storage's maintained provider
lifecycle scripts while DB owns the database-level create, checkpoint-bound family append, exact lost-response
resolution, cross-family commit and Flush, compaction, and cacheless-reopen oracle. The repetition count is
qualification geometry and can be changed for focused diagnostics with
`FLYOLOGY_DB_S3_MATRIX_REPEATS`; it is not a database retry or compatibility policy.

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

The root `compilation.exclude` keeps ignored `.deps` checkouts outside APM primitive discovery. This matters because
the Object Storage clone carries its own repository instruction package; without the exclusion, compiling with the
clone present can select the wrong root guide. Keep the exclusion when changing agent packaging, and always require
`git diff --exit-code -- AGENTS.md apm.lock.yaml` after compilation so scope contamination fails visibly.

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
