# LSM checkpoint publication design

This document freezes the semantic checkpoint-publication decision. The format layer defines current manifest-v3,
readable predecessor manifest-v2, and exact SST-v1/v2 bytes, plus a private SPARK reference decoder and dynamically
sized operational codecs. New run publication selects v2; recovery admits v1, v2, and mixed manifests without
rewriting immutable objects. The codec is the allocation and validation boundary. New Create operations
publish an empty manifest-v3 root carrying the explicit LSM policy. Cacheless Open now admits a complete nonempty
first checkpoint, reconstructs its exact state and
identity partition, and replays only later batches. The internal checkpoint planner assembles an exact successor and
its family SSTs. Public synchronous `Flush`, caller-composable `Flush_Operation`, and `Resolve_Flush` publish and
reconcile checkpoints through the same self-contained receipt and certainty rules. The first call publishes complete
family snapshots; later calls append suffix-delta runs and retain the current descriptor set. Public
`Start_Compaction` and blocking `Compact` replace the complete live view through that same state machine without
selecting automatic policy. Existing manifest-v1 databases remain readable for log-only operation. Partial-run
compaction and run pruning remain separate units.

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

- its immutable predecessor and complete registry and limits; an ordinary checkpoint preserves the registry, while
  a registry-change checkpoint may append exactly one higher-ID family without changing any prior record;
- the exact family-to-L0-run mapping, appending new run IDs without rewriting an existing run;
- the exact global replay-boundary sequence;
- the exact admitted transaction/group identity authority through that boundary; and
- the expected and publication HEAD transition identities.

The identity ledger includes every admitted identity whose nonreuse must survive removal of its batch from the replay
suffix, including admitted failed/orphan authority covered by the checkpoint. It is not reconstructed from visible
keys. The manifest and runs are immutable; provider generations remain opaque validators, not content checksums.

## Publication state machine

Both public Flush forms and the checkpoint-carried, suffix-preserving family-append forms serialize against the
existing bounded native Ada coordinator. The additive
`Flush_Operation` is an owner-stack state machine driven by the caller's completion set. Client-bound synchronous
`Flush` creates its temporary set and buffer pool lazily, atomically promotes its existing lifecycle lease into that
same operation, and waits as the owner. Memory/files retain the backend-neutral synchronous publisher until those
backends expose caller-driven children. There is no automatic flush task, task per run, detached helper, callback
thread, or compaction task in this stage.
Once admitted, either form follows one absolute deadline and retains a self-contained receipt with the stable run
and manifest IDs, exact expected HEAD generation/transition, attempted transition identity, replay boundary, and
phase.

The composable established forms retain borrows of their completion set, database, client-bound storage context, exact
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
uncertainty. The client-bound synchronous wrapper derives its one scratch-block size with checked arithmetic from
persisted live-entry, live-byte, total-run, identity, and immutable family-name authority plus frozen format framing.
It allocates that one-token pool only for the call. Failure before lifecycle promotion is definite capacity failure.

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

The caller supplies an exact family-to-run identity map with one entry for every family selected by the checkpoint
requirement: every suffix-changed family for additive Flush, or every complete-view nonempty family for replacement.
Input order is not authority: the planner joins by stable family ID and emits canonical registry order. Every run ID
is nonzero, unique within the operation, and distinct from the operation's manifest and transition identities. A
missing required family, duplicate family or run ID, unknown family, or colliding identity fails before checkpoint
allocation or object I/O. A legacy full persisted-family map remains accepted; entries for families with no work are
ignored and their run identities are neither published nor reserved. The planner copies selected IDs into owned SSTs
and retains no pointer to the caller's array.

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

The client-backed resolver is provider-centrically colocated with the ordinary checkpoint vocabulary. Its
operation-last overload reuses `Flush_Operation`, moves the self-contained receipt and exact caller scratch token,
and returns both only through the existing typed `Finish`. Immutable uncertainty reconstructs only the original
plan; HEAD uncertainty transfers the already-held checkpoint admission to the shared recovery child. The blocking
buffer overload is a wait over this same state machine. The storage-neutral resolver remains direct, and neither
path creates a helper task, hidden retry, second deadline, or new identity.

