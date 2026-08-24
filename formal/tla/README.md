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
HEAD transitions follow the ambiguous attempt. Their validator checks the exact pooled action paths, reachable-chain
conclusion, ordinal gap, retained unknown history, and receipts for both transactions. They prevent reconciliation
from silently regressing to exact-HEAD or immediate-successor matching.

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
proof kernel, workload projection, or future Ada implementation, so the gate does not claim one. In particular, the
TLAPS epoch property is monotonicity; stale-writer exclusion is checked by the executable model and is not attributed
to that proof-kernel property.

## Manifest registry lane

`ManifestPublication.tla` is a separate bounded two-manifest model for the additive manifest-v1 contract. It makes
ambiguous immutable-object publication explicit: an unknown Put must be confirmed as the exact stored manifest bytes
before any HEAD action is enabled. It then explores accepted and unaccepted lost HEAD responses. A committed witness
resolves the attempted root through a later reachable manifest; the action names say `ExternalStoreSuccessor` and
`ExternalPublishSuccessor` because the fenced unknown writer never continues publication. A failed witness resolves
an unaccepted attempt from a competing root at the attempted ordinal. Both paths discard all local state and recover
the exact registry named by HEAD, and `validate_manifest_witnesses.py` independently checks the critical action order
and final projection.

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
emit deterministic traces, and `validate_checkpoint_witnesses.py` checks their exact actions and final projections.
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
recovery path; `validate_successive_checkpoint_witness.py` checks its exact action sequence and final authority.

`SuccessiveCheckpointSafetyProof.tla` generalizes the same algorithm to arbitrary sets and any number of replacement
cycles. It proves ordering, exact checkpoint/suffix partitioning, exact recovery, and local-cache disposability. It
does not prove format bytes, manifest-depth arithmetic, provider behavior, capacities, or refinement to Ada.

`L0Accumulation.tla` freezes the next additive algorithm without claiming that its Ada implementation has landed.
The first run contains one value; the later delta run contains a tombstone for that key and a Put for a second key.
The successor manifest retains the first descriptor and appends the second under independent persisted family/global
run ceilings. Recovery applies their non-overlapping sequence ranges oldest to newest, so the newer tombstone masks
the old value. The model also covers definite pre-effect capacity rejection and accepted-lost HEAD resolution.
`L0AccumulationPartialProbe.tla` publishes the successor before its new run and manifest are confirmed and must fail.
`L0AccumulationRecoveryWitness.tla` plus `validate_l0_accumulation_witness.py` checks the exact lost-response,
resolution, crash, tombstone, retained-run, and recovery path.

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
violate that monitor. Three witness modules ask TLC for useful paths, and
`validate_snapshot_isolation_witnesses.py` independently checks their exact actions and final authority:

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
retention, both capacity rejections, valid commit, and conflict rejection. Four validators pin a serializable point
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
ordering, persisted sizing, allocation, the public Ada contract, progress, or refinement to production code.

## Witness projection

`CommitPublicationWitness.tla` adds a deliberate invariant violation that asks TLC for one useful path. The
retained path is not treated as proof. `witness_to_workload.py` first rejects any trace whose exact action sequence
and critical state snapshots do not match the intended scenario, then applies this scenario projection:

| TLA+ action | Workload observation |
| --- | --- |
| `PreparePooled` | begin two snapshot transactions and buffer three puts across two families |
| `StoreBatch`, `PublishHead`, `LoseAcceptedResponse` | both grouped commits return `Outcome_Unknown`, each with its own receipt |
| `ResolveCommitted` | both receipts resolve to `Success`; neither transaction is replayed |
| `Crash` | the outer runner kills the adapter and discards every local cache/staging artifact |
| `Recover` | reopen, read all three keys across both families, and assert the complete canonical state |

The checked-in result is `oracles/workloads/tla_commit_publication_witness.ndjson`. The formal gate regenerates
it from fresh TLC JSON, compares it byte-for-byte, and validates it with the normative workload validator.
Milestone 2 adds the actual replay runner; until then the witness is executable contract input, not implementation
evidence.

