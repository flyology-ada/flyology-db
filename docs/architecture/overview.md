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

The executable slice remains log-only: recovery follows `HEAD.Latest_Batch` and the predecessor-batch ID in each
immutable commit object, then rebuilds logical state in sequence order without local state or listing. HEAD version 2
names an immutable root column-family manifest before any batch is decoded. That manifest is the authority for stable
numeric IDs, exact UTF-8 names, per-family key/value admission limits, and database resource budgets. Create requires
all initial identities, limits, and families explicitly and canonicalizes families by numeric ID before effects.
Open reads the complete manifest chain before the batch chain and installs neither partial registry nor partial state.
HEAD version 1 remains decodable for inspection but operational Open returns `Unsupported_Format`; no migration or
write path silently upgrades it.

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

The planned production encoder does not inline every configured maximum value or allocate one maximum-size object
buffer. An immutable owned group arena supplies a measured/CRC pass and one-shot streaming encode to the synchronous
provider; recovery streams into a bounded arena, validates the complete object, then installs atomically. Later
composable overloads may move `Unique_Buffer` tokens while reusing the same semantic state machine.

The current fixed-array recovery path retains up to 64 complete batch records on the caller stack. The deterministic
exclusive-resolution test therefore gives its native Ada task an explicit 8 MiB stack. This is bounded evidence for
the present reference instance, not the production owned-byte design; replacing that footprint with the owned
streaming spine is a prerequisite before widening family key/value limits.

`Get`, `Put`, and `Delete` take the owning `Database` so each call acquires the same lifecycle lease used by commit
admission. They reject fenced or uncertain engine state before observing or changing transaction-local data.
`Rollback` deliberately remains database-independent so callers can always discard an active transaction after a
close or fence. This is an experimental 0.1 API correction; no compatibility promise exists for the earlier
transaction-only `Put` and `Delete` declarations.

The current build accepts persisted family configurations only when every key limit is at most 64 bytes, every value
limit is at most 256 bytes, and the database limits fit the fixed runtime ceilings. A valid manifest above those
physical ceilings returns `Capacity_Exceeded` before engine activation; lower persisted limits remain authoritative
for mutation admission and recovery. The local slice fixes recovery at 64 batches, 512 published transaction IDs,
and 256 live entries. Eight completion
slots and eight transactions per explicit group make the published seen-ID bound exactly `64 * 8 = 512`. A separate
open-engine reservation ledger holds at most `64 * (8 + 1) = 576` identities: eight member transaction IDs and one
distinct group ID for every admitted group; a singleton transaction/batch ID counts once. The queue byte budget is
16 KiB. Admission proves both identity capacities before publication so every acknowledged history remains reopenable
under the same caps. These are operational limits, not wire-format widths.

## Recovery and retention

Ordinary recovery reads the exact head and objects it names. It does not depend on listing, a writer spool, or any
cache. Decoding fails closed. Compaction publishes complete immutable outputs before a metadata transition and keeps
all versions required by transactions, snapshots, checkpoints, and replicas. Garbage collection requires an explicit
reachability and age boundary; a list result alone never proves that an object is unreachable.