Later transaction commits preserve the published manifest ID. The checkpoint does not change the visible state: it
only replaces the authoritative representation of the committed prefix. No run or manifest is visible before the
successful HEAD transition, and unreachable complete objects remain orphans.

## Additive L0 accumulation

The operational algorithm follows the previously frozen model. A later Flush snapshots only the committed batch
suffix strictly after the current replay boundary. For each family with suffix mutations it emits one canonical immutable
run whose sequence range is strictly newer than that family's last current run. Within the suffix, only the newest
mutation for an exact key is required after the replay boundary advances; a Delete remains an explicit tombstone and
is never converted to absence in the run. A family without suffix mutations consumes no run object or mapped run ID.

The successor manifest preserves every current run descriptor in its existing oldest-to-newest order and appends the
new descriptor for each affected family. It advances the global replay boundary to the captured committed sequence
and retains the exact admitted identity ledger through that boundary. Admission requires each affected family run
count plus one to fit its persisted `Maximum_L0_Runs`, and the resulting aggregate to fit persisted
`Maximum_Total_L0_Runs`; checked failure is definite `Capacity_Exceeded` before any new run or manifest object.

Recovery validates every descriptor and object, then applies family runs oldest to newest. A newer Put replaces an
older value; a newer tombstone removes it and continues to mask all older runs. Sequence ranges must remain strictly
non-overlapping and increasing, so reconstruction never depends on provider listing or incidental object order.
Missing, malformed, misbound, overlapping, or reordered runs fail closed. Later batches are replayed only after the
manifest boundary. The separate replacement planner may compact this current run set; additive Flush never selects
that mode implicitly.

The public Flush signatures, receipt ownership, absolute deadline, and publication certainty do not change. The
caller may pass the exact affected-family projection returned by `Observe_L0_Checkpoint_Requirement` after assigning
one fresh identity to each family. A family uses its mapped ID only when it has a suffix delta, matching the existing
empty-family convention. A legacy full map can still publish an empty-suffix successor with no run objects; the
policy query reports no work and does not direct a caller to do so.

The Ada planner, synchronous wait, and composable state machine all use this algorithm. Local activation retains an
exact full live base without rereading storage. Cacheless activation allocates from authenticated run extents, merges
every run oldest-to-newest, trims scratch to the exact live base, and installs it under the existing lifecycle gate.

`Required_L0_Checkpoint_Action` exposes the first maintenance decision without inventing the identities or scheduler
needed to execute it. Under the exclusive checkpoint lifecycle gate it compares one coherent committed view with the
persisted per-family `Maximum_L0_Runs` and database-wide `Maximum_Total_L0_Runs`. It reports no work when the replay
boundary is current, additive `Flush` when one delta run per changed family fits, and complete `Compact` when additive
growth is full but one run per nonempty family fits. If neither representation fits, it returns definite
`Capacity_Exceeded`. The query performs no storage I/O, reserves no identity, and starts no task. Its answer is an
exact observation rather than a reservation: a later commit can change it, and publication revalidates all limits.
The caller still supplies every run, manifest, and transition identity to the existing operation.

`Observe_L0_Checkpoint_Requirement` uses that same coherent observation to retain an owned exact family set in
stable registry order. Additive selection retains the suffix-changed families; complete selection retains the
complete-view nonempty families; no work retains none. Storage is allocated lazily at the exact selected count from
persisted registry facts. Successful observation swaps the entire action/set pair into the limited caller-owned
value; any state or allocation failure preserves its prior contents. The value retains no database borrow and grants
no scheduling, identity, or publication authority. Its family projection is nevertheless the exact input domain for
the existing sparse Flush or complete Compact map at that observed state. Publication revalidates the domain after
entering the exclusive checkpoint lifecycle, so a later commit cannot turn the observation into a reservation.

