# Architecture

## Authority and publication

Object storage is the sole authority. A successful commit consists of two immutable/publication steps: publish the
complete commit batch at `<prefix>/commits/<batch-id>`, then conditionally replace `<prefix>/meta/HEAD` from the
generation read by the writer. The head is the visibility, fencing, and recovery publication point. Unreachable
uploaded objects are orphans and are never visible.

Every head transition has a fresh opaque ID, a strictly increasing transition ordinal, and its predecessor ID. The
`(ordinal, ID)` pair is the exact transition identity, so reuse of an older opaque ID at another ordinal cannot
confirm publication. A stale expected generation loses the conditional replacement. A stale writer that observes
another writer epoch stops. If the replacement response is lost, a generation-bound head read reconciles the exact
transition identity; continuing unavailability remains unknown.

## Initial state model

- One active writer epoch and one global commit sequence.
- Stable column-family IDs that are never inferred from order and never reused.
- One database-wide transactional log; a single transaction may mutate several families atomically.
- Per-family logical/MVCC state, memtables, immutable runs, configuration, and later compaction.
- Read-only replicas advance monotonically by observing valid head transitions.

The formal replica boundary captures one exact HEAD ordinal/writer-epoch pair, validates its complete immutable
graph, and installs it only at or above the replica's high-water pair and no later than current authority. A captured
older head may finish after authority advances and install as an intermediate monotonic step. Writers publish only
from their exact captured ordinal and epoch; fencing invalidates an already prepared writer. Polling, lease duration,
promotion, local-loss continuity, and the operational Ada surface remain undecided.

The executable mutation surface remains log-only between explicit flushes, while recovery accepts either that form
or the latest additive L0 checkpoint. Log-only recovery follows `HEAD.Latest_Batch` and the
predecessor-batch ID in each
immutable commit object, then rebuilds logical state in sequence order without local state or listing. HEAD version 2
names an immutable root column-family manifest before any batch is decoded. New Create operations encode that root as
manifest version 3 with an empty checkpoint partition and explicit database-wide run, identity, and serializable
count authority plus per-family memtable/L0 authority. Activation retains that authenticated policy in live engine
state rather than reconstructing it from handles or defaults. Existing manifest-v1 roots remain readable for
log-only operation; manifest-v2 roots remain readable for snapshot operation but carry no serializable point/range
authority. Create requires all initial identities, limits, and families explicitly and canonicalizes families by
numeric ID before effects. Open reads the complete manifest chain before the batch chain and installs neither partial
registry nor partial state. HEAD version
1 remains decodable for inspection but operational Open returns `Unsupported_Format`; no migration or write path
silently upgrades an existing manifest-v1 database.

The checkpoint protocol is specified separately in
[`lsm-checkpoint-publication.md`](lsm-checkpoint-publication.md). Manifest-v3 root creation, public synchronous Flush
and caller-composable Flush with self-contained certainty receipts, exact same-identity reconciliation, live
coordinator replacement, additive multi-run L0 publication, and cacheless all-run recovery are operational.
The private complete-replacement compaction planner/publisher is operational through both synchronous and
test-qualified caller-composable drivers; its public trigger, automatic policy, snapshot/replica retention horizon,
run pruning, and physical garbage collection are not.

The formal immutable-cache boundary keys verified entries and coalesced in-flight reads by exact object generation.
A read captures its generation before consulting local state, only waiters for that same generation join a fetch,
and corrupt entries are discarded as misses. Complete local loss may discard valid/corrupt entries and in-flight
fetch ownership but preserves object-store authority and the caller's exact requested generation. This is a safety
contract, not an operational cache claim: concrete RAM/disk capacities, allocation, eviction, layout, progress, and
the Ada refinement remain later decisions.

## Transaction semantics

