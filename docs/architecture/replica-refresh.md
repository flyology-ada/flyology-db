# Replica refresh

## Existing synchronous boundary

`Refresh_Replica` performs one caller-triggered monotonic refresh of an already-open handle designated by its
caller for read-only replica use. It acquires the database's exclusive resolution lifecycle, drains previously
admitted calls, validates one complete authoritative recovery graph, and installs it only when the observed
`(HEAD transition number, writer epoch)` pair is newer than the installed pair. Equal or older valid observations
are discarded. Failure before installation leaves the prior engine exact, and a fenced handle remains fenced.

The operation has one caller-supplied monotonic budget and optional cancellation token. It does not poll, retry,
register a replica, acquire a lease, create a retention pin, or authorize promotion.

## Composable API freeze

The additive composable form remains directly in `Flyology.DB`; lifetime discipline is expressed by its limited
operation and typed `Finish`, not by a second child namespace.

```ada
type Refresh_Operation
  (Set          : not null access Flyology.Operations.Completion_Set'Class;
   Item         : not null access Database;
   Storage      : not null access Storage_Context;
   HTTP         : not null access Flyology.HTTP.Client.Client;
   Payload_Pool : not null access Flyology.Buffers.Pool;
   Cancellation : access Flyology.Cancellation.Token) is
  new Flyology.Operations.Operation with private;

procedure Refresh_Replica
  (Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
   Timeout        : Duration;
   Operation      : in out Refresh_Operation);

procedure Finish
  (Operation      : in out Refresh_Operation;
   Result         : out Outcome_Code;
   Payload_Buffer : in out Flyology.Buffers.Unique_Buffer);
```

The operation-last `Refresh_Replica` accepts only a fresh or consumed operation whose owners match the open
database's exact
client-bound storage context. Completion-slot reservation and lifecycle admission happen before moving the acquired
same-pool token. Any initiation exception rolls both back and restores the exact token before propagation. A
successful start leaves the caller handle vacant until typed `Finish`, which accepts any vacant same-pool handle and
restores that exact token. The operation retains no pointer to the initiating handle.

This first form deliberately has no limited-root function. The established operation-last start is the smallest
additive surface consistent with the provider-centric Flyology convention; adding constructor syntax later is
source-compatible and does not justify delaying the owner-driven engine. The older `Start_Flush` spelling remains
source-compatible and does not require a second naming convention for new operations.

## Shared recovery reader

Blocking and composable refresh use one internal request/consume machine rather than two recovery algorithms. Its
owned phases are:

1. Read and authenticate the fixed HEAD image.
2. For each manifest from current to root, range-read the format header, bind the opaque object generation, then
   whole-read and decode that same generation. Preserve exact predecessor and checkpoint anchors.
3. For each run in the selected checkpoint, range-read and authenticate the SST header, then whole-read and decode
   the same generation under the persisted family limits.
4. If HEAD is newer than the checkpoint replay boundary, whole-read and decode each exact batch predecessor until
   the checkpoint boundary or root is anchored.
5. Return one complete owned recovery graph or one typed failure; never expose partial state.

Each request carries its exact object key, kind, range, expected opaque generation, and maximum accepted bytes. The
blocking adapter executes that request through `Storage_Port` and feeds the response back. The composable adapter
uses provider-owned Object Storage Head/range/whole operations in the caller's completion set, consumes each typed
child result before continuing, and reuses one moved destination token. The reader owns decoded manifests, SSTs,
batches, and immutable images until installation or cleanup; it retains no request-string or credential borrow.

All allocation extents remain lazily derived with checked arithmetic from the authenticated manifest's persisted
`Database_Limits`, per-family limits, exact header admission, and exact object lengths. An undersized caller buffer or
allocation failure is `Capacity_Exceeded`; it does not partially install a graph or change the prior replica view.

The shared reader now extracts the HEAD, manifest, SST, and batch consumers from blocking I/O. Each header
consumer retains the decoder-admitted object length and opaque generation; each body consumer accepts only that
exact length and generation before decoding. HEAD and batch consumers preserve the established format/status
normalization without retaining transport state. `Recovery_Traversal` owns every manifest, run, and batch
cursor plus the incomplete graph. `Next_Recovery_Request` exposes one exact
key-kind/generation/maximum request; the blocking adapter executes it and feeds the result to the matching
consumer. The obsolete monolithic traversal and its blocking manifest/SST wrappers have been removed. No
composable API is exposed by this intermediate refactor; the next stage drives these same requests with
provider-owned operations.

## Lifecycle and terminal rules

Composable resolution adds the same serialized quiescence wake used by composable checkpointing, but resolution and
checkpoint publication remain mutually exclusive database lifecycle modes. Before the first provider read, the
operation owns resolution admission and waits on the lifecycle wake, optional cancellation source, and its one
absolute deadline in one visible operation slot. Sequential provider children then use the remaining owner-stack
slots; no helper task or second protocol engine exists.

Cancellation consumes an already-terminal child before classification. Otherwise it cancels and drains the active
child, releases every incomplete recovery owner, cancels lifecycle resolution, and publishes `Cancelled`. Deadline,
capacity, corruption, unsupported-format, and storage failures likewise leave the old engine installed. Only a
fully validated strictly newer graph may allocate and atomically install a replacement engine. Equal/older valid
graphs complete successfully after cleanup. Unexpected local exceptions are retained until typed `Finish`, which
first consumes the operation and restores the token.

Scope abandonment follows the same order: cancel/drain the child, release the recovery graph, cancel any admitted
resolution lifecycle, then let the operation-owned buffer release its exact token to the pool. It never writes
through a possibly finalized caller handle.

## Qualification boundary

The existing replica-refresh TLC/TLAPS lane remains the monotonic-install and fencing safety oracle. The composable
implementation adds deterministic owner-stack coverage for quiescence, cancellation at every read phase, deadline,
undersized token, allocation rollback, equal/older observations, newer install, operation restart, typed Finish, and
scope abandonment. The authenticated provider matrix must refresh a deliberately stale replica through the
generation-bound checkpoint and batch path with no retry or mutation replay. Synchronous client refresh converges on
the same reader before the composable API is declared complete; memory and files may retain blocking transport
adapters while consuming the same request/consume kernel.
