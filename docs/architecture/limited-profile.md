# Limited end-to-end profile

This profile is the first deliberately usable Flyology.DB boundary. It is experimental, bounded, and smaller than
the complete architecture. Passing it demonstrates one coherent public workflow; it does not imply production,
performance, replica, automatic-maintenance, or general-provider qualification.

## Included behavior

- One fenced writer and no concurrent promotion.
- One initial family set supplied through synchronous or caller-composable `Create`, followed by at most the
  caller-driven append operations admitted by persisted registry/history capacity. Each append adds exactly one
  higher stable ID and one exact byte name; rename, drop, reorder, and prior-family mutation remain unavailable.
- Arbitrary byte keys and values within the persisted per-family limits selected by the caller.
- Explicit persisted `Database_Limits`; the library supplies no hidden key, value, transaction, or live-state limit.
- Failure-atomic reads of the exact installed registry revision, family count, database limits, and complete
  per-family name/key/value/memtable/L0 settings. A caller-bounded atomic registry read enumerates every installed
  family in increasing-ID order without out-of-band names or IDs. These local snapshots perform no storage I/O,
  dynamic allocation, or policy selection.
- Snapshot transactions with point `Get`, ordered bounded `Scan`, `Put`, `Delete`, synchronous or
  caller-composable singleton `Commit`, and synchronous or caller-composable atomic `Commit_Group`.
- Explicit synchronous `Flush` into immutable SST and manifest objects, including a later suffix-delta Flush.
- A synchronous `Required_L0_Checkpoint_Action` observation that selects no work, additive `Flush`, or complete
  `Compact` solely from the exact current view and persisted run ceilings; the caller still supplies every identity.
- An owned `L0_Checkpoint_Requirement` observation that carries the exact changed or nonempty family IDs from that
  same view in stable registry order, without retaining the database or reserving publication authority.
- Exact caller-selected two- or three-consecutive-run `Compact`, retaining every version/tombstone and all
  surrounding runs. The maintained shared acceptance workflow selects the two-run form, then crosses the persisted
  L0 ceiling and executes the exact complete-view replacement selected by `Observe_L0_Checkpoint_Requirement`.
- Synchronous and caller-composable `Add_Column_Family` over an exact retained checkpoint and any authenticated
  later commit suffix, with exact manifest/transition identities and same-receipt resolution of uncertainty.
- `Outcome_Unknown` receipts resolved only through the original identity; no application transaction or mutation is
  automatically replayed. Client-bound commit receipts may move with one caller scratch token through an
  owner-driven `Refresh_Operation`; storage-neutral reconciliation remains direct.
- `Close`, complete loss of process-local DB state, and synchronous or caller-composable `Open` recovery solely from
  authoritative object storage.
- Provider-neutral power-loss-durable Files and authenticated S3 runs of one shared complete database-level oracle.

The synchronous profile is the first user-facing entry point. Its client-backed Flush and family append wait on the
same DB operations and provider-owned Object Storage state machines as their caller-composable forms, so this
boundary does not create a second transport or certainty implementation.
Singleton `Commit` is provider-neutral at the DB layer: the limited root and operation-last forms retain the database
and completion set, admit the transaction synchronously, and wait on the existing coordinator worker. The blocking
form is a one-slot wait over the same operation. Atomic `Commit_Group` follows that identical provider-neutral
shape. Its structural `Members` discriminant must equal both Start and Finish array lengths; protected admission
moves every member arena in one cut, and the coordinator emits one wake only after all members share a terminal
classification. Pre-admission outcomes preserve every transaction. Post-admission cancellation and abandonment
drain the exact immutable group without replay, retaining its existing two-through-eight bound and caller-selected
batch identity.
The buffer-owned client-backed `Create` overload likewise waits its reusable `Create_Operation`. Manifest and HEAD
publication remain non-replaying, and an existing or ambiguously published HEAD is resolved through the shared
cacheless recovery traversal before one complete engine is installed. The storage-neutral synchronous overload
remains direct and source-compatible. Receipt-driven `Resolve_Create` uses that identical operation and typed
`Finish`: Start moves the self-contained receipt and scratch token, authenticates the retained immutable bytes
against the provider, admits the exact HEAD only from the definite `Manifest_Confirmed` phase, and performs only
read-based recovery from `Head_Publication_Unknown`. The buffer-owned synchronous form waits that same state machine.
Receipt-driven `Resolve_Flush` reuses `Flush_Operation` and its typed `Finish`: immutable uncertainty rebuilds only
the receipt-selected plan and identities, while possible or confirmed HEAD admission transfers the existing
checkpoint lifecycle admission into the shared bounded recovery traversal. The client-backed buffer overload waits
that operation; the storage-neutral resolver remains direct. Neither form replays a mutation or selects a new
identity.
Ambiguous `Commit_Receipt` resolution reuses `Refresh_Operation` because it is the same exclusive, quiescing,
authenticated recovery machine rather than another publication provider. Operation-last `Resolve` owns the receipt
and exact scratch token until its receipt-returning typed `Finish`; the client-backed blocking overload waits that
operation. A complete graph commits only the retained exact batch bytes, while a conclusive excluding successor
fences the writer. Successful installation reuses the live incarnation so existing family handles remain valid.
Neither form uploads, retries the application transaction, selects a replacement identity, or creates a helper task.
Receipt-driven `Resolve_Add_Column_Family` follows the same provider-centric boundary on `Flush_Operation`.
Immutable uncertainty authenticates the receipt's retained exact manifest bytes before the one permitted pending
HEAD admission. Possible or confirmed HEAD admission transfers the existing checkpoint lifecycle admission into
bounded recovery, which installs only a complete graph containing the exact family manifest and configuration.
Typed `Finish` restores the moved receipt and scratch token; the client-backed blocking overload waits that state
machine, while the storage-neutral resolver remains direct. No path selects a replacement identity or retries a
mutation.
The buffer-owned client-backed `Open` overload likewise waits the reusable `Open_Operation`; the established
storage-neutral synchronous overload remains direct and source-compatible because it accepts no caller-owned scratch
token. Both consume the same recovery request/validation machine and install only a complete authenticated graph.

