# Replica refresh

## Existing synchronous boundary

`Refresh_Replica` performs one caller-triggered monotonic refresh of an already-open handle designated by its
caller for read-only replica use. It acquires the database's exclusive resolution lifecycle, drains previously
admitted calls, validates one complete authoritative recovery graph, and installs it only when the observed
`(HEAD transition number, writer epoch)` pair is newer than the installed pair. Equal or older valid observations
are discarded. Failure before installation leaves the prior engine exact, and a fenced handle remains fenced.

The operation has one caller-supplied monotonic budget and optional cancellation token. It does not poll, retry,
register a replica, acquire a lease, create a retention pin, or authorize promotion.

## Cacheless open reuse

Client-backed cacheless `Open` and replica refresh share the same internal recovery request/consume machine, but
they keep distinct public operation types and lifecycle contracts. `Open_Operation` admits only a closed `Database`,
copies the requested database identity, drives provider-owned Head/range/whole reads, and installs the recovered
engine only after the complete authenticated graph validates. Any typed failure, cancellation, abandonment, or
unexpected local exception aborts lifecycle admission and leaves the database Closed.

The operation-last `Open` moves one exact caller scratch token. Typed `Finish` restores that token into any vacant
same-pool handle before publishing a result or re-raising a saved unexpected exception. A buffer-owned synchronous
overload literally waits that operation. The established storage-neutral synchronous overload remains direct and
source-compatible because it has no caller scratch token and uses the backend-neutral blocking `Storage_Port`.
Neither form selects retry, polling, helper-task, buffer-size, identity, or promotion policy.

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

`Recovery_Traversal` now owns every manifest, run, and batch cursor plus the incomplete graph.
`Next_Recovery_Request` exposes one exact key-kind/generation/maximum request. The blocking adapter executes it
through `Storage_Port`; `Refresh_Operation` executes it through provider-owned Object Storage operations. Each
header request uses HeadObject to obtain the object length and opaque generation, followed by one exact
generation-bound range Get. The initial database HEAD whole Get is intentionally unconditional; immutable manifest
and SST body reads carry the generation authenticated by the preceding header request. The obsolete monolithic
traversal and its blocking manifest/SST wrappers have been removed.

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

The existing replica-refresh TLC/TLAPS lane remains the monotonic-install and fencing safety oracle. Deterministic
owner-stack coverage exercises completion-slot rollback, undersized-token rejection, pre-requested cancellation,
scope abandonment, a newer install, equal-head restart, typed Finish into a different same-pool handle, and
cacheless reopen. The authenticated provider matrix refreshes a deliberately stale replica through the
generation-bound checkpoint and batch path with no retry or mutation replay. Synchronous client refresh and the
composable path consume the same request/consume machine; memory and files retain blocking transport adapters. A
bounded test-only TCP proxy uses one Ada task to hold the first active whole Get, HeadObject, and generation-bound
range Get independently. For each provider-child shape, separate cases request cancellation or let the one absolute
deadline expire only after the proxy confirms the request is blocked. Typed Finish restores the exact moved token,
the old replica view remains installed after every terminal result, and a following unblocked refresh still installs
the complete newer graph. The proxy forces one request per connection, so the cold H1 connect child is exercised
inside the caller-owned completion set rather than hidden by a warm pooled connection.
