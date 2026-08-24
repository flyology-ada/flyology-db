# Milestone plan and acceptance gates

Each milestone completes a focused develop, commit, independent review, fix/amend, and re-review loop. A milestone
is accepted only when its implementation, tests, proof, documentation, dependency provenance, and review record pass.

| Milestone | Acceptance gate | State |
| --- | --- | --- |
| 0 Foundation | Crate, guide, dependency clone/pin, architecture/format/oracle contracts, runners, provenance | Accepted at `8b9ff8c` |
| 1 Publication | Atomic absent/matching-generation writes, generation reads, reconciliation, provider fault tests | Local and authenticated-client paths implemented; remote matrix pending |
| 2 Log-only transactions | Create/open, stable families, pooled cross-family commits, remote recovery | Owned synchronous spine accepted at `c909c57`; authenticated binding added; remote matrix pending |
| 3 MVCC/isolation | Snapshot and serializable validation, rollback, receipts, controlled concurrency | Snapshot writes/point reads operational; serializable pending |
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
images remain inspection-only and return `Unsupported_Format` operationally. The authenticated client binding now
exercises create, commit, composable first-checkpoint Flush, and cacheless reopen through Object Storage scoped
operations. Remote-provider matrix qualification and dynamic append-only family changes remain prerequisites for
accepting Milestone 2. The accepted owned-runtime closure is `c909c572`; the pooled TLA+ and manifest-publication
models remain abstract assurance lanes rather than a claimed refinement proof.

Milestone 3 now has a formal-first and operational write/write validation boundary. A transaction captures the global
sequence at Begin and must prove every written key unchanged since that snapshot from retained exact history.
Transactions older than the checkpoint history boundary reject conservatively because compacted tombstones can erase
negative evidence. Atomic groups validate each member against external committed history and retain their existing
deterministic intra-group ordering. Fixed-snapshot point reads are operational: own Put/Delete wins, retained exact
history selects the newest committed version no later than Begin, and an exact lazily allocated checkpoint base
preserves compacted values after suffix replacement. The serializable point/range conflict and independent
backpressure rules are now frozen in a separate TLC/TLAPS lane, but their Ada API, persisted bounds, scan
normalization, and runtime tracking are not yet implemented, so Milestone 3 remains Pending.

The fixed-snapshot point-read rule is now separately model-checked and proved: read-your-writes precedes committed
history, committed lookup selects the newest version no later than Begin, and incomplete checkpoint history returns a
conservative too-old outcome. Production `Get` now implements that selection rule, mapping formal `TooOld` to the
existing public `Conflict` outcome without adding a new public enumeration or persisted field.

The formal serializable rule retains successful and absent point reads plus normalized range predicates only in
serializable mode. A commit rejects when a post-Begin committed write intersects its writes, retained points, or
retained ranges. Independent point/range capacity rejection is safety backpressure: reaching a bound never drops an
observation. The finite one-slot model values are qualification geometry rather than product defaults; production
capacities remain caller- or persisted-authority decisions.

The first-LSM work now includes exact/proven manifest-v2 and SST-v1 formats, dynamic operational codecs, manifest-v2
root creation, public synchronous first-checkpoint Flush/receipt reconciliation, live coordinator replacement, and
cacheless recovery of one complete nonempty checkpoint plus its strictly later batch suffix. Recovery restores live
values, last-write sequences, and the exact never-reused checkpoint identity ledger from persisted authority.
The additive DB-level `Flush_Operation` moves a caller-sized unique-buffer token through the same certainty contract
without a helper task. Multiple checkpoints, scans, compaction, and provider qualification remain later focused
units, so Milestone 4 remains Pending.

## Formal state-machine lane

TLA+ models single- and bounded pooled-transaction publication, ambiguous outcomes, fencing, cache loss, and recovery
before the corresponding production unit freezes. TLC exhausts a bounded state space and emits selected execution
witnesses. TLAPS proves an unbounded batch-atomic safety kernel. A checked scenario converter projects selected
witnesses into the normative NDJSON workload contract for replay against the Ada reference model, Flyology.DB, and
supported comparative oracles.