`L0Compaction.tla` starts from that exact two-run accumulated authority and freezes a complete replacement algorithm.
An admitted operation captures the complete live view and identity authority, stores and confirms one compacted run
and a successor manifest, and only then conditionally changes HEAD from the captured generation. The successor names
only the compacted run; the two superseded runs remain confirmed immutable stored history rather than current
authority. Zero-versus-one output capacity covers definite pre-effect rejection but is finite qualification geometry,
not a product default. Missing compacted output after a crash fails recovery closed.
`L0CompactionPartialProbe.tla` publishes HEAD immediately after planning and must violate safety.
`L0CompactionRecoveryWitness.tla` plus `validate_l0_compaction_witness.py` checks the exact admitted, accepted-lost,
read-only resolution, crash, and compacted-run-only recovery path.

`L0CompactionSafetyProof.tla` generalizes complete replacement to arbitrary nonempty fresh output sets and any number
of cycles. It proves stored-before-confirmed ordering, confirmed current authority, separation of fresh/current/
retired run sets, exact checkpoint/suffix authority, exact recovery, and disposable local state. It intentionally
retains retired objects and proves no physical garbage collection, concrete merge, snapshot-retention horizon,
format, capacity arithmetic, provider behavior, liveness, or refinement to Ada.

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
independently
validated 24-state witness covers snapshot, replica, predecessor, and unknown-attempt protection; release and exact
predecessor deletion; discovery loss/reconstruction; and resolved-orphan deletion while current authority survives.
`ObjectRetentionSafetyProof.tla` proves 15 action-preservation obligations over arbitrary object sets. It proves no
graph traversal, clock/source metadata trust, age threshold, replica lease protocol, provider delete certainty,
batching, progress, public API, or refinement to Ada.

## Reproduction

Install the pinned tools under ignored `.deps/tla` as recorded in
`docs/qualification/dependency-provenance.md`, provide Java 11 or newer, and run:

```sh
./scripts/check-tla.sh
```

The checked configuration uses one TLC worker for deterministic breadth-first witness selection. The exhaustive
gate must report 112,031 distinct states at depth 14, record a successful `PreparePooled` transition in coverage, and
strict TLAPS must prove 23 of 23 obligations. The manifest lane adds 286 distinct states at depth 10 and 12 of 12
strict TLAPS obligations. The first-checkpoint lane adds 819 distinct states at depth 19, three independently
validated witnesses, four required integrated negative probes, full normal-action coverage, and 43 of 43 strict
TLAPS obligations. The successive-checkpoint lane adds 37 distinct states at depth 17, one validated lost-response
recovery witness, one required early-HEAD negative probe, full semantic-action coverage, and 24 of 24 strict TLAPS
obligations. The additive-L0 lane adds 49 distinct states at depth 17, one validated tombstone/lost-response recovery
witness, one required early-HEAD negative probe, full semantic-action coverage, and 24 of 24 strict TLAPS obligations.
The L0-compaction lane adds 15 distinct states at depth 10, one validated lost-response recovery witness, one required
early-HEAD negative probe, full semantic-action coverage, and 26 of 26 strict TLAPS obligations.
The immutable-cache lane adds 623 distinct states at depth 12, one validated coalescing/loss/corruption witness, one
required stale-generation negative probe, full semantic-action coverage, and 13 of 13 strict TLAPS obligations.
The immutable-object retention lane adds 75,337 distinct states at depth 16, one validated protection/reclamation
witness, one required listing-only deletion probe, full semantic-action coverage, and 15 of 15 TLAPS obligations.
The snapshot-isolation lane
adds 336 distinct states at depth 10, three independently validated
witnesses, one required negative probe, full normal-action coverage, and 6 of 6 strict TLAPS obligations. The
fixed-snapshot read lane adds 7,530 states at depth 14, three validated witnesses, one negative probe, and 7 of 7
strict TLAPS obligations. The serializable lane adds 44,244 states at depth 13, four validated witnesses, one
negative probe, full semantic-action coverage, and 10 of 10 strict TLAPS obligations. Larger state spaces belong to
qualification campaigns and must not replace this fast per-change gate.
