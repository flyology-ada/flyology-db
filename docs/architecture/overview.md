# Architecture

## Authority and publication

Object storage is the sole authority. A successful commit consists of two immutable/publication steps: publish the
complete commit batch at a unique key, then conditionally replace `meta/HEAD` from the generation read by the
writer. The head is the visibility, fencing, and recovery publication point. Unreachable uploaded objects are
orphans and are never visible.

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

The first executable slice is log-only: recovery follows `HEAD.Latest_Batch` and the predecessor-batch ID in each
immutable commit object, then rebuilds logical state in sequence order without local files or listing. Later
milestones checkpoint that chain through immutable manifests and SSTs without changing the publication rule.

## Transaction semantics

A transaction reads from one global snapshot and sees its own buffered mutations. Snapshot isolation rejects a
commit when a key it writes was written after that snapshot. Serializable mode additionally records point reads and
normalized scan ranges and rejects a post-snapshot write that intersects either. The initial serializable validator
may conservatively reject additional transactions but may not admit write skew or phantoms forbidden by this rule.

Transactions carry caller-visible idempotency identities. A receipt separates success, conflict, definite failure,
and unknown publication. Resolving an unknown receipt never reapplies the transaction under a new identity.

## Execution and ownership

Public calls retain synchronous Ada semantics. The planned production engine will use Ada tasking: bounded Flyology
scoped operations, completion sets, channels, and unique buffers compose storage I/O, while group commit uses one
long-lived Ada coordinator task rather than a task per caller. CPU-heavy sorting, compression, and merging will use
bounded native Ada tasks or an explicitly isolated process with detached owned input. The engine will not create
detached C threads.

## Recovery and retention

Ordinary recovery reads the exact head and objects it names. It does not depend on listing, a writer spool, or any
cache. Decoding fails closed. Compaction publishes complete immutable outputs before a metadata transition and keeps
all versions required by transactions, snapshots, checkpoints, and replicas. Garbage collection requires an explicit
reachability and age boundary; a list result alone never proves that an object is unreachable.
