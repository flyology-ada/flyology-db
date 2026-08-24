# LSM checkpoint publication design

This document freezes the semantic checkpoint-publication decision. The format layer defines current manifest-v3,
readable predecessor manifest-v2, and exact SST-v1 bytes, plus a private SPARK reference decoder and a byte-identical
dynamically sized operational codec. The codec is the allocation and validation boundary. New Create operations
publish an empty manifest-v3 root carrying the explicit LSM policy. Cacheless Open now admits a complete nonempty
first checkpoint, reconstructs its exact state and
identity partition, and replays only later batches. The internal checkpoint planner assembles an exact successor and
its family SSTs. Public synchronous `Flush`, caller-composable `Flush_Operation`, and `Resolve_Flush` publish and
reconcile checkpoints through the same self-contained receipt and certainty rules. The first operational unit
publishes one checkpoint. The successive-replacement unit reuses that API to publish later complete snapshots before
multi-run L0 accumulation and compaction are introduced. Existing manifest-v1 databases remain readable for log-only
operation.

## Staged compatibility decision

A current checkpoint uses column-family manifest object version 3 and immutable SST object kind 4. Manifest version
1 remains readable as a log-only registry and limit authority, but it cannot name runs or a replay boundary. Manifest
version 2 remains readable for snapshot operation but carries no serializable point/range count authority. There is
no in-place rewrite and no implicit migration. New databases start with a manifest-v3 root whose replay
boundary, run set, and identity ledger are empty; Create persists every database and family LSM limit supplied by the
caller. Public Flush writes complete immutable SST runs and a successor manifest-v3 object before one exact
conditional HEAD transition. Exact wire widths, offsets, checksums, goldens, corruption fixtures, decoder proofs,
dynamic admission, and the cacheless reader apply to the same production state machine used by deterministic test
fixtures.

Create, Open, create reconciliation, and ambiguous-commit resolution retain the authenticated manifest-v2/v3 policy
in live engine state. Legacy v1 activation retains an explicit no-LSM sentinel and never synthesizes replacement
policy. This is the authority used by the staged Flush path; public handles are not a second source.

Every installed live key also retains the exact nonzero sequence of its last authenticated Put. Same-key replacement
changes that sequence to the replacing transaction's sequence, and cacheless batch replay reconstructs it exactly.
The later SST snapshot consumes this retained authority; it never infers a sequence from traversal order, current
HEAD, or the flush operation.

Manifest v2 introduced the complete immutable family registry and LSM policy. Current manifest v3 preserves that
layout and adds independent database-wide serializable point/range counts. The LSM extension includes,
at minimum, for each family:

- `Memtable_Max_Bytes`, a nonzero logical byte budget;
- `Memtable_Max_Entries`, a nonzero entry budget; and
- `Maximum_L0_Runs`, a nonzero bound on named level-zero runs.

Database-wide limits independently bound the total number of named L0 runs, the exact admitted-identity ledger, and
the point/range observations retained by a serializable transaction.
The per-family and aggregate bounds are distinct: every proposed family run set must fit its family limit, their sum
must fit the database run limit, and the exact checkpoint identity ledger must fit the database identity limit.
Per-family key/value limits remain the authority for individual allocation and mutation admission. No global default
silently narrows them.

## Immutable objects and identities

A first checkpoint snapshots an already committed replay boundary. For each nonempty family snapshot, the writer
constructs one complete immutable L0 run sorted by that family's persisted byte ordering. Empty families need no
run. Every run carries a caller- or operation-stable nonzero identity. The manifest identity and attempted HEAD
transition identity are likewise stable for the operation; reconciliation never invents replacement identities.
The exact offsets, widths, canonical ordering, and corruption rules are normative in `persisted-formats.md`.

Current manifest version 3 records:

- its immutable predecessor and complete unchanged registry and limits;
- the exact family-to-L0-run mapping, appending new run IDs without rewriting an existing run;
- the exact global replay-boundary sequence;
- the exact admitted transaction/group identity authority through that boundary; and
- the expected and publication HEAD transition identities.

The identity ledger includes every admitted identity whose nonreuse must survive removal of its batch from the replay
suffix, including admitted failed/orphan authority covered by the checkpoint. It is not reconstructed from visible
keys. The manifest and runs are immutable; provider generations remain opaque validators, not content checksums.

## Publication state machine

Both public forms serialize `Flush` against the existing bounded native Ada coordinator. The synchronous procedure
waits directly; the additive `Flush_Operation` is an owner-stack state machine driven by the caller's completion set.
There is no automatic flush task, task per run, detached helper, callback thread, or compaction task in this stage.
Once admitted, either form follows one absolute deadline and retains a self-contained receipt with the stable run
and manifest IDs, exact expected HEAD generation/transition, attempted transition identity, replay boundary, and
phase.