The selection kernel is isolated in `Flyology.DB.Checkpoint_Policy` for SPARK proof. It uses checked arithmetic and
distinguishes changed families from complete-view nonempty families, so a tombstone-only suffix can require an
additive run while complete replacement may correctly emit no run for the now-empty family. The TLA+ selection lane
model-checks the same action and family projection, while the accumulation and compaction lanes remain the
publication witnesses; no Ada-to-TLA+ refinement theorem is claimed.

`L0Accumulation.tla` checks the concrete two-run tombstone merge, independent persisted capacity rejection, lost
accepted HEAD response, and exact recovery. `L0AccumulationSafetyProof.tla` proves the arbitrary-set, unbounded-cycle
publication kernel. The models freeze the algorithm and qualify its abstract publication invariants; no refinement
theorem from TLA+ to the Ada implementation is claimed.

The current manifest's `Registry_Revision` is also its exact one-based immutable predecessor-chain depth: roots are
revision one and every successor increments once under predecessor validation. A new checkpoint requires
`Registry_Revision < Maximum_Manifest_History`; equality is definite `Capacity_Exceeded` before any immutable object
publication. This derives the next available history slot from persisted authority and introduces no flush-count
default. Integer exhaustion likewise rejects before effects.

Checkpoint publication retains the complete admitted identity ledger through the new boundary. The newly activated
engine reconstructs the exact live state and identity authority from all named runs, discards the old local
checkpoint images only after the lifecycle has installed and exposed the successor, and starts with an empty replay
suffix. Existing family handles retain the engine incarnation. Active calls drain before planning, and no pointer or
borrow into the replaced engine survives its joined finalization.

The same certainty boundary applies to every checkpoint ordinal. Immutable objects are confirmed byte-for-byte
before HEAD admission; a lost accepted HEAD response remains unknown until cacheless recovery reaches the exact new
manifest and replay boundary. Rebuilding an `Objects_Unknown` plan uses only the receipt's original identities.
Repeated publication never creates a replacement identity or retries an application transaction.

## Append-only family registry publication

`Add_Column_Family` is the deliberately narrow operational use of the checkpoint-carried registry transition. It
accepts one complete `Column_Family_Configuration`, immutable successor-manifest identity, HEAD transition identity,
whole-operation monotonic timeout budget, optional cancellation token, and an owned receipt. The family ID must be strictly greater
than the existing last ID; its byte name must be unique. Every key/value, memtable, and L0 limit comes from that
configuration, while database-wide family, history, run, and identity capacity comes from the authenticated current
manifest. No default, generated ID, rename, drop, reorder, or prior-family mutation is selected.

The operation requires an exact durable checkpoint carrier. The successor copies that checkpoint's replay boundary,
run descriptors, identity ledger, LSM limits, and every prior family record byte for byte. A later committed suffix
remains outside that unchanged checkpoint partition: it is admitted only when the authenticated HEAD and batch chain
anchor every suffix batch strictly after the replay boundary. A fresh root has no retained checkpoint plan and still
rejects as `Invalid_State` before allocation or publication; the operation does not select an automatic Flush.

Planning lazily allocates exactly one successor checkpoint with `prior family count + 1`, the prior run count, and
the prior identity count. Checked arithmetic and structural validation precede effects. Allocation failure is
`Capacity_Exceeded` and leaves manifest and HEAD publication counts unchanged. The new family starts with zero runs;
its first later Flush uses the same persisted per-family and database-wide L0 capacity as every other family.

Publication confirms the exact immutable manifest bytes first, then enters one conditional HEAD replacement from
the retained provider generation. `Column_Family_Receipt` owns the exact configuration, manifest bytes, expected
HEAD/generation, attempted transition, and originating engine incarnation. Manifest ambiguity permits only
same-identity/same-byte continuation. HEAD ambiguity permits only complete cacheless recovery: an older observation
remains `Outcome_Unknown`, the exact attempted manifest in a validated reachable chain confirms publication, and a
conclusive successor chain that excludes it fences the stale writer. No result authorizes a replacement identity or
automatic mutation retry.

