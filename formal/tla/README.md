# TLA+ assurance lane

This directory specifies commit publication and recovery before the production engine implements them. It has
three related artifacts with deliberately different jobs.

`CommitPublication.tla` is the executable finite model. Two writers and two transactions can prepare either
one-transaction batches or one bounded two-transaction batch, race conditional HEAD publication, lose a response
before or after acceptance, reconcile receipts, acquire a new writer epoch, crash, discard all local state, and
recover the exact remote chain. Publishing a batch advances the global commit sequence by its transaction count;
visibility, immediate outcome, unknown history, and reconciliation change for every batch member in one action.
An unknown publication resolves committed whenever its immutable attempted batch is present anywhere in the
validated chain reachable from the current HEAD. It resolves failed only when that batch is absent from the
validated reachable chain and HEAD has reached or passed the attempted publication ordinal. This log-only rule uses
the retained chain and exact transition ordinals rather than opaque transition-value freshness; a recurring opaque
value therefore cannot change the conclusion.

`CommitPublication.cfg` asks TLC to exhaust the model under opaque-transition symmetry and check every safety
invariant. Transition identity is the pair of monotonic ordinal and opaque value: the model deliberately permits an
older opaque value to recur at a later ordinal, while prohibiting equality with the immediate predecessor. This
exercises the same anti-reuse defense as the persisted HEAD policy instead of assuming globally fresh opaque values.
`CommitPublicationStaleProbe.tla` deliberately applies the shared publication-history function after a writer has
become stale; the gate requires TLC to reject that negative probe through `NoStaleWriterPublication`. This keeps the
history monitor itself from becoming a vacuous green check.

The two descendant witness modules require committed and failed reconciliation traces in which two later valid
HEAD transitions follow the ambiguous attempt. The gate regenerates their canonical shared traces byte-for-byte,
including the exact pooled action paths, reachable-chain conclusion, ordinal gap, retained unknown history, and
receipts for both transactions. They prevent reconciliation from silently regressing to exact-HEAD or
immediate-successor matching.

`PublicationSafetyProof.tla` is an unbounded batch-atomic abstraction. Each abstract batch is assigned an arbitrary
nonempty transaction set, with pairwise-disjoint membership across distinct batches, and every action changes the
phase of that set through its batch identity. TLAPS proves initialization and action-by-action inductive preservation
for these properties:

- visible batches were published remotely;
- acknowledged batches, and therefore every transaction assigned to them, are wholly visible;
- visible publication epochs never exceed the current epoch;
- a batch that returned an unknown outcome can only resolve, so none of its transactions become active again; and
- local state is a discardable subset of remote state.

TLAPS also proves the separate transaction-level theorem that batch no-replay plus pairwise-disjoint ownership means
no transaction belonging to an ever-unknown batch can belong to an active batch. The executable model checks the
corresponding invariant in every state. `PublicationSafetyOverlapProbe.tla` deliberately assigns one transaction to
an unknown batch and a distinct active batch; the gate requires TLC to reject that overlapping-membership mutation.

The proof kernel intentionally omits sequence arithmetic, byte formats, conditional-write provider behavior,
linked-batch ordering, recovery traversal, and progress. SPARK covers executable format and policy code; provider
conformance tests cover storage atomicity. TLC checks the richer linked-chain model over its complete finite state
graph, including transaction-count sequence advancement, all-or-none recovery, and an explicit history flag that
would record any stale-writer publication. There is no machine-checked refinement theorem between the TLC model,
proof kernel, canonical trace projection, or Ada implementation, so the gate does not claim one. In particular, the
TLAPS epoch property is monotonicity; stale-writer exclusion is checked by the executable model and is not attributed
to that proof-kernel property.

## Manifest registry lane

`ManifestPublication.tla` is a separate bounded two-manifest model for the additive manifest-v1 contract. It makes
ambiguous immutable-object publication explicit: an unknown Put must be confirmed as the exact stored manifest bytes
before any HEAD action is enabled. It then explores accepted and unaccepted lost HEAD responses. A committed witness
resolves the attempted root through a later reachable manifest; the action names say `ExternalStoreSuccessor` and
`ExternalPublishSuccessor` because the fenced unknown writer never continues publication. A failed witness resolves
an unaccepted attempt from a competing root at the attempted ordinal. Both paths discard all local state and recover
the exact registry named by HEAD. The shared normalizer validates and byte-compares the deterministic action order
and final projection in both canonical trace artifacts.

