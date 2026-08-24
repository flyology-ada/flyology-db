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

The executable mutation surface remains log-only, but recovery accepts either that log-only form or one complete
nonempty first checkpoint. Log-only recovery follows `HEAD.Latest_Batch` and the predecessor-batch ID in each
immutable commit object, then rebuilds logical state in sequence order without local state or listing. HEAD version 2
names an immutable root column-family manifest before any batch is decoded. New Create operations encode that root as
manifest version 2 with an empty checkpoint partition and explicit database-wide run/identity plus per-family
memtable/L0 authority. Activation retains that authenticated policy in live engine state rather than reconstructing
it from handles or defaults. Existing manifest-v1 roots remain readable for log-only operation. Create requires all
initial identities, limits, and families explicitly and canonicalizes families by numeric ID before effects. Open reads the
complete manifest chain before the batch chain and installs neither partial registry nor partial state. HEAD version
1 remains decodable for inspection but operational Open returns `Unsupported_Format`; no migration or write path
silently upgrades an existing manifest-v1 database.

The staged first-checkpoint protocol is specified separately in
[`lsm-checkpoint-publication.md`](lsm-checkpoint-publication.md). Manifest-v2 root creation and cacheless nonempty
checkpoint recovery are operational. The private deterministic publisher exists only to build recovery fixtures;
the certainty-preserving public Flush surface remains the next focused publication unit.

## Transaction semantics

A transaction reads from one global snapshot and sees its own buffered mutations. Snapshot isolation rejects a
commit when a key it writes was written after that snapshot. Serializable mode additionally records point reads and
normalized scan ranges and rejects a post-snapshot write that intersects either. The initial serializable validator
may conservatively reject additional transactions but may not admit write skew or phantoms forbidden by this rule.

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
storage deadline. Future sustained remote I/O will compose bounded Flyology scoped operations, completion sets,
channels, and unique buffers over this same semantic core. CPU-heavy sorting, compression, and merging will use
bounded native Ada tasks or an explicitly isolated process with detached owned input. The engine will not create
detached C threads.

The synchronous runtime does not inline configured maximum values or allocate a theoretical maximum-history image
product. A caller's borrowed bytes are copied once into a transaction-owned arena, atomically moved into a coordinator
slot, and encoded into one exact reference-counted immutable batch image. The provider source borrows that image for
the synchronous call; it does not clone it. Recovery sinks own exact response images, and live state stores image
offsets/views. Outcome-unknown receipts retain a shared exact image until conclusive byte-for-byte reconciliation.
Later composable overloads may move `Unique_Buffer` tokens while reusing this semantic core.

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
