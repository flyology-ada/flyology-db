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

## First LSM checkpoint lane

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

The semantic format decision is staged in `docs/architecture/lsm-checkpoint-publication.md`: checkpoint publication
will use a future immutable manifest object version 2 plus a new SST object kind. Current manifest v1 remains
log-only, and this model/design unit does not make either future encoding decodable or operational.

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
TLAPS obligations. Larger state spaces belong to qualification campaigns and must not replace this fast per-change
gate.