The exhaustive manifest model checks stored/confirmed ordering, predecessor storage, immutable existing family
configuration, sound committed/failed reconciliation, and cacheless recovery snapshots. The deliberately invalid
`ManifestRegistryMutationProbe.tla` changes an existing configuration and must violate monotonicity.
`ManifestSafetyProof.tla` is a smaller unbounded inductive kernel over arbitrary manifest, family, and configuration
sets. TLAPS proves stored-before-confirmed/HEAD, predecessor storage, append-only configuration, and disposable local
cache state. It intentionally omits byte encoding, UTF-8, ordinals, liveness, provider behavior, and any refinement
theorem to the Ada codec or future engine.

## LSM checkpoint lanes

`CheckpointPublication.tla` is a separate finite model for the staged first-checkpoint protocol. Two committed
transactions span two families. The flush stores and confirms one complete sorted L0 run per family, stores and
confirms an immutable future manifest-v2 snapshot, and conditionally publishes it from one exact expected HEAD
identity. Its manifest preserves the family registry and explicit per-family key/value, memtable byte/entry, and L0
run policies. Separate scenarios exercise per-family/aggregate run backpressure and exact identity-ledger capacity.

Each confirmed manifest maps runs by family. The safety predicate checks that every confirmed run contains only its
declared family's transactions, every named run belongs to the map family, and each family's named runs reconstruct
exactly its checkpoint prefix. The manifest ledger is exact, including the admitted-but-nonvisible identity; it may
neither drop that identity nor invent a later one. Recovery also proves no preboundary identity enters the replay
partition.

The model distinguishes accepted-response loss from an unaccepted ambiguous HEAD call. A fenced unknown writer never
continues; a named external/later writer may publish a successor. Recovery discards all local state, starts from HEAD,
loads every named run and the exact admitted-identity ledger through the replay boundary, then replays only later
batches. Missing or corrupt named runs reject recovery. The `committed`, `rejected`, and `recovery` witness modules
emit deterministic traces. The shared normalizer validates and byte-compares their exact actions and final
projections.
The stale-publication, partial-run, wrong-family, and wrong-ledger probes extend the full checkpoint machine. Each
adds one deliberately unsafe action excluded from normal `Next` and reaches it through a valid prefix. They must
violate their respective invariants. The gate also requires nonzero TLC coverage for every normal action, including
all three capacity branches, external advance, missing/corrupt-run rejection, publication, reconciliation, crash,
and recovery.

`CheckpointSafetyProof.tla` is a deliberately smaller unbounded kernel. Its arbitrary sets abstract confirmed run and
manifest bytes, current checkpoint state/identity authority, and the disjoint later replay partition. TLAPS proves 43
obligations covering stored-before-confirmed ordering, confirmed HEAD references, immutable registry, exact expected
generation publication, exact/no-overlap authority partition, exact recovery, and disposable local cache state. It
does not prove per-family reconstruction, sorting/completeness/corruption checks, capacity arithmetic, response
reconciliation, byte formats, or refinement to a future Ada implementation. Those concrete behaviors remain in the
exhaustive TLC lane or future format/implementation gates.

The semantic decision in `docs/architecture/lsm-checkpoint-publication.md` now has exact persisted formats: current
immutable manifest version 3, readable predecessor version 2, and SST kind 4/version 1 have frozen bytes, goldens,
corruption tests, and bounded SPARK coverage for the current codec. Operational Create/Flush/recovery use the same
dynamically allocated format state machine. No refinement theorem connects these bytes to this TLA+ model; its
historical first-checkpoint witness still names the version-2 shape whose LSM payload v3 preserves unchanged.

`SuccessiveCheckpointPublication.tla` is a focused second-checkpoint model rather than an expansion of the pinned
first-checkpoint state graph. One transaction is captured by the first complete run, a later transaction remains in
the replay suffix, and a second complete run replaces current checkpoint authority. The finite two-versus-three
manifest-history choice exists only to cover persisted-history backpressure; it is not a product default. The model
also covers an accepted lost second-HEAD response, exact resolution, crash/recovery, and retention of old immutable
bytes outside current visibility. `SuccessiveCheckpointPartialProbe.tla` deliberately publishes the second HEAD
before confirming its new run and manifest and must violate the normal safety predicate.
`SuccessiveCheckpointRecoveryWitness.tla` selects the accepted-lost response, read-only resolution, crash, and
recovery path; the shared canonical trace comparison checks its exact action sequence and final authority.

