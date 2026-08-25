# Milestone plan and acceptance gates

Each milestone completes a focused develop, commit, independent review, fix/amend, and re-review loop. A milestone
is accepted only when its implementation, tests, proof, documentation, dependency provenance, and review record pass.

| Milestone | Acceptance gate | State |
| --- | --- | --- |
| 0 Foundation | Crate, guide, dependency clone/pin, architecture/format/oracle contracts, runners, provenance | Accepted at `8b9ff8c` |
| 1 Publication | Atomic absent/matching-generation writes, generation reads, reconciliation, provider fault tests | Local and authenticated-client paths implemented; remote matrix pending |
| 2 Log-only transactions | Create/open, stable families, pooled cross-family commits, remote recovery | Owned synchronous spine accepted at `c909c57`; authenticated binding added; remote matrix pending |
| 3 MVCC/isolation | Snapshot and serializable validation, rollback, receipts, controlled concurrency | Snapshot plus serializable point/range-predicate validation operational; broader acceptance pending |
| 4 Memtables/SST | Per-family memtables, validated format, lookup/scan, flush recovery | Additive L0, private sync/composable replacement, and manifest-admitted version-preserving merge kernel operational; public compaction pending |
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
exercises create, commit, synchronous and composable checkpoint Flush, composable replacement, and cacheless reopen
through provider-owned Object Storage operations in `Client.Objects`. Client-bound synchronous Flush is now an
owner-driven wait over the same DB operation; memory/files retain the backend-neutral synchronous fallback. The
limited operation and caller-owned completion set express scoped lifetime; a separate `.Scoped` package would create
a second vocabulary for the same provider state machine and is intentionally absent. Remote-provider matrix
qualification and dynamic append-only family changes remain prerequisites for accepting Milestone 2. The accepted
owned-runtime closure is `c909c572`; the pooled TLA+ and manifest-publication models remain abstract assurance lanes
rather than a claimed refinement proof.

The persisted transition and cacheless-recovery prerequisite now admits a manifest-v3 checkpoint carrier that
either preserves the exact registry or appends exactly one higher-ID family while leaving every prior record fixed.
This prevents a later dynamic-family publication from discarding an already-compacted replay boundary. It does not
yet expose or claim the public dynamic-family publication operation; that lifecycle, receipt, reconciliation, and
activation slice remains part of Milestone 2.

The immediate integration target is the [limited end-to-end profile](limited-profile.md). It freezes one coherent
public workflow before broadening policy: fixed initial families, synchronous transactions, explicit Flush, complete
process-local state loss, and authoritative reopen. Dynamic families, public compaction policy, replicas, TTL, and
automatic maintenance remain outside that acceptance claim.

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
retain normalized same-family components lazily under the persisted range count, while Snapshot calls validate
without retention. Overlap, endpoint contact, and transitive bridges become exact unions; cross-family components
remain distinct. Allocation or count failure publishes no partial predicate. Admission and prepublication checks reject
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

The policy-neutral partial-compaction lane now places two selected consecutive runs between retained older and newer
runs. Its finite model exhausts every two-key/two-value mutation map, validates an older/selected/newer execution
witness, and rejects a merger that drops a selected tombstone. Its arbitrary-key/value TLAPS kernel proves that the
newest selected mutation per key exactly replaces the pair while retained surrounding order remains unchanged.
Automatic run selection, trigger/fanout/level policy, and a public compaction surface remain separate Milestone 4
and 6 work. The private runtime now supplies the narrower
snapshot-safe merge iteration kernel: two validated ordered nonoverlapping SSTs become one fresh-identity SST while
every version and tombstone remains. Exact output extents are checked sums of the inputs. The manifest-aware entry
point requires the two exact SST descriptors to be adjacent in one authenticated family and rejects an output identity
already named by that manifest. An effect-free builder now validates the exact next checkpoint base and produces the
corresponding successor by replacing only that pair while preserving all other persisted authority. The private
publisher binds that captured manifest to current HEAD, authenticates the named SSTs, stores and confirms the merged
SST and successor, conditionally advances HEAD, and reconciles an ambiguous object response only by rebuilding the
same selected pair and identities. Client-backed selected reads run through the caller-owned completion set and the
synchronous form waits on that operation; backend-neutral memory/files reads remain blocking. Production policy
remains separate work. A later log suffix is cloned at its exact decoded transaction/mutation extents before publication,
with shared ownership of its immutable images. The replacement coordinator reconstructs only the successor run base,
then replays the suffix to preserve conflict and identity authority. Recovery admits that topology only through exact
batch-to-manifest-chain and suffix-to-checkpoint-boundary anchors.

The same private runtime now has an additive exact-three-run qualification kernel. It admits only three adjacent
descriptors selected by its caller, uses one checked allocation for their exact combined entry/payload extents,
retains every version and tombstone, and replaces only those three descriptors with one in the effect-free successor.
The maintained TLC lane exhausts the middle-tombstone/last-empty case and TLAPS proves arbitrary-key associative
composition with retained surrounding runs and a later suffix. The private publisher now operationalizes that exact
slice through the established Flush owner stack: three authenticated source reads, one immutable output, one
successor manifest, one conditional HEAD transition, and exact same-identity resolution after an uncertain response.
The receipt retains the exact three source IDs needed to reconstruct the attempted bytes; it retains no caller handle
or borrowed body. Cacheless activation treats only the first, highest-sequence entry for each key in a sorted SST as
live-state authority, preserving a selected tombstone while older versions remain in the immutable object. This does
not choose automatic selection, fanout, trigger, levels, retries, publication scheduling, or a public API; those
remain Milestone 4 and 6 work.

The scan-range-normalization lane freezes same-family half-open union, transitive bridge coalescing, cross-family
separation, and atomic capacity/allocation rollback. Its finite model exhausts 3,419 states and the arbitrary-universe
kernel proves 19 TLAPS obligations. Production and the bounded SPARK oracle now implement that rule: they build a
complete replacement before atomically publishing the normalized set, and a full-capacity merge remains admissible.

## Formal state-machine lane

TLA+ models single- and bounded pooled-transaction publication, ambiguous outcomes, fencing, cache loss, and recovery
before the corresponding production unit freezes. TLC exhausts a bounded state space and emits selected execution
witnesses. TLAPS proves an unbounded batch-atomic safety kernel. A checked scenario converter projects selected
witnesses into the normative NDJSON workload contract for replay against the Ada reference model, Flyology.DB, and
supported comparative oracles.
