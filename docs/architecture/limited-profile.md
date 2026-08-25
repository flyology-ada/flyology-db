# Limited end-to-end profile

This profile is the first deliberately usable Flyology.DB boundary. It is experimental, bounded, and smaller than
the complete architecture. Passing it demonstrates one coherent public workflow; it does not imply production,
performance, replica, automatic-maintenance, or general-provider qualification.

## Included behavior

- One fenced writer and no concurrent promotion.
- One initial family set supplied at `Create`, followed by at most the caller-driven append operations admitted by
  persisted registry/history capacity. Each append adds exactly one higher stable ID and one exact byte name; rename,
  drop, reorder, and prior-family mutation remain unavailable.
- Arbitrary byte keys and values within the persisted per-family limits selected by the caller.
- Explicit persisted `Database_Limits`; the library supplies no hidden key, value, transaction, or live-state limit.
- Synchronous Snapshot transactions with point `Get`, ordered bounded `Scan`, `Put`, `Delete`, singleton `Commit`,
  and explicit atomic `Commit_Group`.
- Explicit synchronous `Flush` into immutable SST and manifest objects, including a later suffix-delta Flush.
- Exact caller-selected two- or three-consecutive-run `Compact`, retaining every version/tombstone and all
  surrounding runs. The maintained Files acceptance scenario selects the two-run form.
- Synchronous and caller-composable `Add_Column_Family` at an exact checkpoint boundary, with exact
  manifest/transition identities and same-receipt resolution of immutable or HEAD uncertainty.
- `Outcome_Unknown` receipts resolved only through the original identity; no application transaction or mutation is
  automatically replayed.
- `Close`, complete loss of process-local DB state, and `Open` recovery solely from authoritative object storage.
- A provider-neutral power-loss-durable files run of the complete database-level oracle.

The synchronous profile is the first user-facing entry point. Its client-backed Flush and family append wait on the
same DB operations and provider-owned Object Storage state machines as their caller-composable forms, so this
boundary does not create a second transport or certainty implementation.

## Acceptance scenario

One maintained executable must perform the following sequence using only public Flyology.DB APIs:

1. Receive every database identity, object identity, column-family limit, database limit, timeout, provider endpoint,
   bucket, prefix, and credential choice explicitly from its fixture or caller.
2. Create a database with one explicit family and reopen it by stable ID and exact name.
3. Commit exact byte keys and values, then Flush a complete first checkpoint.
4. Append one independently bounded higher-ID family with caller-stable manifest and transition identities, then
   reopen it by stable ID and exact name.
5. Atomically commit a group whose members affect both families, verify one all-or-nothing visible sequence, delete
   one key, verify ordered half-open scanning, and Flush the suffix without changing prior run identity.
6. Compact the exact adjacent root-family pair under caller-supplied output, manifest, and transition identities,
   then verify that the second family and complete logical view remain unchanged.
7. Close the database, discard every process-local DB object and buffer, construct a fresh database value, and Open
   it from the same object-store prefix.
8. Verify the exact surviving bytes, deletion, canonical scan order, highest visible sequence, and persisted family
   handles after recovery.
9. Close cleanly and report every non-success outcome without retrying a mutation or silently weakening certainty.

The authenticated provider matrix directly exercises checkpoint-bound family append, lost-HEAD-response
reconciliation through the original receipt, cross-family commit and Flush, compaction, close, and cacheless reopen
against RustFS, SeaweedFS, MinIO, and Flyology memory, files, and SQLite. The public Files showcase remains the exact
complete-local-loss acceptance workflow; the matrix is a provider qualification of the same family-registry and
recovery spine, not a claim that its transport harness is the showcase executable unchanged. S3, HTTP, signing,
retry, and endpoint policy remain outside Flyology.DB.

## Explicit exclusions

This profile does not include family rename/drop/reconfiguration, appending across an unflushed commit suffix,
public replica management, writer promotion, TTL, codecs, automatic Flush or
automatic compaction selection, garbage-collection policy, an authenticated deployment walkthrough,
background polling, transparent retry, retained borrowed request bodies, performance claims, or stable-format
compatibility beyond the versions accepted by the current decoder. Public complete-view `Compact` is deliberately
policy-neutral: the caller supplies every output and publication identity, and the operation retains predecessors.
Public exact two- and three-run compaction is likewise caller-selected and retains all history; fixed arity does not
authorize an automatic selector, fanout, pruning, or deletion. The replica spine remains qualification work until
separate public-policy decisions admit it.

Expansion starts only after the acceptance scenario, deterministic suite, provider matrix, repository gate, TLA+ and
TLAPS models, selected SPARK proof, API documentation, and findings cycle are green on one exact source/dependency
tree.

## First additive expansion

The accepted profile remains the smaller baseline above. The first additive operation beyond it is synchronous
`Refresh_Replica`: one caller-triggered monotonic refresh of an already-open handle dedicated by the caller to
read-only replica use. It validates and installs one complete newer authoritative graph or leaves the prior view
unchanged. It adds no polling, helper task, retry, lease, registration, retention, promotion, or timeout default, and
a fenced handle remains fenced. Authenticated provider qualification exercises a deliberately stale checkpoint view
followed by one exact refresh to the writer's compacted view.