The target transaction reads from one global snapshot and sees its own buffered mutations. The operational first
slice captures the global sequence at Begin and rejects a commit when an exact key it writes was written after that
sequence. It retains each lazily allocated decoded post-checkpoint batch with its already-owned immutable image, so
Put and Delete history have equal conflict authority without allocating a theoretical key table. A transaction older
than the retained checkpoint boundary rejects conservatively because compacted tombstones can erase negative
evidence. An explicit commit group is one atomic co-commit unit: members validate independently against external
history, while existing deterministic member order resolves overlapping member writes. `Get` still returns the
newest buffered mutation first. Otherwise it searches retained exact committed history for the newest value no later
than the Begin sequence, then falls back to exact checkpoint-base descriptors allocated lazily from authenticated SST
entry counts. A snapshot older than the retained checkpoint boundary returns `Conflict`; it never substitutes latest
state or incomplete negative evidence.

The public `Isolation_Level` selects `Snapshot` or `Serializable` explicitly at Begin; the compatibility overload is
a literal Snapshot call and supplies no public default. A serializable external `Get` retains one lazily allocated
exact family/key predicate after either a successful or absent read. Duplicate observations deduplicate, own buffered
Put/Delete reads bypass observation capacity, and allocation or one-over-capacity failure returns
`Capacity_Exceeded` without partially linking an observation or poisoning the transaction. Commit admission and the
prepublication recheck reject a post-Begin write intersecting a retained point; atomic groups validate each member's
points independently against external history. Manifest-v2 databases have no point/range authority, so explicit
Serializable Begin returns `Unsupported_Format` rather than inventing a ceiling. Manifest v3 supplies the exact
database-wide point count while the selected family's persisted maximum continues to bound copied key bytes.

Public `Observe_Range` operationalizes the frozen half-open predicate rule without claiming to return rows. False
endpoint flags mean unbounded and make the corresponding bytes irrelevant; two present endpoints require strict
bytewise `Lower < Upper`. Snapshot transactions validate but retain nothing. Serializable transactions lazily copy
each distinct exact family/present-endpoint tuple under the persisted range count and selected family's key bound.
Node or endpoint allocation failure and one-over capacity return `Capacity_Exceeded` without partial linkage.
Commit admission and its prepublication recheck reject any post-Begin same-family write with
`Lower <= Key < Upper`; open and whole-family forms follow from the same comparison. Atomic groups validate each
member against external history. `Scan` uses the identical predicate and materializes every live row at the fixed
snapshot, including transaction-local Put/Delete precedence, before retaining that predicate in Serializable mode.
Rows are returned in unsigned-byte lexicographic key order through a limited controlled result. Exact row count and
combined key/value bytes are bounded by persisted database live-state limits; individual keys and values remain
bounded by the selected family. A failed call neither replaces an earlier result nor retains a partial predicate.

Transactions carry caller-visible idempotency identities. A singleton transaction uses that exact identity as its
immutable batch ID. An explicit group carries a separate caller-stable group ID; group and transaction IDs share one
never-reused batch-ID namespace, including failed admitted attempts and recovered history. A receipt separates
success, conflict, definite failure, and unknown publication. Pre-admission rejection leaves the transaction active;
admission consumes it regardless of the later terminal result. The open engine reserves every admitted batch ID, and
after local-state loss a pre-existing immutable object rejects a later admission rather than permitting exact-byte
application replay. Exact-byte reconciliation proceeds only inside the original admitted operation. Resolving an
unknown receipt never reapplies the transaction under either the same or a new identity.

## Execution and ownership