After confirmed publication, activation replaces the local engine through the existing checkpoint lifecycle while
preserving the process-session incarnation. The client/composable path installs its prepared view directly at the
exact checkpoint boundary. With a later suffix it transfers the same lifecycle admission into cacheless
authenticated recovery, which rebuilds the successor checkpoint and replays the anchored suffix before installation.
The storage-neutral synchronous path retains authenticated recovery activation at either boundary. A failed local
allocation/install or post-HEAD recovery is `Local_Activation_Failed`, retains durable-success authority, and can be
completed by `Resolve_Add_Column_Family`. Terminal success exposes the family through the existing
`Open_Column_Family` calls. The additive operation-last form reuses `Flush_Operation`, its
caller-owned completion set, moved scratch token, and typed token-restoring `Finish`; a runtime result discriminator
prevents the receipt-shaped Flush and family finishes from consuming one another. The client-backed synchronous form
allocates one derived scratch token and waits on that exact state machine. Memory and files retain the backend-neutral
synchronous publisher. No helper task, automatic retry, second deadline, or parallel API package is introduced.

The provider-bound family resolver is colocated on that same `Flush_Operation`. Start moves the self-contained
receipt and exact caller scratch token after reserving both the operation slot and checkpoint lifecycle admission.
`Family_Manifest_Unknown` decodes and authenticates the retained exact bytes, then admits only the original pending
HEAD transition. `Family_Head_Unknown` and `Family_Head_Confirmed` transfer the same admission into shared bounded
cacheless recovery. Recovery must reach the exact manifest and exact family configuration in a complete validated
chain before installing the successor; an excluding successor fences the writer, and a failed local install retains
confirmed durable authority. Typed family `Finish` returns both receipt and token. The buffer-owned client wrapper
waits this state machine; the storage-neutral resolver remains direct. Neither path replays a mutation, changes an
identity, creates a helper task, or starts a second deadline.

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

`LiveSuffixRegistryPublication.tla` isolates family append over a retained checkpoint plus a nonempty live suffix.
The pinned finite lane generates 26 states, finds 18 distinct states with an empty queue at depth 9, and covers 16
ordered actions: the first 15 once and `RecoverActivation` twice. It checks exact checkpoint/suffix identity
partitioning, read-only same-receipt manifest resolution, immediate fencing after confirmed HEAD, cancellation and
local activation failure, complete recovery, and rival rejection. Five negative probes must respectively violate
`CapturedPartitionIsExact`, `ConfirmedHeadImpliesFenced`, `ManifestResolutionDoesNotReplay`,
`ResolutionDoesNotReplay`, and `RivalCannotResolveCommitted`; canonical recovery and cancellation witnesses fix both
terminal routes. `LiveSuffixRegistryPublicationSafetyProof.tla` proves 25/25 strict obligations. This finite geometry
and its unbounded kernel prove neither provider behavior nor a refinement from the Ada implementation.

## Frozen L0 compaction boundary

Compaction is a complete-authority replacement, not an in-place rewrite and not physical garbage collection. It
captures one quiescent committed checkpoint view and its exact admitted-identity authority, emits a fresh set of
complete immutable outputs when the captured view contains live keys, and builds a successor manifest that names only
those outputs at the unchanged replay boundary. When every captured key is absent after tombstone application, the
canonical replacement is an empty run set: it creates no synthetic SST but still publishes and confirms the immutable
successor manifest before the exact-generation conditional HEAD transition. Every present output must likewise be
stored and confirmed first. A definite capacity or allocation failure before provider admission publishes nothing.