`SuccessiveCheckpointSafetyProof.tla` generalizes the same algorithm to arbitrary sets and any number of replacement
cycles. It proves ordering, exact checkpoint/suffix partitioning, exact recovery, and local-cache disposability. It
does not prove format bytes, manifest-depth arithmetic, provider behavior, capacities, or refinement to Ada.

`L0CheckpointSelection.tla` freezes the policy-neutral observation that maps persisted per-family and database-wide
L0 run ceilings to no work, additive flush, complete compaction, or no admissible action. The two-family,
zero-to-two-run, one-to-three-slot geometry is finite qualification coverage rather than a product limit. Observation
does not reserve an object identity, mutate checkpoint authority, or schedule work. Four canonical witnesses cover
no work, additive Flush, complete compaction, and no admissible action. The shared Ada replay adapter calls the real
private checkpoint policy for each input and requires its outcome and selected family set to match the model. A
deliberately buggy adapter must diverge on complete compaction with a stable shared result fingerprint. The model
projects changed families for additive Flush, nonempty families for complete compaction, and an empty set otherwise.
`L0CheckpointSelectionSafetyProof.tla` proves the four decision and four family-projection branches directly; it does
not establish liveness, operational Ada refinement, or atomicity between this observation and a later caller-selected
Flush or Compact.

`L0Accumulation.tla` freezes the next additive algorithm without claiming that its Ada implementation has landed.
The first run contains one value; the later delta run contains a tombstone for that key and a Put for a second key.
The successor manifest retains the first descriptor and appends the second under independent persisted family/global
run ceilings. Recovery applies their non-overlapping sequence ranges oldest to newest, so the newer tombstone masks
the old value. The model also covers definite pre-effect capacity rejection and accepted-lost HEAD resolution.
`L0AccumulationPartialProbe.tla` publishes the successor before its new run and manifest are confirmed and must fail.
The canonical `L0AccumulationRecoveryWitness` trace fixes the exact lost-response, resolution, crash, tombstone,
retained-run, and recovery path.

`L0AccumulationSafetyProof.tla` generalizes additive publication to arbitrary transaction, identity, manifest, and
run sets over any number of cycles. It proves that current run authority names only confirmed immutable bytes, each
publication appends its prepared run without rewriting earlier stored runs, checkpoint/suffix authority remains
exact, and cacheless recovery restores it. Concrete key/value merge, run ordering, bounds, formats, liveness, and
refinement to Ada remain outside the unbounded kernel.

## Snapshot-isolation validation lane

`SnapshotIsolation.tla` freezes the first production write/write validation rule over two transactions and two keys.
Each transaction captures the global sequence once at `Begin`. Commit succeeds only when every key in its buffered
write set has a last-write sequence no later than that fixed snapshot and the snapshot is not older than the retained
exact-history boundary. A checkpoint may advance that boundary while transactions remain active. An older transaction
is then rejected conservatively, even for a disjoint key, because a compacted tombstone may no longer be available to
prove the absence of a post-snapshot write. This is deliberate safety backpressure, not a global transaction lock.

TLC exhausts the finite state graph and checks type/sequence authority plus the explicit no-invalid-commit monitor.
`SnapshotIsolationUnsafeCommitProbe.tla` adds the forbidden transition that commits despite failed validation and must
violate that monitor. Three witness modules ask TLC for useful paths, and their canonical shared traces fix the exact
actions and final authority:

- two same-snapshot writers of the same key produce one commit and one conflict;
- two same-snapshot writers of disjoint keys both commit; and
- a transaction older than a checkpoint boundary is conservatively rejected although its key is disjoint.

`SnapshotIsolationSafetyProof.tla` is the corresponding unbounded inductive kernel over arbitrary nonempty transaction
and key sets. TLAPS proves initialization and preservation by Begin, buffering, valid commit, conflict rejection, and
checkpoint. It proves only that the state types and sequence bounds remain sound and that the modeled valid-commit
action never records an invalid commit. It does not prove retention sufficiency, reads, serializable predicates,
grouped commits, byte-key equality, progress, or refinement to Ada. The witness traces are checked design examples,
not proof or executable-refinement evidence.

## Fixed-snapshot point-read lane

`SnapshotReads.tla` freezes the next point-read rule independently from write admission. A transaction reads its own
buffered Put/Delete first. Otherwise it selects the newest committed value no later than its fixed Begin sequence. If
that sequence predates the retained checkpoint boundary, the read reports `TooOld`; it never substitutes the latest
value when exact evidence is incomplete. The two transactions, two values, and two committed-version slots are finite
qualification geometry complete for this model, not product limits or a proposed retention representation.

