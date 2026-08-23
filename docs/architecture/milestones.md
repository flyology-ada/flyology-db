# Milestone plan and acceptance gates

Each milestone completes a focused develop, commit, independent review, fix/amend, and re-review loop. A milestone
is accepted only when its implementation, tests, proof, documentation, dependency provenance, and review record pass.

| Milestone | Acceptance gate | State |
| --- | --- | --- |
| 0 Foundation | Crate, guide, dependency clone/pin, architecture/format/oracle contracts, runners, provenance | Accepted at `8b9ff8c` |
| 1 Publication | Atomic absent/matching-generation writes, generation reads, reconciliation, provider fault tests | Local-provider review unit implemented; not yet accepted |
| 2 Log-only transactions | Create/open, stable families, pooled cross-family commits, remote recovery | Owned synchronous local-provider spine accepted at `c909c57`; remote gates pending |
| 3 MVCC/isolation | Snapshot and serializable validation, rollback, receipts, controlled concurrency | Pending |
| 4 Memtables/SST | Per-family memtables, validated format, lookup/scan, flush recovery | Pending |
| 5 Caching | Bounded metadata/RAM/disk caches, coalescing, corruption and complete-loss tests | Pending |
| 6 Compaction/retention | Conservative compaction, snapshot retention, atomic manifests, orphan GC | Pending |
| 7 Configuration | Persisted immutable/versioned/ephemeral family settings, TTL and codec gates | Pending |
| 8 Replicas/fencing | Monotonic refresh, catch-up, stale-writer rejection, explicit promotion | Pending |
| 9 Qualification | Full oracle/fault/performance matrices, proof and supported-platform evidence | Pending |

The current implementation unit is intentionally narrower than full Milestone 2 acceptance. It activates the
accepted manifest-v1 encoding through operational HEAD version 2 for provider-neutral memory/files backends. Public
Create requires an explicit root manifest identity, transition identity, database limits, and initial family table;
Open resolves handles by stable ID or exact name and validates manifest authority before replaying batches. HEAD-v1
images remain inspection-only and return `Unsupported_Format` operationally. Authenticated remote-provider
qualification and dynamic append-only family changes remain prerequisites for accepting Milestone 2. The accepted
owned-runtime closure is `c909c572`; the pooled TLA+ and manifest-publication
models remain abstract assurance lanes rather than a claimed refinement proof.

The first-LSM model/design unit adds a staged checkpoint-publication contract for Milestone 4, not an implementation
or acceptance claim. It chooses future manifest-v2 and SST object kinds, models bounded per-family L0 runs and exact
identity-ledger recovery, and leaves binary formats, Ada runtime work, scans, compaction, and provider qualification
to later focused units. Milestone 4 therefore remains Pending.

## Formal state-machine lane

TLA+ models single- and bounded pooled-transaction publication, ambiguous outcomes, fencing, cache loss, and recovery
before the corresponding production unit freezes. TLC exhausts a bounded state space and emits selected execution
witnesses. TLAPS proves an unbounded batch-atomic safety kernel. A checked scenario converter projects selected
witnesses into the normative NDJSON workload contract for replay against the Ada reference model, Flyology.DB, and
supported comparative oracles.