## Acceptance scenario

One shared showcase-internal workflow, reached through both maintained provider-specific executables, must perform
the following sequence using only public Flyology.DB APIs:

1. Receive every database identity, object identity, column-family limit, database limit, timeout, provider endpoint,
   bucket, prefix, and credential choice explicitly from its fixture or caller.
2. Create a database with one explicit family, read its exact installed database configuration and complete family
   registry, observe no checkpoint work, and reopen the family by stable ID and exact name.
3. Commit exact byte keys and values, require the additive action, then Flush a complete first checkpoint and
   observe no remaining work. Commit one later root-family suffix without another Flush.
4. Append one independently bounded higher-ID family with caller-stable manifest and transition identities,
   require the pre-append suffix value to remain visible, then enumerate the complete two-family registry and
   reopen it by stable ID and exact name before reading both families' exact installed settings.
5. Atomically commit a group whose members affect both families, verify one all-or-nothing visible sequence, delete
   one key, verify ordered half-open scanning, require the additive action, and Flush the suffix without changing
   prior run identity; observe no remaining checkpoint work afterward.
6. Compact the exact adjacent root-family pair under caller-supplied output, manifest, and transition identities,
   then commit and sparsely Flush one later root-family update. Commit once more, require a complete-compaction
   action at the persisted L0 ceiling, and Compact the exact returned two-family projection under fresh
   caller-supplied identities; observe no remaining checkpoint work.
7. Close the database, discard every process-local DB object and buffer, construct a fresh database value, and Open
   it from the same object-store prefix.
8. Verify the exact surviving bytes, deletion, canonical scan order, highest visible sequence, persisted family
   handles, and unchanged installed database/family registry and configuration after recovery.
9. Close cleanly and report every non-success outcome without retrying a mutation or silently weakening certainty.

The public Files showcase and every authenticated provider-matrix lane call the same complete workflow. Each creates
the database, appends a family, performs cross-family commit and Flush, compacts the exact adjacent pair, performs
the observed complete replacement, closes, discards every provider/adapter/DB owner, reopens through a fresh scope,
and verifies identical bytes, deletion, scan order, sequence, and family handles. The provider shells differ only
where authority genuinely differs: Files creates its temporary bucket, while S3 requires an existing caller-owned
bucket plus endpoint, credentials, region, addressing style, and fresh prefix. RustFS, SeaweedFS, MinIO, and
Flyology memory, files, and SQLite therefore qualify the database-level acceptance oracle itself. S3, HTTP, signing,
retry, and endpoint policy remain outside Flyology.DB.

## Explicit exclusions

This profile does not include family rename/drop/reconfiguration, a family append without a retained checkpoint,
writer promotion, TTL, codecs, automatic execution or identity generation, garbage-collection policy, bucket
creation or cleanup,
background polling, transparent retry, retained borrowed request bodies, performance claims, or stable-format
compatibility beyond the versions accepted by the current decoder. Public complete-view `Compact` is deliberately
policy-neutral: the caller supplies every output and publication identity, and the operation retains predecessors.
Public exact two- and three-run compaction is likewise caller-selected and retains all history; fixed arity does not
authorize an automatic selector, fanout, pruning, or deletion. The replica spine remains qualification work until
separate public-policy decisions admit it.

The read-only configuration surface does not authorize a mutable configuration protocol. It returns only the exact
authority already installed in the current engine incarnation and supplies no defaults, migration, version upgrade,
ephemeral overrides, TTL, codec choice, or reconfiguration semantics.