TLC exhausts 7,530 states at depth 14 and requires nonzero coverage for Begin, Put/Delete buffering, commit, read, and
checkpoint. Three independently checked traces pin an old committed value that survives a later Put, a buffered Put
that wins over later committed state, and conservative `TooOld` after checkpoint advancement. The negative model reads the
latest value despite a different expected result and must trip the explicit bad-read monitor. The unbounded TLAPS
kernel proves seven inductive obligations over arbitrary nonempty transaction and value sets. It proves type/sequence
soundness and exact selection by the modeled read action; it does not prove byte lookup, retained-history sufficiency,
allocation/ownership, serializable predicates, progress, or refinement to Ada.

## Serializable-validation lane

`SerializableValidation.tla` freezes the conflict rule before any public Ada isolation or range API is selected.
Snapshot transactions retain neither point nor range observations and reject only writes changed after Begin.
Serializable transactions retain successful and absent point observations plus normalized range predicates, then
reject if a later committed write intersects their write set, a retained point, or any member of a retained range.
Point and range retention have independent capacity rejection paths; no observation is silently dropped at capacity.
This focused model assumes exact post-snapshot write authority; the separate snapshot-isolation model owns
conservative rejection below the retained checkpoint-history boundary.

The finite model uses two transactions, two keys, two ranges, and one retained point/range slot. Those values are
qualification geometry: one slot admits an observation and the second distinct observation reaches backpressure.
They are not public defaults, persisted values, byte-order policy, or proposed product capacities. A modeled key is
an exact (column family, byte key) identity; `R1` contains one identity and `R2` both identities solely to exercise
same-family point and phantom conflicts. Manifest v3 now supplies caller-selected persisted count authority; the Ada
isolation/range API and runtime allocation remain separate pending decisions.

TLC exhausts 44,244 states at depth 13 and requires nonzero coverage for Begin, write buffering, point/range
retention, both capacity rejections, valid commit, and conflict rejection. Four canonical shared traces pin a serializable point
conflict, a serializable range conflict, a snapshot transaction that observes the same point without retaining it,
and a serializable read of its own write after the point set is full. Own writes bypass point retention and capacity,
matching read-your-writes precedence. The negative model commits through an existing serializable point conflict and
must trip the invalid-commit monitor.

`SerializableValidationSafetyProof.tla` is an unbounded action-preservation kernel over arbitrary nonempty
transaction, key, and range sets and arbitrary positive capacities. TLAPS proves ten obligations covering
initialization and every modeled action. It proves type/sequence soundness and that the guarded commit action cannot
record an invalid commit. The kernel deliberately excludes finite-cardinality inequalities because TLAPS's recursive
`FiniteSets.Cardinality` definition is outside this focused SMT proof. TLC checks those capacity invariants and both
backpressure actions exhaustively. Neither lane proves retained-history sufficiency, range normalization, byte-key
ordering, persisted sizing, allocation, the public Ada contract, progress, or refinement to production code. The
separate range-normalization lane below now owns the previously excluded normalization rule.

## Scan-range normalization lane

`RangeNormalization.tla` freezes the transaction-owned normalization algorithm independently from the serializable
conflict model. Ranges are half-open. Same-family predicates coalesce when they overlap or when one upper endpoint
equals the other's lower endpoint; a bridge coalesces every connected component in one atomic replacement.
Equal-byte predicates in different families remain distinct. An admissible merge is allowed while the retained set
is already at capacity because it does not add a normalized component. Only a disjoint component that would exceed
the persisted count is rejected. Modeled allocation rejection and capacity rejection preserve both the exact
retained set and its logical covered-key union.

The finite geometry uses two families, four key positions, and capacity two solely to expose separated components,
transitive bridging, family separation, full-capacity merging, and a third-component rejection. TLC exhausts 3,419
states at depth 4 with nonzero coverage for successful recording and both rejection actions. The checked eight-state
witness records two separated ranges, bridges them, retains the same byte interval independently in another family,
rejects a third component, extends the first family while full, and rejects an allocation without effects. The
negative probe merges only one side of a bridge and must violate pairwise normalization.

`RangeNormalizationSafetyProof.tla` is an unbounded action-preservation kernel over arbitrary range and qualified-key
universes. TLAPS proves 19 obligations showing that publication of a pure normalized result preserves exact coverage,
normalization, and capacity, while capacity and allocation rejection are atomic. Its abstract `RangeCount` avoids
attributing recursive finite-cardinality reasoning to the SMT proof. The pure-normalizer contract is an explicit
proof boundary: concrete endpoint ordering is checked by TLC, not derived by TLAPS. Neither lane proves byte storage,
allocation implementation, list ownership, concurrency, progress, or refinement to production Ada.