Once HEAD conclusively names the successor, prior current runs are no longer recovery or visibility authority. They
remain immutable stored history; this decision does not authorize their deletion, set an age threshold, or claim that
no active snapshot or replica can still require them. Physical reclamation needs its own reachability and retention
decision. A lost accepted HEAD response remains `Outcome_Unknown` until read-only reconciliation identifies the exact
attempted transition or a conclusive successor. No retry, replacement identity, automatic trigger, helper task, or
new public capacity/default follows from the compaction algorithm.

The operational replacement planner runs under the existing exclusive checkpoint gate. It snapshots the complete
live state rather than the post-boundary delta, allocates exact run and manifest extents from persisted database and
per-family limits, rejects any current immutable run identity, and prepares the complete activation base before the
first provider call. The shared checkpoint publisher then stores and confirms each output and the successor manifest
before the conditional HEAD transition. Public `Start_Compaction` selects this mode in the existing caller-owned
`Flush_Operation`, while `Start_Flush` continues to select additive mode. Blocking `Compact` waits on that operation
for client storage and drives the equivalent backend-neutral publisher for memory/files. Both modes share the same
completion-set owner stack, exact moved token, typed `Finish`, absolute deadline, publication certainty, and
same-identity whole-Get reconciliation. The receipt mode is retained solely so `Objects_Unknown` reconciliation
rebuilds the identical replacement bytes and identities; it is not persisted policy.

The adjacent-merge publisher is a narrower policy-neutral sibling exposed through overloaded public
`Start_Compaction` and `Compact` declarations. Its caller supplies the exact older,
newer, output, manifest, and transition identities. Under the same exclusive checkpoint lifecycle, it binds the
retained checkpoint manifest to the exact current HEAD generation, reads every named SST through the maintained
header-first and generation-bound whole-object path, and admits the pair only through the manifest-aware adjacent
merge kernel. It prepares the exact successor and its SST-derived activation base before the first write. The shared
publisher then confirms the merged SST and successor manifest before the conditional HEAD transition. An ambiguous
immutable-object result fences the writer and retains the selected input identities privately in the receipt so
`Resolve_Flush` can rebuild only the same bytes and identities. The composable form retains the exact moved token
until typed `Finish`; the blocking client form waits on that same operation. It never substitutes an additive or
complete-view plan, generates a new identity, or automatically retries.

If the retained checkpoint replay boundary precedes current HEAD, the quiescent planner clones every decoded suffix
batch at its exact transaction and mutation extents and retains shared ownership of each immutable image before the
first write. It validates newest-to-oldest predecessor continuity, exact current-HEAD publication of the newest
batch, and the oldest batch's transition from the retained checkpoint. Allocation or validation failure releases the
complete candidate and publishes nothing. The replacement coordinator reconstructs its base strictly from the
successor's authenticated SSTs, then replays the cloned suffix oldest-to-newest. This preserves live values,
write-conflict history, seen transaction IDs, used batch IDs, and the never-reused identity ledger; copying only the
live image would not suffice.

Cacheless recovery applies the same authority boundary without trusting the current HEAD as the batch's immediate
publication transition. The already-validated immutable manifest predecessor chain must contain an exact expected
transition anchor for the latest retained batch and an exact replay-boundary checkpoint whose publication transition
the oldest suffix batch names. Thus a manifest-only successor can preserve the suffix, while an orphan batch or a
suffix attached to another checkpoint still fails closed.

The client-backed path is caller-composable without a helper task. After the effect-free authority snapshot, one DB
parent serially drives a bodyless HEAD, exact-generation frozen-header range, and same-generation bounded whole Get
for every manifest-named run. One moved caller-selected buffer supplies all read and publication bodies; one absolute
deadline and cancellation source cover the entire operation. Every loaded SST is revalidated against its exact
database, family, and descriptor before the effect-free successor builder runs. Public blocking adjacent `Compact` is a
literal wait on that operation and therefore shares its ownership, capacity, certainty, and result mapping.
Backend-neutral memory/files reads remain on the blocking storage port and create no helper task.
Neither public compaction form selects an automatic trigger, run, level, fanout, retry, or schedule policy. The
complete-view caller provides the complete family/output identity map; the adjacent caller provides the exact pair
and fresh output identity. Both provide stable successor manifest/transition identities.