Expansion starts only after the acceptance scenario, deterministic suite, provider matrix, repository gate, TLA+ and
TLAPS models, selected SPARK proof, API documentation, and findings cycle are green on one exact source/dependency
tree.

The authenticated walkthrough reuses this profile's exact shared workflow against an existing S3-compatible bucket.
The caller supplies a fresh prefix, endpoint, signing region, addressing style, positive timeout, and credentials.
The executable neither creates nor lists the bucket, retries a mutation, generates an application identity, nor
chooses cleanup/retention policy. All persisted limits, row bytes, and identities remain isolated deterministic
showcase geometry and are not database defaults.

## First additive expansion

The accepted profile remains the smaller baseline above. The first additive operation beyond it is synchronous
`Refresh_Replica`: one caller-triggered monotonic refresh of an already-open handle dedicated by the caller to
read-only replica use. It validates and installs one complete newer authoritative graph or leaves the prior view
unchanged. It adds no polling, helper task, retry, lease, registration, retention, promotion, or timeout default, and
a fenced handle remains fenced. Authenticated provider qualification exercises a deliberately stale checkpoint view
followed by one exact refresh to the writer's compacted view.

The additive composable `Create` surface moves one exact caller scratch token through root-manifest publication,
conditional HEAD publication, and any necessary read-only recovery. `Create_Operation`, its operation-last `Create`,
typed `Finish`, and the buffer-owned synchronous overload share one state machine and one receipt contract. A
definitely unadmitted HEAD remains safely resumable from `Manifest_Confirmed`; possible admission is never replayed
and is reconciled by authenticating the complete existing graph. The five-slot worst case derives from the nested
DB Create/recovery, Object Storage, HTTP, and transport owner stack. No helper task, retry, identity selection,
object-size bound, timeout default, or second API namespace is added. Operation-last and buffer-owned synchronous
`Resolve_Create` now reuse that same state machine rather than introducing a resolution operation or compatibility
namespace. Exact receipt ownership moves with the scratch token and returns only through the existing typed Finish.

The additive composable `Open` surface makes cacheless client recovery usable by owner-driven applications without
creating a parallel recovery algorithm. `Open_Operation`, its operation-last `Open`, typed `Finish`, and the
buffer-owned synchronous overload share one absolute deadline, cancellation source, exact caller scratch token, and
complete install boundary. Failed start, cancellation, insufficient scratch capacity, abandonment, and unexpected
local failure return the database lifecycle to Closed. This adds no helper task, retry, polling, identity policy,
buffer default, or storage-neutral API break.

The public `Required_L0_Checkpoint_Action` closes the policy-free observation seam between
persisted run ceilings and the already-public Flush/Compact algorithms without generating identities or scheduling
work. Memory/files qualification covers per-family, aggregate, and impossible replacement capacity; the
authenticated provider probe covers clean and additive decisions on the same public writer path.
`Observe_L0_Checkpoint_Requirement` exposes the same decision with an owned exact family projection. Successful
observation atomically replaces the caller's prior value; capacity or state failure leaves that value unchanged.
The projection is directly actionable through the existing Flush or Compact map after the application assigns one
fresh immutable run identity per returned family. The publication call revalidates the observed work and accepts the
exact sparse map; it retains compatibility with a full-family map by ignoring entries for families with no work.

The additive client-backed storage `Get` is the first read-side composable expansion. Its established
`Get_Operation`, typed `Finish`, and synchronous buffer overload resolve transaction-local mutations, the committed
suffix, and immutable checkpoint runs under one snapshot, deadline, cancellation token, and exact caller scratch
token. The maintained authenticated client fixture exercises suffix and checkpoint reads, restart, allocation,
cancellation, timeout, Serializable observation, and exact token restoration. This does not replace or silently
change the provider-neutral storage-free `Get` used by the Files acceptance showcase; direct memory/files lazy reads
remain a separate execution decision.

Authenticated scans use the same additive pattern. The compatibility `Start_Scan` operation traverses the exact
manifest run slice before cursor publication. `Start_Storage_Backed_Scan` instead retains exact run descriptors, and
its composable `Next_Scan_Page` operation advances at most one authenticated head per run through generation-bound
SST-v2 header/index/frame reads or the required frozen SST-v1 whole-object fallback. The page owns one caller scratch
token and deadline; typed `Finish` jointly publishes the candidate cursor and result. Neither path adds a second
visibility engine, retry, helper task, page default, run cap, or cache. Retained checkpoint state is proportional to
selected run count during paging. The authenticated whole `Scan` waits on that storage-backed initializer and one
complete page under a single absolute deadline; it no longer traverses every selected entry before cursor publication.
This does not remove persisted run-count or local/suffix-state bounds.