## Fixed-snapshot paged-scan lane

`PagedScan.tla` freezes caller-bounded page selection before the additive Ada cursor is implemented. Every successful
page is the maximal next contiguous prefix from one captured logical view that fits both an explicit row budget and
an explicit combined key-plus-value byte budget. Tombstones mask older values. Later replacement, resurrection, and
deletion in current authority cannot alter the captured rows. When rows remain but the next indivisible row does not
fit, capacity rejection preserves the exact cursor and prior page; modeled allocation rejection has the same atomic
boundary. A valid range with no visible rows succeeds with an empty final page and records the predicate.

The finite model's four ordered one-byte keys, three value extents, zero-to-two row budgets, and zero-to-five byte
budgets are qualification geometry only. They are not key/value limits, persisted fields, page defaults, or retention
policy. TLC exhausts 341 distinct states at depth 6 with nonzero coverage for Begin, concurrent authority change,
ordinary page publication, empty-view completion, capacity rejection, and allocation rejection. The skipped-key
and nonmaximal-page negative probes must each violate `Safety`. The canonical eight-state trace records
the frozen first row, changes current authority, observes both atomic rejection paths, and then emits the original
remaining rows exactly.

`PagedScanSafetyProof.tla` is an unbounded action-preservation kernel over an arbitrary frozen row sequence and
arbitrary nonempty budget set. Its explicit `PageFor` boundary requires every selected page to be the exact next
prefix. TLAPS proves 24 obligations for initialization, successful nonempty publication, successful empty completion,
capacity rejection, allocation rejection, and quiescence. The kernel does not prove maximal-prefix arithmetic,
tombstone semantics, endpoint comparison, allocation, transaction-local mutation stability, progress, concurrency,
the public Ada contract, or refinement. TLC owns the first two finite rules; the remaining operational boundaries
must be covered by the Ada implementation and deterministic tests.

## Generation-bound lazy-SST-read lane

`LazySSTRead.tla` freezes the certainty and publication boundary for one independently authenticated SST-v2 entry.
`Begin` abstracts a successful HeadObject authority observation followed by a generation-bound header range. The
index and selected entry frame must use that exact generation, and the frame must match the key and value
authenticated by the index before output changes. Allocation, stale-generation, and corruption rejection preserve
the prior output. A provider replacement after the frame is owned does not alter the captured bytes. The finite
model's two keys, two generations, and four values are qualification geometry, not format extents, key/value limits,
cache capacity, request policy, or public defaults.

TLC exhausts 16 distinct states at depth 6 with nonzero coverage for capture, provider replacement, index/frame
authentication, success, allocation rejection, both stale-generation rejections, and both corruption rejections.
The stale-generation probe publishes the current generation under an older captured header, while the frame-swap
probe authenticates another key's frame; both must violate `Safety`. The canonical seven-state trace
rejects one allocation, authenticates the exact frame, replaces provider authority, and still publishes only the
owned older-generation value.

`LazySSTReadSafetyProof.tla` is an action-preservation kernel over arbitrary nonempty generation, key, and value sets.
TLAPS proves 41 obligations for type and request binding, exact generation and frame binding, prepublication and
failure atomicity, exact successful output, and quiescence. The model proves no CRC or byte-range arithmetic, codec,
allocation implementation, provider behavior, progress, public API, or refinement to Ada. Those remain codec and
executable qualification boundaries documented in `docs/architecture/lazy-sst-reads.md`.

`LazySSTNextEntry.tla` freezes selection of one next snapshot-visible entry
inside a canonical SST. Its three-entry geometry contains `a@2=value`,
`a@1=tombstone`, and `b@2=value`; TLC therefore exercises newest selection,
historical tombstone fallback, strict/inclusive starts, the exclusive upper
bound, one selected frame, complete absence, and failure atomicity. The
skipped-first negative probe must violate `Safety`. The canonical witness
selects `a@1` under snapshot 1 and `[a,b)`, authenticates that frame, and
publishes NotFound from the tombstone.

`LazySSTNextEntrySafetyProof.tla` is the arbitrary-domain action-preservation
kernel. It assumes the finite model's already-established `ExpectedPosition`
function and proves exact request, selected-position, frame-position, terminal
output, and failure-atomicity preservation. Neither model proves byte ordering,
CRC/format parsing, provider behavior, allocation, progress, Ada execution,
refinement, or constant-memory paging.