The composable established form retains borrows of its completion set, database, client-bound storage context, exact
HTTP client, buffer pool, and optional cancellation token until typed `Finish` or finalization drain. `Start_Flush`
validates those owners and copies the run map before reserving its visible slot. Only then does it move the exact
caller `Unique_Buffer` token into operation ownership. Any initiating exception rolls back lifecycle and slot
admission and leaves byte length, tag, metadata, and payload ownership unchanged. Terminal `Finish` is the sole
normal restoration authority and accepts any vacant handle from the same pool; the operation retains no pointer to
the initiating handle. Scope abandonment first cancels and drains nested Object Storage/HTTP work, then releases the
token to its pool.

The caller chooses the scratch pool block size from persisted database/family limits and the intended encoded object
bound; the DB adds no public body-size default. Before the first conditional Put, the driver constructs and hashes the
complete plan and verifies that every run, manifest, and HEAD image fits that block. A smaller block is a definite
`Capacity_Exceeded` result with no publication. The current nested provider stack needs four reusable completion-set
slots while one Flush mutation is active: the visible DB parent, Object Storage conditional Put, HTTP exchange, and
one transport child. Slot exhaustion before a child request is typed capacity/backpressure, never publication
uncertainty.

Before storage admission, the lifecycle enters an exclusive checkpoint mode and waits for every already-admitted
database call to finish. The builder reads actual per-family entry and payload totals, checks them against that
family’s persisted memtable limits, then allocates an exact transient reference array and exact SST object. References
borrow immutable engine images only while checkpoint mode excludes close and mutation. Arbitrary byte keys are sorted
canonically, duplicate live keys fail closed, exact retained last-write sequences populate the run, and the operational
SST encoder revalidates the complete result. Allocation failure is typed capacity and cannot publish an object. This
work is designed for the bounded native coordinator; it creates no per-flush, per-run, or per-entry helper task.

The complete unpublished plan includes one exact SST allocation for every nonempty canonical family, no allocation
for an empty family, and one exact successor-manifest allocation. It retains the provider generation and transition
identity observed with the committed HEAD snapshot, advances the manifest ordinal and registry revision exactly once,
uses the committed highest sequence as its replay boundary, and copies the complete never-reused admission ledger.
The ledger is sorted by identifier bytes before structural validation. Family, aggregate-run, and exact-identity
limits come only from the authenticated manifest-v3 policy. Any validation or allocation failure releases the whole
plan and leaves batch, manifest, and HEAD publication counts unchanged.

The caller supplies an exact family-to-run identity map with one entry for every persisted family. Input order is not
authority: the planner joins by stable family ID and emits canonical registry order. Every run ID is nonzero, unique
within the operation, and distinct from the operation's manifest and transition identities. Duplicate, missing,
unknown, or colliding mappings fail before checkpoint allocation or object I/O. Empty families publish no run, so
their mapped identities are not consumed by this checkpoint. The planner copies selected IDs into owned SSTs and
retains no pointer to the caller's array.

Publication order is strict:

1. Snapshot the committed boundary and the exact identity authority covered by it.
2. Validate per-family memtable and L0 bounds plus database-wide run and identity capacity before effects.
3. Write each complete immutable sorted run and confirm its exact bytes.
4. Write the complete immutable manifest and confirm its exact bytes.
5. Conditionally replace HEAD from the exact expected provider generation and transition identity.
6. Classify success only from the completed conditional response or conclusive reconciliation.

An observed Put or response byte is not conclusive. A lost response after the HEAD call is `Outcome_Unknown`. The
unknown writer remains fenced and does not publish later work. A whole authenticated HEAD read confirms the attempted
transition or a fully validated reachable successor; an unaccepted conditional write followed by an exact rival
ordinal/transition can conclude rejection. Continued unavailability remains unknown. A stale expected generation
cannot publish. Backpressure before step 3 produces no run, manifest, or partial visible state.

The receipt distinguishes immutable-object uncertainty, HEAD uncertainty, confirmed HEAD awaiting local activation,
and a terminal result. Immutable-object resolution rebuilds the exact deterministic plan from the fenced coordinator
and uses only the retained identities; pre-existing objects must match byte for byte. HEAD resolution is read-only and
accepts success only when cacheless recovery reaches the exact checkpoint manifest and replay boundary. A completed
HEAD transition first fences the old coordinator, then installs a newly allocated coordinator from the exact plan.
If that local allocation or installation fails, `Local_Activation_Failed` preserves durable-success certainty and
`Resolve_Flush` can activate the same checkpoint from cacheless recovery. Normal success leaves the database open and
usable; it does not require close/reopen.

Later transaction commits preserve the published manifest ID. The checkpoint does not change the visible state: it
only replaces the authoritative representation of the committed prefix. No run or manifest is visible before the
successful HEAD transition, and unreachable complete objects remain orphans.

## Successive whole-state replacement

A later `Flush` may replace an existing checkpoint with a new complete whole-state checkpoint. It does not append a
second current L0 run. For each nonempty family, the planner writes one newly identified immutable run containing the
complete live family state at the new replay boundary; empty families again name no run. The successor manifest names
only those new runs and links immutably to the prior manifest. Prior manifests and runs remain immutable and stored,
but are not current read authority after the HEAD transition. Reclamation remains a later garbage-collection unit.

