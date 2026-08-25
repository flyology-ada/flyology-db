# Limited end-to-end profile

This profile is the first deliberately usable Flyology.DB boundary. It is experimental, bounded, and smaller than
the complete architecture. Passing it demonstrates one coherent public workflow; it does not imply production,
performance, replica, automatic-maintenance, or general-provider qualification.

## Included behavior

- One fenced writer and no concurrent promotion.
- An immutable set of column families supplied at `Create`, with stable IDs and exact byte names.
- Arbitrary byte keys and values within the persisted per-family limits selected by the caller.
- Explicit persisted `Database_Limits`; the library supplies no hidden key, value, transaction, or live-state limit.
- Synchronous Snapshot transactions with point `Get`, ordered bounded `Scan`, `Put`, `Delete`, singleton `Commit`,
  and explicit atomic `Commit_Group`.
- Explicit synchronous `Flush` into immutable SST and manifest objects, including a later suffix-delta Flush.
- `Outcome_Unknown` receipts resolved only through the original identity; no application transaction or mutation is
  automatically replayed.
- `Close`, complete loss of process-local DB state, and `Open` recovery solely from authoritative object storage.
- A provider-neutral power-loss-durable files run of the complete database-level oracle.

The synchronous profile is the first user-facing entry point. Its client-backed Flush already waits on the same
provider-owned Object Storage state machines as the caller-composable DB operation, so this boundary does not create
a second transport or certainty implementation.

## Acceptance scenario

One maintained executable must perform the following sequence using only public Flyology.DB APIs:

1. Receive every database identity, object identity, column-family limit, database limit, timeout, provider endpoint,
   bucket, prefix, and credential choice explicitly from its fixture or caller.
2. Create a database with at least two fixed families and reopen both by stable ID and exact name.
3. Commit exact byte keys and values, verify point reads, delete one key, and verify ordered half-open scanning.
4. Atomically commit a group whose members affect different families and verify one all-or-nothing visible sequence.
5. Flush a complete first checkpoint, commit a later suffix, and Flush the suffix without changing prior run identity.
6. Close the database, discard every process-local DB object and buffer, construct a fresh database value, and Open
   it from the same object-store prefix.
7. Verify the exact surviving bytes, deletion, canonical scan order, highest visible sequence, and persisted family
   handles after recovery.
8. Close cleanly and report every non-success outcome without retrying a mutation or silently weakening certainty.

The existing authenticated provider matrix remains corroborating transport and certainty evidence, but it is not
claimed as the exact showcase workflow. Porting this public-only oracle unchanged to a caller-configured authenticated
provider is the first expansion after the files profile is accepted. S3, HTTP, signing, retry, and endpoint policy
remain outside Flyology.DB.

## Explicit exclusions

This profile does not include dynamic family changes, public replica management, writer promotion, TTL, codecs,
automatic Flush or compaction selection, public compaction/garbage-collection policy, an authenticated deployment
walkthrough, background polling, transparent retry, retained borrowed request bodies, performance claims, or
stable-format compatibility beyond the versions accepted by the current decoder. Existing private compaction and
replica spines remain qualification work until a separate public-policy decision admits them.

Expansion starts only after the acceptance scenario, deterministic suite, provider matrix, repository gate, TLA+ and
TLAPS models, selected SPARK proof, API documentation, and findings cycle are green on one exact source/dependency
tree.