`LSMPartialCompactionEquivalence.tla` now models the same abstract execution order: merge the selected consecutive
runs, transfer one finite suffix batch and its identity authority unchanged, reconstruct the successor run view, and
apply the suffix afterward. Its witness requires both read equivalence and retained identity authority; its negative
probe still demonstrates that dropping a selected tombstone is unsafe. The arbitrary-key/value TLAPS kernel proves
read equivalence with an arbitrary later suffix. It does not prove the Ada descriptor clone, protected-coordinator
snapshot, immutable manifest anchors, or ownership implementation.

Cacheless recovery from the compacted successor validates only its named outputs and exact manifest authority; it
does not reread depublicized predecessors to reconstruct current state. A missing, malformed, corrupt, misbound, or
unconfirmed compacted output fails closed and installs no local state. The formal finite model exercises definite
output-capacity rejection, ordinary and canonical-empty replacement, accepted-lost publication, depublication with
retained old bytes, missing-output rejection for a present output, crash, and exact recovery. Separate
machine-validated traces cover ordinary and zero-output recovery. The unbounded TLAPS kernel permits arbitrary fresh
output sets including empty and proves the corresponding abstract replacement invariants. No TLA+-to-Ada refinement
is claimed. Automatic selection and compaction policy remain separate API and policy units.

`LSMCompactionEquivalence.tla` separately closes the concrete point-read equation that the publication model leaves
abstract. For every finite captured view in its qualification geometry, the replacement run contains the exact live
value or no mutation for absence, never a tombstone. Cacheless application to an empty view reproduces every key,
and any later Put/Delete/no-mutation delta produces the same result whether applied before or after replacement. A
machine-validated trace exercises a live key, an absent key, a later Delete, and a later Put; a negative probe omits
one live key and must violate safety. `LSMCompactionEquivalenceSafetyProof.tla` proves the same reconstruction and
later-delta equations for arbitrary nonempty key and value sets. This is not a refinement proof for the Ada merge
loop, sequence selection, codecs, publication, or retention.

## Frozen immutable-object retention boundary

Physical deletion requires two independent authorities: explicit age eligibility and absence from the live protected
set. The protected set is the exact union of current HEAD reachability, active snapshot pins, lagging-replica pins,
predecessors still required for recovery or inspection, and every unresolved publication attempt. Listing discovers
stored identities but does not establish unreachability, age, or permission to delete. A deletion action rechecks the
live protected set rather than trusting a previously computed candidate list, and a deleted immutable identity is
never reused by later publication.

`ObjectRetention.tla` exhaustively checks two symmetric identities and uses a third in an exact witness that retains
an old object through current, snapshot, replica, and predecessor authority; retains new/orphan objects through
unknown outcomes; discards and reconstructs discovery evidence; and deletes only after all protections release. A
negative probe deletes the listed, aged current object and must violate safety. `ObjectRetentionSafetyProof.tla`
proves the action-preservation kernel over arbitrary object sets. The finite identities are qualification geometry.

This boundary does not choose the age horizon, clock/source metadata trust, replica lease protocol, predecessor-chain
cut, delete batch size, provider deletion-certainty mapping, progress, public API, or Ada synchronization mechanism.
Those choices require their own authority, crash tests, provider conformance evidence, and operational refinement.

## Non-goals

This design does not implement automatic flushing, identity generation, background scheduling, or run pruning,
garbage
collection, or an LSM performance claim. Its operational scope is manifest-v3 root creation, initial whole-state
runs, additive suffix-delta runs, public caller-selected complete-view replacement, private caller-selected
adjacent-run publication, certainty-preserving checkpoint publication/reconciliation, and header-first cacheless
recovery of every current run plus the later batch suffix. The complete-view operation is qualified across the
maintained remote-provider matrix without selecting provider, endpoint, retry, or scheduling policy.
