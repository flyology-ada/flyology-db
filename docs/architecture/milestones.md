# Milestone plan and acceptance gates

Each milestone completes a focused develop, commit, independent review, fix/amend, and re-review loop. A milestone
is accepted only when its implementation, tests, proof, documentation, dependency provenance, and review record pass.

| Milestone | Acceptance gate | State |
| --- | --- | --- |
| 0 Foundation | Crate, guide, dependency clone/pin, architecture/format/oracle contracts, runners, provenance | Accepted at `8b9ff8c` |
| 1 Publication | Atomic absent/matching-generation writes, generation reads, reconciliation, provider fault tests | Local and authenticated-client paths implemented; remote matrix pending |
| 2 Log-only transactions | Create/open, stable families, pooled cross-family commits, remote recovery | Owned synchronous spine accepted at `c909c57`; authenticated binding added; remote matrix pending |
| 3 MVCC/isolation | Snapshot and serializable validation, rollback, receipts, controlled concurrency | Snapshot plus serializable point/range-predicate validation operational; broader acceptance pending |
| 4 Memtables/SST | Per-family memtables, validated format, lookup/scan, flush recovery | Additive L0 and private sync/composable replacement operational; replacement reads proved; public compaction pending |
| 5 Caching | Bounded metadata/RAM/disk caches, coalescing, corruption and complete-loss tests | Exact-generation/coalescing safety boundary proved; operational caches and capacity policy pending |
| 6 Compaction/retention | Conservative compaction, snapshot retention, atomic manifests, orphan GC | Private sync/composable replacement operational and deletion safety proved; public API/collector policy pending |
| 7 Configuration | Persisted immutable/versioned/ephemeral family settings, TTL and codec gates | Pending |
| 8 Replicas/fencing | Monotonic refresh, catch-up, stale-writer rejection, explicit promotion | Private one-shot refresh operational; public/composable replica and promotion policy pending |
| 9 Qualification | Full oracle/fault/performance matrices, proof and supported-platform evidence | Pending |

The current implementation unit is intentionally narrower than full Milestone 2 acceptance. It activates the
accepted manifest-v1 encoding through operational HEAD version 2 for provider-neutral memory/files backends. Public
Create requires an explicit root manifest identity, transition identity, database limits, and initial family table;
Open resolves handles by stable ID or exact name and validates manifest authority before replaying batches. HEAD-v1
images remain inspection-only and return `Unsupported_Format` operationally. The authenticated client binding now
exercises create, commit, composable checkpoint Flush, and cacheless reopen through Object Storage scoped
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
backpressure rules are frozen in a separate TLC/TLAPS lane. Manifest v3 persists caller-selected independent
point/range counts. The additive public isolation overload now makes Serializable explicit, and production `Get`
lazily retains distinct present/absent external points under the persisted count. Admission and prepublication
validation cover singleton and grouped commits; snapshot callers and own-write reads retain their prior behavior.
Public `Observe_Range` now validates a canonical half-open predicate without reading rows. A false endpoint flag is
unbounded and ignores its byte argument; a present endpoint is bounded by its selected family. Serializable calls
retain exact distinct predicates lazily under the persisted range count, while Snapshot calls validate without
retention. Allocation or count failure publishes no partial predicate. Admission and prepublication checks reject
post-Begin writes in `[Lower, Upper)`, including open and whole-family forms, for singleton and grouped commits.
Public `Scan` now materializes the complete selected half-open interval at the transaction's fixed snapshot, merges
own Put/Delete mutations, and sorts by unsigned-byte lexicographic key. Its controlled result owns exact descriptors
and combined key/value bytes bounded by persisted live-entry/live-state limits. Allocation, validation, or predicate
retention failure leaves the caller's previous result unchanged; Serializable predicates become visible only after
complete materialization. Pagination, streaming scans, and physical merge iteration remain later Milestone 4 work.

The fixed-snapshot point-read rule is now separately model-checked and proved: read-your-writes precedes committed
history, committed lookup selects the newest version no later than Begin, and incomplete checkpoint history returns a
conservative too-old outcome. Production `Get` now implements that selection rule, mapping formal `TooOld` to the
existing public `Conflict` outcome without adding a new public enumeration or persisted field.