`LazyCheckpointRead.tla` composes the one-run result across one exact
oldest-to-newest run slice at a fixed snapshot. TLC exhausts 37 distinct states
at depth 6 with nonzero coverage for future-run skipping, authenticated
absence fall-through, value publication, tombstone masking, complete absence,
and child failure. The three runs, two keys, and four values are qualification
geometry, not a run ceiling, key/value limit, request budget, retry policy, or
public default.

`LazyCheckpointReadSafetyProof.tla` proves 13 obligations for initialization,
cursor advance, exact terminal value/not-found publication, failure atomicity,
request binding, and quiescence over arbitrary snapshot, key, value, and exact
run-count domains. Its abstract `Expected` function assumes the finite model's
newest-visible selection result; neither artifact proves SST authentication,
allocation, provider behavior, progress, Ada execution, or refinement.

## Shared witness contract

Every maintained witness `ALIAS` projects into the shared harness shape from `FlyologyHarness.tla`: action, role,
input, expected outcome, expected state, and model-source coordinates. TLC still chooses the path by reaching the
witness invariant violation. `flyology-tla trace normalize` converts that raw TLC JSON into the canonical
`flyology.tla.trace` schema, the strict shared decoder validates it, and the gate compares it byte-for-byte with the
checked-in artifact under `formal/tla/traces/`.

The canonical traces are deterministic design evidence, not proof or automatic implementation refinement. The L0
checkpoint-selection lane additionally uses `Flyology_TLA.Replay` against the actual Ada policy, checks trace/result
SHA identity, and requires both conformant positive results and one intentional negative divergence. Other lanes
retain their TLC exploration, negative probes, action coverage, and TLAPS proofs without duplicating the shared
trace codec or reporting machinery.

`L0Compaction.tla` starts from that exact two-run accumulated authority and freezes a complete replacement algorithm.
An admitted operation captures the complete live view and identity authority. A live view stores and confirms one
compacted run; an all-absent view confirms the canonical empty output set without consuming output capacity or
creating a synthetic SST. Both branches store and confirm a successor manifest before conditionally changing HEAD
from the captured generation. The successor names only the new output set; the two superseded runs remain confirmed
immutable stored history rather than current authority. Zero-versus-one output capacity is finite qualification
geometry, not a product default. Missing present compacted output after a crash fails recovery closed.
`L0CompactionPartialProbe.tla` publishes HEAD immediately after planning and must violate safety.
The canonical `L0CompactionRecoveryWitness` trace fixes the exact admitted, accepted-lost, read-only resolution,
crash, and compacted-run-only recovery path.
The canonical `L0CompactionEmptyRecoveryWitness` trace fixes the corresponding zero-capacity, no-SST, empty-run
manifest path while preserving exact admitted identities across accepted-lost resolution and recovery.

`L0CompactionSafetyProof.tla` generalizes complete replacement to arbitrary fresh output sets, including empty, and
any number of cycles. It proves stored-before-confirmed ordering, confirmed current authority, separation of
fresh/current/retired run sets, exact checkpoint/suffix authority, exact recovery, and disposable local state. It
intentionally retains retired objects and proves no physical garbage collection, snapshot-retention horizon, format,
capacity arithmetic, provider behavior, liveness, or refinement to Ada.

`LSMCompactionEquivalence.tla` isolates concrete point-read semantics from publication. TLC explores all 576 states
formed by every two-key/two-value captured view and every later Put/Delete/no-mutation map. A complete replacement
emits a Put for a live key and no mutation for an absent key, cacheless recovery must equal the capture, and applying
the later delta must be observationally identical on every key. `LSMCompactionEquivalenceProbe.tla` omits one live
key and must violate safety. The canonical `LSMCompactionEquivalenceWitness` trace fixes the captured-live/absent,
replacement, recovery, later-Delete/later-Put path as executable evidence.

`LSMCompactionEquivalenceSafetyProof.tla` proves six strict obligations over arbitrary nonempty key and value sets:
replacement contains no tombstone, absence emits no entry, live values emit exact Puts, recovery reconstructs the
view, and any later delta remains equivalent. Sequence selection, operational Ada refinement, formats, allocation,
publication, retention, and progress remain in their separate lanes.