This stage is intentionally a checkpoint replacement, not compaction: it neither merges a current multi-run set nor
claims level policy. It removes the one-checkpoint operational restriction and exercises repeated publication,
activation, cacheless recovery, and history backpressure using the existing format. True incremental L0 accumulation
will later preserve multiple current run descriptors and tombstones and will use the already persisted per-family and
database run limits.

The current manifest's `Registry_Revision` is also its exact one-based immutable predecessor-chain depth: roots are
revision one and every successor increments once under predecessor validation. A new checkpoint requires
`Registry_Revision < Maximum_Manifest_History`; equality is definite `Capacity_Exceeded` before any immutable object
publication. This derives the next available history slot from persisted authority and introduces no flush-count
default. Integer exhaustion likewise rejects before effects.

Checkpoint replacement retains the complete admitted identity ledger through the new boundary. The newly activated
engine reconstructs the exact live state and identity authority from the replacement runs, discards the old local
checkpoint images only after the lifecycle has installed and exposed the successor, and starts with an empty replay
suffix. Existing family handles retain the engine incarnation. Active calls drain before planning, and no pointer or
borrow into the replaced engine survives its joined finalization.

The same certainty boundary applies to every checkpoint ordinal. Immutable objects are confirmed byte-for-byte
before HEAD admission; a lost accepted HEAD response remains unknown until cacheless recovery reaches the exact new
manifest and replay boundary. Rebuilding an `Objects_Unknown` plan uses only the receipt's original identities.
Repeated publication never creates a replacement identity or retries an application transaction.

## Cacheless recovery

Recovery after total local loss starts from `meta/HEAD`; listing and local state are never authority. It reads and
validates the exact manifest named by HEAD, then reads every named family run and the complete identity ledger. Every
run must be present, complete, uncorrupted, sorted, in the named family, and consistent with the manifest registry and
limits. Missing, corrupt, partial, unconfirmed, over-capacity, or registry-incompatible state fails closed without
installing a partial cache.

The engine reconstructs state at the manifest replay boundary from the runs, imports exactly the checkpoint identity
authority, and replays only batches strictly after that boundary. A batch at or below the boundary is never applied
again. The final state and used-ID set are exactly the disjoint union of the checkpoint partition and the validated
post-boundary replay partition. Run images, replay batches, and local indices remain disposable caches.

## Formal boundary

`CheckpointPublication.tla` exhaustively explores a finite two-family abstraction, including exact per-family run
placement and reconstruction, exact captured identity authority, separate family/aggregate run and identity capacity,
accepted and lost HEAD responses, unaccepted responses, an external prepublication advance, a rival transition,
crash, cacheless recovery, missing/corrupt run rejection, and committed/rejected/recovery witnesses. Deliberately
unsafe stale-publication, partial-run, wrong-family, and wrong-ledger actions are excluded from the normal transition
relation. Probe modules add them one at a time after reachable prefixes and must violate the matching invariant.

`CheckpointSafetyProof.tla` is a smaller unbounded safety kernel. Its 43 strict TLAPS obligations prove only the
abstract ordering and partition facts: bytes precede confirmation, HEAD names confirmed objects, the registry is
immutable, publication uses the exact expected generation, checkpoint and later authority are disjoint and exact,
replay does not overlap the checkpoint, recovery reconstructs that partition exactly, and local state is disposable.
Concrete family/run contents, sorting, corruption, capacity arithmetic, provider behavior, reconciliation branches,
binary codecs, and a refinement relation to Ada remain outside that kernel and are covered here only by exhaustive
TLC or future gates.

`SuccessiveCheckpointPublication.tla` separately freezes replacement. Its finite geometry publishes a first
checkpoint, commits one later suffix transaction, and either backpressures at a persisted two-manifest history or
confirms and conditionally publishes a complete second checkpoint under a three-manifest history. It covers an
accepted lost second-HEAD response, read-only resolution, crash, exact recovery, replacement of the current run, and
the fact that old immutable bytes remain stored but no longer define current visibility. A negative probe publishes
the second HEAD before its run and manifest are confirmed and must violate the integrated safety predicate. A
separate machine-validated witness selects the accepted-lost response, read-only resolution, crash, and exact
recovery path for comparison with the production corpus.

`SuccessiveCheckpointSafetyProof.tla` is the corresponding unbounded replacement kernel. It permits arbitrarily many
prepare/confirm/publish cycles over arbitrary state and identity sets. Strict TLAPS proves stored-before-confirmed and
confirmed-before-HEAD ordering, exact checkpoint/suffix partitioning after every replacement, exact recovery, and
disposable local state. Manifest-chain arithmetic, concrete bytes, sorting, provider reconciliation, persisted
capacity arithmetic, and a refinement relation to Ada remain outside this kernel.

## Non-goals

This design does not implement automatic flushing, multi-run L0 accumulation, compaction, run pruning, garbage
collection, remote-provider matrix qualification, or an LSM performance claim. Its operational scope is manifest-v3
root creation, exact whole-checkpoint planning, certainty-preserving synchronous and composable checkpoint
publication/reconciliation, successive complete replacement, and header-first cacheless recovery of the latest
checkpoint plus its later batch suffix.