The formal serializable rule retains successful and absent point reads plus normalized range predicates only in
serializable mode. A commit rejects when a post-Begin committed write intersects its writes, retained points, or
retained ranges. Independent point/range capacity rejection is safety backpressure: reaching a bound never drops an
observation. The finite one-slot model values are qualification geometry rather than product defaults; production
capacities are persisted caller-authority decisions in manifest v3, with no library default.

The production point validator maps that rule directly: linked observations contain the exact validated family/key
bytes and are allocated only after an external read has produced `Success` or `Not_Found`. A node is fully built
before it becomes transaction-owned; allocation failure and one-over capacity leave the observation set unchanged.
Distinct point predicates participate in both admission and prepublication conflict checks, while duplicates and
read-your-writes consume no additional slot. Range predicates use the same transactional ownership convention: each
present endpoint is fully copied before linkage, exact duplicates consume no new slot, and arena finalization owns
all reclamation. Bytewise comparison makes the lower endpoint inclusive and upper endpoint exclusive.

The first-LSM work now includes current manifest-v3, readable manifest-v2, and SST-v1 formats, dynamic operational
codecs, manifest-v3 root creation, public synchronous and composable Flush/receipt reconciliation, live coordinator
replacement, additive per-family suffix runs, and cacheless oldest-to-newest recovery of every current run plus the
strictly later batch suffix. Recovery restores live
values, last-write sequences, and the exact never-reused checkpoint identity ledger from persisted authority.
The additive DB-level `Flush_Operation` moves a caller-sized unique-buffer token through the same certainty contract
without a helper task. A private operational path now builds one complete live-state run per nonempty family,
publishes a successor manifest naming only those fresh runs, and reconciles unknown immutable-object responses by
rebuilding the exact replacement plan. A private test-qualified constructor drives that same algorithm through the
caller-owned composable operation and typed token-restoring `Finish`. The public compaction surface,
streaming/physical scans, run pruning, retention/GC policy, and provider qualification remain later focused units, so
Milestone 4 remains incomplete.

The retention/GC safety rule is now independently model-checked and proved. Current HEAD authority, active snapshot
pins, lagging-replica pins, required predecessor reachability, and unresolved publication attempts each retain exact
immutable identities. A listed object becomes deletable only after an explicit age decision and a live protection
recheck; deleted identities are never reused. Concrete age horizons, provider timestamp trust, deletion certainty,
batching, scheduling, and an operational collector remain pending Milestone 6 decisions.

The private replica spine can now refresh one open read-only-use handle synchronously. It drains the existing
lifecycle, validates a complete cacheless recovery graph, and installs only a strictly newer transition-ordinal/
writer-epoch pair. Same/older observations and safe allocation failure retain the prior engine; a fenced writer is
not implicitly promoted. Public and composable refresh declarations, polling, leases, replica registration and
retention pins, and explicit promotion remain pending Milestone 8 decisions.

The LSM read-equivalence lane now exhausts all two-key/two-value captured views and later mutation maps, validates a
concrete delete/put execution witness, rejects a replacement that omits one live key, and proves the arbitrary-key/
value reconstruction and later-delta equations with TLAPS. This strengthens the private replacement spine without
choosing a public trigger, automatic schedule, run-level policy, or storage budget.

The scan-range-normalization lane freezes same-family half-open union, transitive bridge coalescing, cross-family
separation, and atomic capacity/allocation rollback before changing the runtime list. Its finite model exhausts 3,419
states and the arbitrary-universe kernel proves 19 TLAPS obligations. Production still retains exact distinct
predicates until the paired Ada unit lands, so this formal boundary alone does not complete transaction execution.

## Formal state-machine lane

TLA+ models single- and bounded pooled-transaction publication, ambiguous outcomes, fencing, cache loss, and recovery
before the corresponding production unit freezes. TLC exhausts a bounded state space and emits selected execution
witnesses. TLAPS proves an unbounded batch-atomic safety kernel. A checked scenario converter projects selected
witnesses into the normative NDJSON workload contract for replay against the Ada reference model, Flyology.DB, and
supported comparative oracles.