`LSMPartialCompactionEquivalence.tla` freezes the distinct read rule for a partial merge. Two selected consecutive
runs sit between one retained older and one retained newer run. The merger keeps the newest selected mutation per
key; unlike complete live-state replacement, that mutation can be a tombstone because an older retained value may
still need masking. A post-checkpoint log suffix is transferred unchanged, including its transaction-identity
authority, and is replayed after the merged SST view. TLC exhausts 3,145,728 distinct states at depth 3 across all
two-key/two-value run and suffix mutations and checks exact pre/post recovery equality plus suffix authority
transfer. `LSMPartialCompactionEquivalenceProbe.tla` transfers the suffix correctly but drops a selected tombstone
and must violate safety. The canonical `LSMPartialCompactionEquivalenceWitness` trace fixes a concrete
retained-older, selected-pair, retained-newer, and later-suffix path.

`LSMPartialCompactionEquivalenceSafetyProof.tla` proves five strict obligations over arbitrary nonempty key and value
sets: newest selected mutation retention, selected tombstone retention, single-key mutation composition, whole-view
selected-run equivalence, and equality after any suffix over retained older/newer runs. The lane chooses no
run-selection condition, trigger, fanout, level size, schedule, resource capacity, publication protocol, or public
API. It also claims no refinement to an operational Ada partial merger.

`LSMThreeRunCompactionEquivalence.tla` qualifies associative composition across exactly three caller-selected
consecutive runs without turning three into a compaction fanout or trigger. TLC exhausts 12,288 distinct states at
depth 3 for one key and two values, including retained older/newer runs and a post-checkpoint suffix. It checks that
the merged run keeps the newest selected mutation, that a middle tombstone survives when the last run has no
mutation for that key, and that suffix bytes and transaction-identity authority transfer unchanged.
`LSMThreeRunCompactionEquivalenceProbe.tla` drops that middle tombstone and must violate safety.
The canonical `LSMThreeRunCompactionEquivalenceWitness` trace records the concrete first-Put, middle-Delete,
last-empty, suffix-Put execution path.

`LSMThreeRunCompactionEquivalenceSafetyProof.tla` proves seven strict obligations over arbitrary nonempty key and
value sets: mutation associativity, last and middle mutation retention, middle tombstone retention, point-value and
whole-view composition, and full equality with retained older/newer runs and any suffix. The fixed three-run slice
is qualification geometry only. Selection, trigger, fanout, levels, allocation, publication, retention, progress,
and Ada refinement remain separate.

## Immutable cache lane

`ImmutableCache.tla` freezes the safety boundary for a disposable cache of verified immutable objects. Each read
captures an exact generation before consulting local state. Cache entries, one coalesced fetch owner, explicitly
joined waiters, and completed results all retain that generation; a later authority advance therefore cannot turn an
older entry into a hit for a newer request. Corrupt entries are removed without returning bytes, and complete local
loss clears cache and fetch state while preserving remote authority and pending exact-generation requests. The
finite model's two entries, two readers, and zero-versus-one capacity are qualification geometry, not database
defaults or persisted resource policy.

TLC exhausts 623 distinct states at depth 12 with nonzero coverage for every semantic action. The deliberately
unsafe stale-generation probe returns the old entry to a new-generation request and must violate `Safety`. The
machine-validated 20-state witness fixes one coalesced fetch, an authority advance, an interrupted/refetched request,
corruption rejection, and exact final recovery. `ImmutableCacheSafetyProof.tla` proves 13 action-preservation
obligations over arbitrary entry and reader sets; its fetch set represents at most one owner per exact generation.
This lane proves no concrete capacity, allocation behavior, eviction order, disk format, checksum algorithm,
progress, public API, or refinement to Ada.

## Immutable-object retention lane

`ObjectRetention.tla` freezes physical-deletion safety without selecting a retention policy. Current authority,
active snapshots, lagging replicas, required predecessors, and unresolved publication attempts each protect exact
immutable identities. Listing and an explicit age decision nominate candidates, but deletion rechecks the live union
of protections and deleted identities cannot be reused. The exhaustive graph uses two symmetric identities; the
exact witness adds a third orphan identity solely to distinguish predecessor reclamation from an unresolved orphan.
These values are qualification geometry, not an age horizon or delete batch size.

TLC exhausts 75,337 distinct states at depth 16 with nonzero coverage for every semantic action. The listing-only
negative probe deletes the current reachability set after listing and age marking and must violate `Safety`. The
canonical 24-state trace covers snapshot, replica, predecessor, and unknown-attempt protection; release and exact
predecessor deletion; discovery loss/reconstruction; and resolved-orphan deletion while current authority survives.
`ObjectRetentionSafetyProof.tla` proves 15 action-preservation obligations over arbitrary object sets. It proves no
graph traversal, clock/source metadata trust, age threshold, replica lease protocol, provider delete certainty,
batching, progress, public API, or refinement to Ada.