Public calls retain synchronous Ada semantics. The local log-only slice uses one long-lived native Ada coordinator
task with bounded count and byte admission and generation-stamped completion slots; it does not create a task per
transaction. `Commit` is an uncoupled singleton. `Commit_Group` intentionally gives at most eight transactions one
absolute deadline, immutable batch, and HEAD transition. Queue cancellation and timeout apply before atomic
admission. Once publication starts, every admitted caller waits for terminal classification under that same absolute
storage deadline. The current authenticated client binding is the first composable-core step: its synchronous
conditional Put and whole/range Get calls are literal waits over Object Storage scoped state machines, with one moved
unique-buffer token per body operation, one absolute DB deadline, no helper task, and no automatic retry. A range
whose generation is not yet known first performs HeadObject and then binds the range read to that exact ETag. The
DB-level `Flush_Operation` now composes conditional Put and whole-Get children directly in the caller's bounded
completion set. Its private replacement constructor selects complete current-run replacement without changing the
public additive `Start_Flush`; both modes share exact ownership, deadline, certainty, and reconciliation behavior.
Typed `Finish` restores the exact moved token into any vacant same-pool handle; an abandoned operation drains nested
transport work before releasing that token. CPU-heavy sorting, compression, and merging will
use bounded native Ada tasks or an explicitly isolated process with detached owned input. The engine will not create
detached C threads.

The synchronous runtime does not inline configured maximum values or allocate a theoretical maximum-history image
product. A caller's borrowed bytes are copied once into a transaction-owned arena, atomically moved into a coordinator
slot, and encoded into one exact reference-counted immutable batch image. The provider source borrows that image for
the backend-neutral synchronous call; it does not clone it. The authenticated client adapter lazily allocates an
exact request buffer from the encoded image length and an exact response buffer from the authenticated or persisted
read bound. It copies into and out of those transient tokens while the engine keeps the same certainty and recovery
semantics. Recovery sinks own exact response images, and live state stores image offsets/views. Outcome-unknown
receipts retain a shared exact image until conclusive byte-for-byte reconciliation. Composable Flush moves the
caller's `Unique_Buffer` token while reusing this semantic core and preflights every encoded object against its
caller-selected block capacity before publication.

Recovery admits manifest and SST headers before allocating their exact authenticated whole-object lengths, binds the
second read to the first read's opaque generation, and allocates replay history only for batches after the checkpoint
boundary. Engine state, checkpoint/run images, identity ledgers, and final-state projection scratch are sized from
persisted database and family limits before protected publication. Checked arithmetic and `Storage_Error` handling
leave Open closed and protected state unchanged on allocation failure. The small SPARK batch codec remains a separate
reference instance.

`Get`, `Put`, and `Delete` take the owning `Database` so each call acquires the same lifecycle lease used by commit
admission. They reject fenced or uncertain engine state before observing or changing transaction-local data.
`Rollback` deliberately remains database-independent so callers can always discard an active transaction after a
close or fence. This is an experimental 0.1 API correction; no compatibility promise exists for the earlier
transaction-only `Put` and `Delete` declarations.

Persisted per-family key/value limits and database mutation/payload/live-state limits are executable authority.
The runtime accepts the required 20-byte/400-byte profile and the 4 KiB/1 MiB profile without introducing replacement
key/value ceilings. Actual byte images must fit the wire's U32 key/value/count fields and the host's `Natural`-sized
owned container; checked failure is classified before publication. The current manifest format still bounds history
at 64 and the public synchronous group surface at eight members. Seen and reservation ledgers are sized as
`Maximum_Batch_History * Maximum_Transactions_Per_Batch` and history times one additional group identity; singletons
count once. Queue bytes are bounded by the persisted batch payload budget. Admission proves capacities before
publication so every acknowledged history remains reopenable under the same persisted limits.

## Recovery and retention

Ordinary recovery reads the exact head and objects it names. It does not depend on listing, a writer spool, or any
cache. Decoding fails closed. Compaction publishes complete immutable outputs before a metadata transition and keeps
all versions required by transactions, snapshots, checkpoints, and replicas. Garbage collection requires an explicit
reachability and age boundary; a list result alone never proves that an object is unreachable.

The formal retention boundary makes those protections independent and exact: current authority, active snapshots,
lagging replicas, required predecessors, and unresolved publication attempts each prevent deletion. Listing and an
explicit age decision only nominate a candidate; deletion must recheck the live union of protections atomically, and
a deleted identity is never reused. The model freezes safety only. It does not select an age horizon, provider clock,
delete batching/certainty rule, scheduler, public API, or operational collector.