## Replica refresh and fencing lane

`ReplicaRefresh.tla` freezes monotonic read-only catch-up and exact writer fencing. A refresh captures a confirmed
HEAD ordinal/epoch pair, may finish after authority advances, and installs only at or above its replica high-water
pair. A writer publishes only when both its captured ordinal and epoch still equal HEAD. TLC exhausts 1,460 states at
depth 15; stale-writer and rollback probes must violate safety, and a canonical 16-state trace covers fencing,
replacement writer publication, lagging installation, and catch-up. The bounds two and one are qualification
geometry. `ReplicaRefreshSafetyProof.tla` proves 11 obligations over arbitrary natural ordinals/epochs. Immutable
graph validation, transport certainty, polling, leases, promotion, progress, and Ada refinement remain outside.

## Reproduction

Install `flyology_tla=0.1.0-dev` from the configured Flyology Alire index and provision its verified toolchain under
dedicated ignored prefixes, then run:

```sh
./scripts/setup-tla.sh
./scripts/check-tla.sh
```

After an intentional model, configuration, or toolchain-identity change, regenerate the checked artifacts with
`FLYOLOGY_DB_TLA_UPDATE_TRACES=1 ./scripts/check-tla.sh`, inspect the trace diff, and rerun the ordinary command to
prove byte-stable reproduction.

The checked configuration uses one TLC worker for deterministic breadth-first witness selection. The exhaustive
gate must report 112,031 distinct states at depth 14, record a successful `PreparePooled` transition in coverage, and
strict TLAPS must prove 23 of 23 obligations. The manifest lane adds 286 distinct states at depth 10 and 12 of 12
strict TLAPS obligations. The first-checkpoint lane adds 819 distinct states at depth 19, three canonical traces,
four required integrated negative probes, full normal-action coverage, and 43 of 43 strict TLAPS obligations. The
successive-checkpoint lane adds 37 distinct states at depth 17, one canonical lost-response recovery trace, one
required early-HEAD negative probe, full semantic-action coverage, and 24 of 24 strict TLAPS
obligations. The L0 checkpoint-selection lane adds 2,240 distinct states at depth 2, nonzero coverage of all four
decisions, four canonical witnesses, four successful Ada replays, one required implementation-divergence probe, and
8 of 8 strict TLAPS obligations. The additive-L0 lane adds
49 distinct states at depth 17, one canonical tombstone/lost-response recovery trace, one required early-HEAD
negative probe, full semantic-action coverage, and 24 of 24 strict TLAPS obligations.
The L0-compaction lane adds 35 distinct states at depth 10, canonical ordinary and empty-output lost-response
recovery traces, one required early-HEAD negative probe, full semantic-action coverage, and 26 of 26 strict TLAPS
obligations.
The immutable-cache lane adds 623 distinct states at depth 12, one canonical coalescing/loss/corruption trace, one
required stale-generation negative probe, full semantic-action coverage, and 13 of 13 strict TLAPS obligations.
The immutable-object retention lane adds 75,337 distinct states at depth 16, one canonical protection/reclamation
trace, one required listing-only deletion probe, full semantic-action coverage, and 15 of 15 TLAPS obligations.
The replica lane adds 1,460 distinct states at depth 15, one canonical fencing/catch-up trace, two required negative
probes, full semantic-action coverage, and 11 of 11 TLAPS obligations.
The snapshot-isolation lane
adds 336 distinct states at depth 10, three canonical traces, one required negative probe, full normal-action
coverage, and 6 of 6 strict TLAPS obligations. The fixed-snapshot read lane adds 7,530 states at depth 14, three
canonical traces, one negative probe, and 7 of 7 strict TLAPS obligations. The serializable lane adds 44,244 states
at depth 13, four canonical traces, one
negative probe, full semantic-action coverage, and 10 of 10 strict TLAPS obligations. Larger state spaces belong to
qualification campaigns and must not replace this fast per-change gate.
The range-normalization lane adds 3,419 states at depth 4, one canonical bridge/cross-family/rollback trace, one
negative probe, and 19 of 19 strict TLAPS obligations. The paged-scan lane adds 341 states at depth 6, one canonical
fixed-view/backpressure trace, skipped-key and nonmaximal-page negative probes, full semantic-action coverage, and
24 of 24 strict TLAPS obligations.
The lazy-SST-read lane adds 16 states at depth 6, one canonical allocation/replacement trace, stale-generation and
frame-swap negative probes, full semantic-action coverage, and 41 of 41 strict TLAPS obligations.
