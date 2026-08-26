# Review record

## Accepted recovery HEAD/batch consumer extraction candidate

- Parent: generation-bound recovery-consumer commit `d6962da`.
- Scope: extract fixed HEAD authentication and batch response/decode normalization from the blocking recovery loop.
  The loop issues the same requests, advances the same counters only after each provider return, and retains all
  predecessor/checkpoint anchoring in place. No public declaration, stored byte, request, limit, allocation, task,
  retry, deadline, cancellation, or lifecycle rule changes.
- Failure and ownership: HEAD length/version/database checks and batch missing/cancel/timeout/capacity/corruption
  mappings are exact copies of the prior branches. A failed batch consumer returns a vacant batch, and the enclosing
  recovery owner still releases every earlier history/checkpoint object on failure or exception.
- Verification and findings: the first sweep found one P1 sequencing drift: the extraction advanced the retained
  history count after every provider return rather than only after `Object_Read`. The failure slot was vacant, but
  the controller boundary must preserve exact ownership state; the count now advances at the original point. After
  that fix, `alr build`, `./tests/scripts/test.sh`, repository, diff, and 110-column checks pass on the exact tree. A
  repeated comparison against the parent finds no changed request, counter, decode, chain, allocation, cleanup,
  compatibility, or constants-authority behavior and no remaining actionable P0/P1/P2 finding.

## Accepted generation-bound recovery-consumer extraction candidate

- Parent: composable replica-refresh architecture commit `2f4eadb`.
- Scope: extract body-private manifest and SST header/body consumers from the existing blocking recovery path. The
  manifest and SST readers still issue the same bounded range followed by the same generation-bound whole read, then
  invoke the extracted consumers. No public declaration, lifecycle mode, storage request, timeout, task, retry,
  allocation limit, or persisted field changes in this stage.
- Authority and failure: header inspection retains the decoder-admitted object length rather than trusting only the
  provider-reported length. Whole-body decode requires that exact length and the header response's opaque generation.
  Allocation remains lazy and checked at the established manifest-header, manifest-image, SST-header, and SST-image
  fault points. Decode status maps to the same Capacity_Exceeded, Unsupported_Format, or Corrupt outcomes, and every
  partially allocated image/checkpoint/SST is released on typed failure or exception.
- Verification: the root/test builds and `./tests/scripts/test.sh` pass, including deterministic memory/files
  recovery, complete-compaction close/local-loss/reopen, corruption and allocation-fault cases, the authenticated
  client-backed refresh/reopen probe, 32 comparative cases, and pinned TidesDB 4/4. The exact-tree TLA/TLC/TLAPS
  gate passes every maintained lane, including the 1,460-state replica-refresh model and 3,145,728-state partial
  merge. `./scripts/prove.sh` proves 1,097/1,097 warning-strict checks and the post-run formal-process audit is
  clean. The provider matrix passes all six implementations three times each. Repository, diff, and 110-column
  checks are green.
- Findings cycle: the first sweep found one P1 authority drift where the extracted records kept the raw
  provider-reported length instead of the stronger decoder-admitted length used by the prior code. Both manifest and
  SST consumers now retain the decoder result exactly. Repeated generation, length, decode, allocation, cleanup,
  exception, compatibility, constants-authority, documentation, and unnecessary-surface review finds no remaining
  actionable P0/P1/P2 finding.

## Accepted composable replica-refresh architecture candidate

- Parent: complete-compaction limited-profile integration commit `b487c9b`.
- API and scope: colocate private-completion-state `Refresh_Operation`, same-name operation-last
  `Refresh_Replica`, and typed `Finish` directly in `Flyology.DB`. The existing synchronous overload remains exact.
  The new operation carries caller-owned completion-set, database, client-bound storage, HTTP client, buffer-pool,
  and optional cancellation owners. One acquired same-pool buffer moves only after slot reservation and lifecycle
  admission; typed Finish is its sole handle restoration authority. No limited-root function, child namespace,
  compatibility wrapper, public constant, default, role flag, or persisted field is introduced.
- Execution design: extract one explicit recovery request/consume machine from the blocking traversal. Blocking
  storage adapters execute its requests synchronously; the composable adapter drives provider-owned range/whole
  children serially in the caller's owner stack. Both validate the same HEAD, manifest predecessor chain,
  generation-bound SSTs, replay anchor, and batch predecessor chain, and return only one complete owned graph. One
  deadline covers quiescence and every read. No helper task, provider retry, or second recovery algorithm exists.
- Safety and failure: all allocations remain lazy, checked, and derived from persisted database/family limits and
  authenticated object lengths. Cancellation consumes a terminal child before classification; otherwise it drains
  the active child, releases the partial graph, cancels resolution admission, and preserves the old engine. Equal or
  older valid graphs are discarded; only a complete strictly newer graph installs. Abandonment drains first, then
  releases recovery owners and the operation token to its pool without retaining the original caller handle.
- Findings cycle: the first API sweep found one P2 naming/order inconsistency in the draft `Start_Refresh_Replica`
  signature. Replacing it with the provider-centric same-name operation-last overload avoids a second naming
  convention. Repeated API, ownership, lifecycle, cancellation, deadline, allocation, compatibility,
  constants-authority, documentation, and unnecessary-surface review finds no actionable P0/P1/P2 finding. This is
  an architecture freeze only; implementation and its deterministic/formal/provider evidence remain explicitly
  pending and no runtime qualification is claimed by this record.

## Accepted complete-compaction limited-profile integration candidate

- Parent: sparse checkpoint-map execution commit `ed2fb6a6d9a919ac1a26295389e1fa0ebdaca071`.
- Scope and behavior: extend only the maintained public Files-backed acceptance executable and its architecture
  narrative. After exact adjacent compaction, the fixture commits one later update, executes the observed sparse
  additive Flush, commits again at the persisted L0 ceiling, observes the exact two-family complete-compaction
  requirement, and passes that projection to the existing complete `Compact`. It verifies no remaining work, closes
  every process-local owner, and recovers the final bytes, deletion, scan order, family handles, and sequence from
  object storage alone. No library implementation, API, scheduler, retry, provider policy, or identity generator is
  added.
- Constants and compatibility: the fixture's persisted manifest-history limit increases from five to seven for the
  exact root/Flush/family-append/Flush/adjacent/sparse-Flush/complete manifest chain. Its checkpoint identity limit
  increases from eight to nine for the exact six singleton transaction identities plus two grouped members and one
  group batch identity. IDs 25 through 33 name only the new fixture transactions and immutable publications. Adjacent
  comments record that authority and its persisted fixture impact; no product default or inferred ceiling changes.
- Verification: `./tests/scripts/test.sh` passes the root/test builds, repository gate, deterministic memory/files
  suite, expanded Files showcase, crash/recovery corpus, authenticated client probe, 32 comparative cases, and pinned
  TidesDB 4/4. `./scripts/check-tla.sh` passes every maintained model, including 2,240 L0-selection states and 8/8
  obligations with its complete-compaction witness. `./scripts/prove.sh` proves 1,097/1,097 warning-strict checks and
  the post-run formal audit is clean. The six-provider matrix passes all 18 RustFS, SeaweedFS, MinIO, and Flyology
  memory/files/SQLite lanes against Object Storage `179b16c…` and HTTP/QUIC `eb09a80…`. Repository, diff, and
  handwritten-Ada line-width checks are clean. GNATformat and GNATdoc are absent from the selected toolchain, so no
  formatter or generated-site claim is made.
- Findings cycle: the first sweep found one P2 oracle weakness because complete compaction checked only receipt
  arity. The corrected showcase checks both exact family/run entries plus manifest and transition identities before
  reopen. Repeated behavior, recovery, identity, persisted-capacity, constants-authority, documentation,
  compatibility, test, formal-boundary, and unnecessary-surface review finds no actionable P0/P1/P2 finding.

## Accepted sparse checkpoint-map execution candidate

- Parent: owned exact-family checkpoint-requirement commit `1b8190175553fa2f1e34ff5a4ac731a42407f571`.
- API and scope: relax the existing Flush and complete Compact family/run maps to accept the exact affected-family
  projection already returned by `Observe_L0_Checkpoint_Requirement`. No declaration, overload, default, timeout,
  identity generator, scheduler, retry, or public capacity is added. Additive Flush still rejects an empty map;
  complete replacement accepts one only when the complete view produces no SST.
- Validation and certainty: under the existing exclusive checkpoint lifecycle, the planner derives the complete
  required-family projection before any SST allocation, rejects a missing required family with definite
  `Invalid_State`, and publishes nothing. Duplicate families or run IDs, unknown families, zero IDs, and operation-ID
  collisions retain their established prepublication rejection. The provider publication order, absolute deadline,
  mutation certainty, same-identity reconciliation, owner-stack operation, buffer move/restore, and no-replay rules
  are unchanged.
- Compatibility and authority: legacy full-family maps remain accepted. Entries for empty or unchanged families are
  retained as caller-supplied reconciliation input but produce no immutable object and reserve no identity. The
  authenticated fixture reuses one such ignored value for a later affected-family run. Sparse maps select no policy:
  every run, manifest, and transition identity remains caller-owned, while the required domain derives only from the
  persisted family state and limits.
- Verification: `./tests/scripts/test.sh` passes the root/test builds, repository/provenance gate, deterministic
  memory/files suite, limited Files end-to-end showcase, crash/recovery corpus, authenticated client-backed
  create/commit/Flush/compaction/refresh/reopen probe, 32 comparative cases, and pinned TidesDB 4/4. The complete
  TLA+/TLAPS gate remains green, including 2,240 checkpoint-selection states and 8/8 selection obligations. The
  warning-strict SPARK gate proves 1,097/1,097 selected-unit checks. The six-provider matrix passes all 18 RustFS,
  SeaweedFS, MinIO, and Flyology memory/files/SQLite lanes against Object Storage `179b16c…` and HTTP/QUIC
  `eb09a80…`. Exact post-formal host audit, repository check, line-width audit, and `git diff --check` are clean.
  GNATformat and GNATdoc are absent from the selected Alire toolchain, so no formatter or generated-site claim is
  made.
- Findings cycle: the first sweep fixed one P2 ordering weakness by validating every required family before any
  transient SST allocation. It also corrected one P2 authenticated receipt assertion that still expected a removed
  no-work mapping. Repeated API, concurrency, allocation, publication, certainty, compatibility, constants,
  documentation, test, formal-boundary, and unnecessary-surface review finds no actionable P0/P1/P2 finding.

## Accepted owned exact-family checkpoint-requirement candidate

- Parent: limited-profile checkpoint-observation integration commit `0d377f9`.
- API and scope: add limited private `L0_Checkpoint_Requirement`, one synchronous atomic observation procedure, and
  read-only action/count/index accessors directly in `Flyology.DB`. The owned value retains suffix-changed family IDs
  for additive Flush, complete-view nonempty family IDs for complete compaction, and none for no work. Stable registry
  order is preserved. The existing action-only query remains source-compatible and uses the same observation kernel.
- Authority and ownership: family storage is allocated lazily at the exact selected count derived from the persisted
  registry, with no new public/default capacity. A private controlled component reclaims it automatically; the public
  type is limited but deliberately non-derivable and retains no database borrow. Complete compaction with no live
  families is valid and retains an empty set. Successful observation swaps the whole action/set pair; state or
  allocation failure leaves the prior value exact and publishes nothing.
- Concurrency and certainty: the operation uses the existing exclusive checkpoint lifecycle and one coherent writer
  view. It performs no provider I/O, reserves no identity, schedules no work, and grants no admission authority. A
  later commit may invalidate the result, and the caller-selected Flush/Compact path revalidates every persisted
  bound before publication.
- Verification: `./tests/scripts/test.sh` is green, including memory/files allocation rollback, no-admissible
  preservation, out-of-range access, complete zero-family projection, authenticated client use, crash/recovery, and
  the owned limited Files showcase. `./tests/scripts/test-s3-matrix.sh` passes all 18 RustFS, SeaweedFS, MinIO, and
  Flyology memory/files/SQLite lanes against Object Storage `179b16c…` and HTTP/QUIC `eb09a80…`. The selection model
  remains 2,240 states at depth 2 with all four branches covered; its witness validates the exact complete family set
  and TLAPS proves 8/8 action/projection obligations. The maintained warning-strict SPARK gate proves 1,097/1,097
  selected-unit checks; the exact post-run audit is clean. Repository and diff checks pass. GNATformat is absent from
  this host's selected Alire toolchain, so no formatter claim is made; every changed handwritten Ada line is within
  110 columns. GNATdoc is likewise unavailable, so no generated-site claim is made.
- Findings cycle: the API review found one P2 unnecessary visibly tagged/derivable type; a private controlled holder
  restores the intended limited-private surface. The implementation sweep found one P1 rejection of the legitimate
  all-tombstoned complete-compaction empty set; accepting the empty projection and adding the exact regression fixes
  it. The repeated API, concurrency, allocation, lifecycle, certainty, constants, tests, formal-model, documentation,
  compatibility, and unnecessary-surface sweep finds no actionable P0/P1/P2 finding.

## Accepted limited-profile checkpoint-observation integration candidate

- Parent: public L0 checkpoint-action observation commit `dbff9d6`.
- Scope and behavior: route the maintained Files-backed public acceptance executable through
  `Required_L0_Checkpoint_Action` at fresh, dirty, and successfully checkpointed boundaries. The showcase requires
  additive Flush before each caller-identified checkpoint and no work afterward. Its exact adjacent compaction
  remains an explicit independent caller selection; the change adds no automatic execution, identity generation,
  trigger, fanout, retry, or provider policy.
- Verification and findings: `./showcases/run-limited-e2e.sh` rebuilds and passes the complete create, transaction,
  family append, cross-family Flush, adjacent compaction, close, complete-local-loss, and authoritative reopen path.
  Project-aware GNATformat was applied only to the new helper and call ranges; repository diff checks are clean.
  The API, sequencing, certainty, constants, documentation, and unnecessary-surface sweep finds no actionable
  P0/P1/P2 finding.

## Accepted public L0 checkpoint-action observation candidate

- Parent: public one-shot monotonic replica refresh commit `4ec2816`.
- API and scope: add `Required_L0_Checkpoint_Action` directly in `Flyology.DB` to observe whether the exact current
  persisted authority requires no work, additive `Flush`, or complete `Compact`. The call reserves no identity,
  performs no object-storage I/O, starts no task, and is not a scheduler or reservation; the later caller-selected
  publication revalidates every bound and precondition.
- Authority and allocation: the selector distinguishes suffix-changed families from complete-view nonempty families
  and applies each persisted `Maximum_L0_Runs` plus `Maximum_Total_L0_Runs`. Runtime scratch is allocated lazily at
  the exact validated persisted family count with checked arithmetic. Invalid authority fails closed as `Corrupt`;
  a representation that fits neither publication shape returns definite `Capacity_Exceeded`; allocation failure
  publishes nothing and is safely classified before any provider effect.
- Concurrency and ownership: the observation uses the established exclusive checkpoint lifecycle, drains active
  work, snapshots one coherent writer view, and releases the lifecycle on every normal or exceptional path. It
  retains no caller borrow or storage lease after return. A later commit may change the answer, which is stated in
  the public contract and prevents callers from treating the observation as conclusive admission.
- Verification: root/test builds, `./tests/scripts/test.sh`, and the uninterrupted six-provider/three-run matrix are
  green on Object Storage `179b16c…` and HTTP/QUIC `eb09a80…`. The new finite model exhausts 2,240 states at depth 2
  with nonzero coverage of all four internal decisions; its complete-compaction witness validates and TLAPS proves
  4/4 branch obligations. The warning-strict selected SPARK gate proves 1,097/1,097 checks, including all five new
  selector checks, and the exact post-run host audit is clean. Root/test project-aware GNATformat was applied only to
  changed ranges/new units; GNATdoc is unavailable in this host toolchain, so no generated-site claim is made.
- Findings cycle: the first sweep found one P2 fixed-size 64-family scratch allocation and one P2 stale test-authority
  comment. Exact persisted-family-sized scratch state and corrected adjacent authority wording fix both. The repeated
  API, concurrency, allocation, certainty, constants, tests, formal-model, documentation, and unnecessary-surface
  sweep finds no actionable P0/P1/P2 finding.

## Accepted public one-shot monotonic replica refresh candidate

- Parent: published dependency-chain qualification commit `e38ea25`.
- API and scope: expose the already-qualified synchronous refresh directly in `Flyology.DB` as
  `Refresh_Replica`, remove the private testing forwarding declaration, and route deterministic memory/files plus
  authenticated client coverage through the public operation. The caller designates an open handle for read-only
  replica use, finishes its active transactions, and supplies the operation's only monotonic timeout budget.
- Authority and behavior: refresh drains the existing lifecycle, validates one complete authoritative recovery
  graph, and atomically installs only a newer transition-number/writer-epoch pair. Same or older valid observations
  are no-ops; recovery or allocation failure preserves the prior engine; a fenced handle remains `Stale_Writer`.
  The operation adds no helper task, polling, retry, lease, registration, retention, promotion, persisted field,
  allocation limit, or default.
- Ownership and concurrency: the operation retains no caller input beyond the synchronous call and reuses the
  established exclusive resolution lifecycle. The authenticated probe opens one stale checkpoint view, lets the
  writer append families, Flush, and compact, verifies the stale bytes, then performs one refresh and reads the exact
  final compacted bytes. No mutation is replayed and object storage remains the sole durable authority.
- Verification: root/test builds and `./tests/scripts/test.sh` are green; the uninterrupted six-provider/three-run
  matrix is 18/18 at Object Storage `179b16c…` and HTTP/QUIC `eb09a80…`; GNATdoc renders the operation and all four
  parameter descriptions; the complete TLA/TLC/TLAPS gate is green, including replica refresh at 1,460 states and
  11/11 obligations with stale-writer/rollback negative probes; GNATprove proves 1,091/1,091 checks and the exact
  post-run host audit is clean. Project-aware GNATformat 26 loads the dependency graph, but its unconfigured baseline
  rewrites thousands of untouched lines even under `--gitdiff`; that mechanical output was fully rejected, and every
  changed handwritten Ada line remains within 110 columns.
- Findings cycle: the first sweep found one P2 stale “private witness” comment after public promotion; it is corrected.
  The repeated API, role, monotonicity, fencing, lifecycle, allocation rollback, certainty, constants, tests, proof,
  documentation, formatting, compatibility, and unnecessary-surface sweep finds no actionable P0/P1/P2 finding.

## Accepted Object Storage and HTTP hook-selection dependency candidate

- Parent: public exact-three-run compaction commit `c87f926`.
- Scope and provenance: fast-forward only the clean ignored `.deps/flyology-object-storage` build clone from
  `1978275b…` to published source `179b16c414090662924c04355a5d292c29d33204`, then record Alire index
  `ade6ebbddd254f9fa0515fa8bb11397427d0a76b`. The root filesystem pin and exact
  `flyology_object_storage = "=0.1.0-dev"` constraint remain unchanged. The ignored solve selects unpinned
  HTTP/QUIC 0.1.3-dev at `eb09a80a7e06274e93289861c2cae1ca7e8cb1af`; no external transport pin is added.
- API and behavior: the dependency update is additive outside the DB-consumed `Client.Objects` conditional Put,
  whole/range Get, and Head contracts. DB source, ownership, deadlines, cancellation, publication certainty,
  same-identity reconciliation, and non-replay rules do not change. New bucket-control operations grant no DB policy
  and are not consumed by this unit.
- Verification and findings: the root/test build, deterministic suite, authenticated provider matrix, repository
  gate, warning-strict DB proof, exact host audit, and dependency cleanliness are rerun against the exact fast-forward
  before commit. The review covers API drift, transport origin, pin state, mutation replay, certainty mapping,
  formatter baseline, and unnecessary surface; no actionable P0/P1/P2 finding remains after qualification.

## Accepted public exact-three-run compaction candidate

- Parent: APM dependency-isolation commit `28e35bc` over the qualified private three-run publisher.
- Scope and API: add operation-last `Start_Compaction` and blocking `Compact` overloads directly in `Flyology.DB`
  for exactly three caller-selected consecutive current runs. They reuse `Flush_Operation`, typed token-restoring
  `Finish`, `Flush_Receipt`, and `Resolve_Flush`; no new type, constant, default, selector, compatibility namespace,
  helper task, retry, trigger, level, schedule, retention horizon, pruning rule, or deletion rule is introduced.
  Three is the already-qualified algorithm shape, not a product fanout or maintenance policy.
- Ownership and certainty: both overloads delegate to the existing three-run publisher and owner-stack driver. The
  operation copies all selected/publication identities and moves the exact caller buffer only after validation,
  lifecycle admission, and slot reservation. Typed `Finish` remains the sole restoration authority. Any possibly
  admitted immutable-object or HEAD failure retains `Outcome_Unknown` and is reconciled read-only from the same
  identities and bytes; no mutation is replayed.
- Durability and bounds: the current authenticated manifest must contain the three exact adjacent descriptors in one
  family. The merge retains every version and tombstone, surrounding descriptors, later committed suffixes, and
  predecessor objects. Allocation remains lazy, checked, and derived from persisted database/family limits and exact
  authenticated object shapes; failure before provider admission publishes nothing.
- Verification: root and test builds and `./tests/scripts/test.sh` pass on the public path. The uninterrupted provider
  matrix passes all 18 RustFS, SeaweedFS, MinIO, and Flyology memory/files/SQLite lanes against Object Storage
  `1978275b…` with indexed HTTP/QUIC `eb09a80…`. `./scripts/check-tla.sh`
  passes every maintained lane, including the 12,288-state three-run model with 7/7 TLAPS obligations and the
  deliberately broken tombstone-loss negative probe. `./scripts/prove.sh` proves 1,091/1,091 warning-strict selected
  checks and the exact post-run host audit is clean. The repository and diff gates are green. Project-aware
  GNATformat 26 now loads the dependency graph after the HTTP hook-selection update, but its unconfigured default
  style proposes broad existing repository/dependency rewrites; those formatter-only changes were removed, so no
  mass-format or formatter-clean claim is made. All changed handwritten Ada is independently checked at no more than
  110 columns.
- Findings cycle: the API/constants review confirms that fixed arity is documented adjacent to both declarations and
  introduces no limit/default policy. The implementation reuses one state machine rather than a second engine, and
  the public client probe covers definite pre-admission failure, exact token restoration, uncertain output
  reconciliation, successful publication, retained-family state, and cacheless reopen. No actionable P0/P1/P2
  finding remains after final qualification.

## Accepted TidesDB adapter readiness candidate

- Parent: adjacent-compaction limited-profile showcase commit `63e7767`.
- Problem and scope: a pure-helper adapter test can finish before its `run.sh` child completes the maintained
  validate/build/exec sequence. Closing stdin during that pre-exec phase does not reach the Python protocol, so
  ordinary build latency can exceed the established teardown wait and report a false leaked-process failure. The
  change is test-harness only; it does not alter a DB, adapter, TidesDB, timeout, retry, or compatibility contract.
- Solution and lifecycle: `Protocol` now completes one ordinary `capabilities` request/response during construction.
  Every test therefore begins only after `run.sh` has exec'd the adapter and the protocol consumes stdin. Teardown
  retains its established timeout and EOF behavior; no wait value is raised and no failure is masked by forced
  termination. Subsequent request identifiers advance normally and remain checked against each response.
- Verification: the formerly failing pure-helper test passes ten consecutive fresh-process runs. The focused
  `./oracles/adapters/tidesdb/scripts/test.sh` gate passes 32/32 adapter tests, 4/4 pinned upstream tests, and every
  workload fixture. The complete `./tests/scripts/test.sh` gate then passes, including the public Files showcase,
  authenticated DB client, crash/recovery probes, comparative adapters, and another 32/32 plus 4/4 TidesDB pass.
- Findings cycle: readiness uses an existing protocol command and adds no timing constant, platform branch, or
  subprocess ownership path. The final correctness, process-lifecycle, protocol, constants, portability, test, and
  unnecessary-surface sweep has no actionable P0/P1/P2 finding.

## Accepted adjacent-compaction limited-profile showcase candidate

- Parent: public exact-adjacent compaction commit `4423d1e`.
- Scope: extend only the public power-loss-durable files showcase and limited-profile documentation. After the
  established two-family suffix Flush, the executable supplies the exact adjacent root-family pair and fresh output,
  manifest, and transition identities to blocking `Compact`, verifies the self-contained receipt, verifies the live
  two-family view, closes every DB/provider owner, and recovers the same bytes and family handles from object storage
  alone. No library implementation, API, default, provider behavior, retry, selection, pruning, or deletion policy
  changes.
- Limits and constants: the persisted manifest-history fixture limit increases from four to five because its exact
  scenario now contains root, first Flush, family append, suffix Flush, and adjacent successor manifests. IDs 20--22
  are adjacent-documented output/manifest/transition fixture roles, and reader identities advance to avoid reusing
  them. All other limits remain caller-selected persisted authority; no product ceiling is inferred.
- Verification: the standalone `./showcases/run-limited-e2e.sh` passes. The first full-suite attempt passed every DB,
  files crash/reopen, showcase, and authenticated client gate but hit a pre-existing TidesDB subprocess teardown
  timeout. No orphan remained; the focused adapter rerun passed 32/32 plus 4/4 pinned upstream tests, and the following
  complete `./tests/scripts/test.sh` rerun passed. Repository and diff checks are green, and the exact-tree
  `./scripts/prove.sh` confirmation proves 1,091/1,091 warning-strict checks with a clean post-run audit. The
  production implementation, public contract, formal models, and selected SPARK units are unchanged.
- Findings cycle: the first compile found that equality for the private `Checkpoint_Run_Identity` result type needed
  an explicit `use type`; it was fixed without opening representation. The API/authority sweep then replaced an
  attempted private-component read with the caller's original stable run identities. The final correctness,
  durability, ownership, bounds, constants, documentation, test, and unnecessary-surface sweep has no actionable
  P0/P1/P2 finding in this unit.

## Accepted public exact-adjacent compaction candidate

- Parent: public complete-view compaction commit `3fa6dfe`.
- Scope and API: overload the established `Start_Compaction` and `Compact` names directly in `Flyology.DB` for one
  exact caller-selected adjacent pair, reusing `Flush_Operation`, typed token-restoring `Finish`, `Flush_Receipt`, and
  `Resolve_Flush`. The caller supplies both selected run identities and fresh output, manifest, and transition
  identities. No public type, constant, default, selector, trigger, level, fanout, schedule, retry, retention horizon,
  pruning rule, deletion rule, helper task, or compatibility namespace is introduced.
- Ownership and certainty: the composable overload copies every identifier, validates operation/storage/pool owners,
  reserves the parent slot and lifecycle checkpoint, and only then moves the caller's exact buffer token. Initiation
  exceptions roll back lifecycle, slot, and token ownership. Typed `Finish` is the sole normal token-restoration path
  and accepts any vacant same-pool handle. Any possibly admitted object or HEAD result remains `Outcome_Unknown` and
  is reconciled read-only from the exact retained identities; no mutation is replayed under a new identity.
- Durability and bounds: current manifest authority must contain the exact adjacent descriptors in one family. The
  merge retains every version and tombstone, preserves surrounding runs and any later committed suffix, confirms the
  immutable output and successor before conditional HEAD, and retains predecessor objects. All allocation extents
  remain lazy checked derivations from persisted database/family limits and authenticated object shapes; failure
  before provider admission publishes nothing.
- Verification: `./tests/scripts/test.sh` passes the local engine, files crash/reopen, limited showcase, comparative
  adapters, and authenticated client probe. The provider matrix passes all 18 RustFS, SeaweedFS, MinIO, and Flyology
  memory/files/SQLite lanes on Object Storage `1978275b…`. `./scripts/check-tla.sh` passes every maintained lane,
  including 3,145,728 partial-merge states, 5/5 TLAPS obligations, and the dropped-tombstone negative probe.
  `./scripts/prove.sh` proves 1,091/1,091 warning-strict checks; repository and diff gates are green. GNATformat and
  GNATdoc are unavailable in the installed toolchain, so no formatter or extracted-site result is claimed.
- Findings cycle: the API/constants sweep confirmed that the cancellation token is mandatory rather than a new null
  default and that no new public value or capacity was introduced. The first documentation sweep fixed stale private
  surface wording, the client probe now exercises the public operation and exact token restoration, and an internal
  comment was corrected to identify the now-public caller-selected publisher. The final correctness, crash-safety,
  concurrency, ownership, bounds, format, storage, certainty, API, test, documentation, and unnecessary-surface sweep
  has no actionable P0/P1/P2 finding.

## Accepted public complete-view compaction candidate

- Parent: caller-composable column-family append commit `afe1b21`.
- Scope and API: expose established-operation `Start_Compaction` and blocking `Compact` directly in `Flyology.DB`, reusing
  the established limited `Flush_Operation`, typed token-restoring `Finish`, `Flush_Receipt`, and `Resolve_Flush`.
  The caller supplies the complete family/output map and stable manifest/transition identities. No result type,
  public constant, default, trigger, run selector, level, fanout, schedule, retry, retention horizon, deletion rule,
  helper task, or compatibility wrapper is introduced. Partial-run merge publication remains private.
- Implementation and ownership: one mode-selected checkpoint driver now owns both blocking Flush and Compact.
  Client storage waits on the same caller-driven operation used by `Start_Compaction`; memory/files use the existing
  backend-neutral publisher with the identical complete-replacement plan. The run map is copied before return, the
  exact scratch token remains operation-owned until typed Finish or finalization drain, and every normal owner borrow,
  absolute deadline, cancellation, and same-identity reconciliation rule remains unchanged.
- Certainty, bounds, and durability: all persisted and transient extents remain lazily derived with checked arithmetic
  from `Database_Limits`, per-family limits, exact encoded shapes, and caller buffer capacity. Definite prepublication
  failure publishes nothing. Any possibly admitted immutable-object or HEAD failure remains `Outcome_Unknown`; the
  original receipt alone authorizes read-only exact-byte/transition resolution. Complete outputs and the immutable
  successor are confirmed before conditional HEAD. Superseded objects remain stored and gain no deletion authority.
- Verification: `./tests/scripts/test.sh` passes the local engine, Files crash/reopen, limited showcase, comparative
  adapters, and authenticated client probe. The probe covers public composable lost-run-response reconciliation,
  exact token restoration, blocking lost-HEAD-response reconciliation, and three-family cacheless reopen. The full
  provider matrix passes all 18 RustFS, SeaweedFS, MinIO, Flyology memory/files/SQLite lanes. `./scripts/check-tla.sh`
  passes every maintained lane, including 35-state complete replacement, 576-state read equivalence, and 3,145,728
  partial-merge states with all TLAPS obligations and negative probes. `./scripts/prove.sh` proves 1,091/1,091
  warning-strict selected checks; repository and diff gates are green. GNATdoc is unavailable in the installed
  toolchain, so no extracted-site build is claimed.
- Findings cycle: the first API/ownership sweep fixed one P1 documentation ambiguity that incorrectly implied no
  caller-owned state was retained after Start; the contract now distinguishes the copied run map from the moved token
  and normal operation-owner borrows. The constants sweep removed an unauthorized new public null-token default and
  replaced an unverified fixture-count explanation with the exact prior-sixteen-plus-four identity-role derivation.
  The final correctness, crash-safety, concurrency, ownership, bounds, format, storage, certainty, API, test,
  documentation, and unnecessary-surface sweep has no actionable P0/P1/P2 finding.

## Accepted caller-composable column-family append candidate

- Parent: authenticated cross-provider family-append qualification `ac1dcd0`.
- Scope and API: add an operation-last `Add_Column_Family` overload and receipt-shaped typed `Finish` directly in
  `Flyology.DB`, reusing the established `Flush_Operation`. Scoped lifetime is expressed by the limited operation,
  caller-owned completion set, retained owner borrows, cancellation/drain protocol, moved token, and typed Finish;
  no parallel `.Scoped` package, alias, helper task, default, or second state machine is introduced. Client-backed
  synchronous append is now a literal wait over this operation; memory/files retain their backend-neutral publisher.
- Ownership and certainty: slot and lifecycle admission precede moving the exact caller buffer token. Initiating
  exceptions roll back admission and ownership exactly. Terminal family Finish accepts any vacant same-pool handle,
  restores the exact token, and transfers the self-contained receipt. A runtime result discriminator rejects the
  wrong receipt-shaped Finish before consuming either result or token. Manifest/HEAD ambiguity retains the exact
  bytes, identities, expected generation, and transition for read-only resolution; no mutation is replayed.
- Bounds and activation: the synchronous scratch extent adds the exact incoming family name and frozen format
  framing to persisted live-state, run, identity, and family authorities with checked arithmetic. Composable planning
  lazily builds the complete activation graph only after admission. Allocation or undersized caller scratch fails
  safely with no partial publication.
- Verification and findings: the maintained client probe covers prepublication one-byte scratch failure and identity
  reuse, wrong-Finish rejection without consumption, post-admission unknown HEAD resolution, exact token restoration,
  blocking wait equivalence, and cacheless reopen of three families. `./tests/scripts/test.sh` is green, and the full
  provider matrix passes all 18 RustFS, SeaweedFS, MinIO, Flyology memory/files/SQLite lanes. `./scripts/check-tla.sh`
  passes every maintained TLC/TLAPS lane, including 3,145,728 partial-merge states; `./scripts/prove.sh` proves
  1,091/1,091 warning-strict selected checks. Repository and diff checks are green. GNATdoc is unavailable in the
  installed toolchain, so the public leading comments are compiler- and repository-checked but no extracted-site
  build is claimed. The final API, ownership, certainty, bounds, constants, provider, test, documentation, and
  unnecessary-surface sweep has no actionable P0/P1/P2 finding.

## Accepted authenticated cross-provider family-append qualification

- Parent: published Object Storage provenance update `492edad` over synchronous family append `b95df46`.
- Scope: strengthen only the maintained authenticated client probe. After its first checkpoint, it appends one
  caller-configured family with distinct key, value, memtable, and L0 limits; deliberately loses the conditional HEAD
  response after possible admission; resolves only through the original receipt; writes both families atomically;
  Flushes both; compacts the original family; closes; and cachelessly reopens and verifies both exact values. No
  production source, public declaration, persisted format, retry, timeout, provider policy, or allocation behavior
  changes in this qualification unit.
- Authority and bounds: the probe expands only its persisted fixture geometry from one to two families, six to seven
  retained manifests, and three to four total L0 runs. Adjacent source comments tie those values and every new
  object identity to the exact corpus path; none is a DB default. The second family's complete policy remains caller
  authority and deliberately differs from the initial family.
- Verification: `./tests/scripts/test.sh` passes the repository, local engine, authenticated memory server,
  power-loss Files, limited showcase, 32 comparative, and TidesDB 4/4 gates. The maintained S3 matrix passes all
  18 lanes: RustFS, SeaweedFS, MinIO, Flyology memory, files, and SQLite, three repetitions each, against exact
  Object Storage `1978275b4c4cd4704adc41ec52b167a7587b411f`. Every lane reports the complete
  `create/append/commit/Flush/compaction/reopen` sentinel.
- Findings cycle: the first constants/test-oracle sweep fixed a P2 accidental gap in the remapped one-byte object-ID
  sequence and corrected a stale single-family comment. API, ownership, certainty, bounds, provider compatibility,
  recovery, test-oracle, and unnecessary-surface re-review finds no actionable P0, P1, or P2 finding. The production
  source and selected proof units are unchanged from the warning-strict 1,091/1,091 proof campaign recorded below.

## Accepted checkpoint-bound column-family append candidate

- Parent: checkpoint-carried registry prerequisite `021bdd2`.
- Scope and contract: `Add_Column_Family` appends exactly one caller-configured, higher-ID family at an exact durable
  checkpoint with no later commit suffix. The caller supplies the complete per-family limits plus stable immutable
  manifest and HEAD transition identities. Duplicate ID/name, non-increasing ID, fresh-root state, suffix-bearing
  state, persisted family/history capacity, and invalid limits reject before publication. Rename, drop, reorder,
  prior-family mutation, automatic Flush, and a composable overload remain outside this unit.
- Allocation and formats: planning lazily allocates the authenticated checkpoint extents with one additional family,
  checked arithmetic, the prior run and identity totals, and the existing persisted database-wide ceilings. It copies
  every prior registry record, run descriptor, identity, replay boundary, and LSM limit exactly; the new family starts
  with zero runs. Allocation failure is typed `Capacity_Exceeded` and publishes no partial manifest or HEAD. No public
  constant, default, timeout, ID allocator, task count, or resource ceiling is introduced.
- Certainty and ownership: the private receipt owns the exact encoded successor manifest, expected provider
  generation/HEAD, attempted transition, family configuration, and engine incarnation. Immutable uncertainty permits
  only same-ID/same-byte continuation. HEAD uncertainty fences the writer and permits only complete cacheless
  reconciliation; an older observation remains unknown, the attempted manifest in a fully validated reachable chain
  confirms publication, and a conclusive excluding successor is stale-writer evidence. Confirmed publication followed
  by failed local replacement is `Local_Activation_Failed` and retains sufficient authority for exact resolution. No
  result authorizes mutation replay or a replacement identity.
- Acceptance evidence: the memory and files corpus covers duplicate rejection, persisted capacity, exact receipt
  authority, appended-family key/value enforcement, first-run Flush, cacheless reopen, fresh-root and unflushed-suffix
  rejection, exact allocation rollback, immutable and HEAD lost-response resolution, and local-activation recovery.
  The public Files showcase now creates one family, checkpoints it, appends a differently bounded family, commits and
  Flushes both, destroys all process-local state, and recovers both solely from object storage. The full deterministic
  suite, repository gate, GNATdoc generation, all maintained TLC models/witnesses/negative probes, 251/251 TLAPS
  obligations, and warning-strict GNATprove 1,091/1,091 checks (167 flow, 924 prover) are green; the post-run formal
  audit is clean.
- Findings cycle: the first pass fixed a P1 certainty downgrade that could classify an incomplete read after a
  confirmed HEAD as publication unknown, and separated unsupported call state from authenticated corruption. The
  acceptance review then fixed a P2 showcase gap by carrying the appended family through a two-family Flush and
  process-local-loss reopen, and corrected one timeout description and one formatting defect. Final API, ownership,
  concurrency, certainty, allocation, persisted-format, constants, recovery, tests, documentation, and
  unnecessary-surface re-review finds no actionable P0, P1, or P2 finding.

## Accepted checkpoint-carried registry append prerequisite

- Parent: limited end-to-end profile `d511de4`.
- Problem and scope: an append-only family successor encoded only as the base manifest would stop carrying the
  current checkpoint replay boundary. After compacted history is no longer available from sequence zero, cacheless
  recovery could not soundly activate that graph. This unit changes no bytes, visible DB API, default, capacity,
  allocation policy, task, retry, publication, or local-activation behavior.
- Compatibility decision: a decoded manifest-v3 checkpoint carrier may use either existing predecessor shape: the
  exact same registry for checkpoint/run evolution, or exactly one appended higher-ID family with every earlier
  family and database limit unchanged. Ordinary checkpoint and merge builders retain the strict same-registry
  predicate; only version-aware cacheless chain validation uses the carrier-aware union. Rename, drop, reorder, ID
  reuse, prior-record mutation, and limit changes remain rejected.
- Constants and ownership: no consequential value is added or changed. The new predicate composes the two already
  documented persisted transition authorities and allocates, retains, borrows, publishes, or schedules nothing.
- Verification: the maintained deterministic suite is green, including direct same-registry, one-family append, and
  prior-family-mutation predicate oracles plus local/client/files recovery and the limited public profile. The full
  TLA/TLAPS gate passes all maintained models, witnesses, and negative probes. Warning-strict GNATprove proves
  1,091/1,091 selected checks (167 flow, 924 prover), with zero warnings, unproved/justified checks, or `Assume`; the
  exact post-run formal-process audit is clean.
- Findings cycle: review checked predicate dispatch, merge-builder strictness, version selection, compatibility,
  constants, and claim scope. One P2 documentation gap failed to distinguish this format/recovery prerequisite from
  the still-missing public dynamic-family operation; the milestone and proof record now state that boundary. Final
  re-review finds no actionable P0, P1, or P2 finding.

## Accepted limited end-to-end public profile

- Parent: provider-centric Object Storage migration `a81fdea`.
- Scope and authority: freeze one deliberately narrow usable boundary before expanding the database. The profile has
  one fenced writer, two caller-declared fixed families with distinct persisted limits, synchronous Snapshot
  transactions, explicit singleton and atomic-group commits, point reads, ordered bounded scans, Delete, two explicit
  Flush calls, complete process-local state loss, and authoritative reopen. It selects no dynamic-family, automatic
  Flush/compaction, replica, TTL, codec, GC, retry, performance, or production policy.
- Ownership and durability: the maintained executable uses only public `Flyology.DB` and provider-neutral Files APIs.
  It requests power-loss-durable file publication, closes the first database value, constructs a fresh database
  value, and recovers solely from the same object-store prefix. The synchronous profile uses the same DB Flush
  operation and provider-owned Object Storage state machines as composable callers; no helper task, borrowed-body
  retention, mutation replay, or second certainty implementation is introduced.
- Constants and allocation: every database/family limit, identity, timeout, backend object ceiling, bucket, and
  prefix is fixture-owned and adjacent-documented. The two families deliberately have different key/value limits to
  witness persisted per-family authority. No value becomes a public default or inferred product ceiling; production
  allocation remains checked, lazy, and derived from authenticated persisted limits.
- Acceptance oracle: create two families; commit one singleton; atomically co-commit across both families; delete one
  key; Flush a complete checkpoint; commit and Flush a suffix; verify point and canonical scan results; close; reopen
  from a fresh database value; and verify exact surviving bytes, deletion, stable family lookup, and highest visible
  sequence. `tests/scripts/test.sh` invokes this executable, and the repository gate requires its sources and success
  sentinel.
- Verification: the formatted executable passes directly and within the complete deterministic suite; root build,
  repository checks, the 18-lane authenticated provider matrix, GNATdoc, maintained TLC/TLAPS campaign, and the
  warning-strict 1,090-check DB proof gate are green on the same source/dependency closure. The exact showcase is a
  power-loss-durable Files oracle; the authenticated matrix is corroborating evidence, not a claim that it ran this
  identical executable.
- Findings cycle: the first documentation pass overstated the authenticated provider matrix as the exact same
  database-level oracle. The claim now distinguishes the complete Files showcase from corroborating authenticated
  coverage and makes porting this public-only oracle the first expansion. A fidelity sweep found one P1: the first DB,
  family handles, storage binding, and provider handle remained alive after logical Close, weakening the claimed
  complete process-local-loss witness. Seed and recovery now run in separate owner scopes with independently opened
  Files handles and bindings; only the durable root path crosses the boundary. The post-gate sweep also found that a
  successful showcase left its executable as an untracked repository artifact; the profile now ignores its dedicated
  binary directory consistently with the maintained test executables. API, ownership, crash recovery, ordering,
  bounds, constants, packaging, documentation, test integration, and unnecessary-surface re-review finds no remaining
  actionable P0, P1, or P2 finding.

## Accepted provider-centric Object Storage migration

- Parent: pre-migration main `487747b31e3f`.
- Scope and provenance: migrate the DB consumer from the removed parallel `Scoped` child under `Client` to published
  provider-owned declarations at Object Storage source `3455cde3158fd589480281beac39bea51305bb5e`, selected by
  exact crate constraint `flyology_object_storage = "=0.1.0-dev"` from Flyology index
  `8e99188eb914e9d67243785f5427b494c041ac38`. The ignored clean build clone is the only path pin; the author checkout
  remains read-only. Indexed HTTP/QUIC resolve unpinned at 0.1.3-dev from
  `b5cd966decfc81132b46fdc97f9cbbfa5bcdf86c`.
- Architecture: scoped lifetime is an ownership discipline, not the provider. `Client.Objects` therefore colocates
  each synchronous overload, limited constructor, reusable operation-last procedure, operation type, and typed
  `Finish`. This keeps blocking and composable calls on one state machine and one certainty contract. DB introduces
  no alias, forwarding child, deprecated rename, wrapper, helper task, retry path, or second operation vocabulary.
- Contract preservation: conditional Put still moves one unique-buffer token and restores the exact token through
  typed `Finish`; any post-entry exception without definite non-admission remains outcome unknown and is reconciled
  read-only by generation-bound whole Get. Whole/range Get and Head retain their existing bounds, cancellation,
  absolute deadlines, request binding, and response-failure classification. No public DB constant, default,
  persisted format, allocation policy, or transaction behavior changes.
- Verification: the root build, maintained deterministic suite, 18-lane authenticated provider matrix, GNATdoc,
  repository gate, complete maintained TLC/TLAPS campaign, and warning-strict DB proof gate are green on the exact
  dependency closure. The DB proof reports 1,090/1,090 selected checks; the Object Storage handoff reports 936/936.
- Findings cycle: the first dependency run found one ignored nested test lock still selecting the earlier HTTP
  origin; refreshing that generated lock selected the published flattened origin without changing source or adding a
  pin. The API, ownership, certainty, constants, documentation, dependency-isolation, and unnecessary-surface sweep
  finds no remaining actionable P0, P1, or P2 finding.

## Accepted composable ListObjects v1 dependency qualification

- Parent: operational exact-three-run publication commit `0776d6a`.
- Scope and provenance: fast-forward only the ignored clean Object Storage build clone from
  `00959177c49f7e6e38f2ac19b8e958afba78c901` to exact authoritative local main
  `ea8c92c84fbd53b3c82e5004d7133c5b47633f3a`. The author checkout remains read-only coordination state, the root
  filesystem path pin is unchanged, indexed HTTP/QUIC remain unpinned at 0.1.3-dev, and no DB declaration, persisted
  format, allocation limit, task, retry, listing policy, or publication protocol changes.
- Surface and ownership: Object Storage adds caller-owned `List_Objects_Operation`, constructor and reusable
  operation-last `List_Objects`, terminal-only typed `Finish`, and a synchronous `List_V1_Page` result overload that
  waits on the same owner-stack state machine. The operation owns its prepared request and XML-limit-bounded response;
  signing borrows credentials only for the call and no helper task or borrowed request input survives initiation.
- Result boundary: complete strict pages preserve modeled listed/error results. Modeled request, authentication,
  authorization, missing-bucket, and backend-unavailable errors remain typed; malformed, unknown, inconsistent, or
  request-scope/payer-mismatched responses fail closed. Transport terminals retain result, phase, bounded detail, and
  request-admission certainty. This surface is read-only, performs no automatic retry, and treats pages as independent
  snapshots. Flyology.DB does not consume it in this dependency-only unit.
- Constants and compatibility: XML retention derives from `S3.XML.Default_Limits`; operation capacity derives from
  the established owner stack. Region, addressing, timeout, and cancellation defaults remain the existing Object
  Storage surface. Qualification introduces no DB public constant, default, persisted value, or resource ceiling.
- Verification and findings: `./tests/scripts/test.sh` rebuilds the dependency closure at exact `ea8c92c`, passes
  repository provenance, the local engine, authenticated client-backed create/commit/Flush/compaction/reopen,
  filesystem crash and cacheless recovery, all 32 comparative tests, and pinned TidesDB 4/4. `./scripts/prove.sh`
  proves 1,090/1,090 selected checks with its maintained success sentinel; exact pre/post host audits are clean.
  Upstream's reported 41/41 tests, 126 crash cases, provider matrix, GNATdoc, and 936/936 proof are corroborating
  evidence rather than substitutes for DB gates. API compatibility, ownership, response binding, read-only certainty,
  author-checkout isolation, constants, and unnecessary-surface review find no remaining P0, P1, P2, or P3 issue.

## Accepted operational exact-three-run publication candidate

- Parent: composable UploadPartCopy dependency qualification commit `097c21e`.
- Scope and authority: operationalize only the already-qualified exact-three algorithm through the private Flush
  publisher. The caller supplies three source run IDs plus output, manifest, and transition identities. Three remains
  qualification geometry; this unit adds no public API, automatic selection, trigger, fanout, level, retry, task,
  timeout, capacity, or persisted-format policy.
- Ownership and execution: the client-backed path uses the existing caller-owned completion set, one moved scratch
  token, typed Finish, and one absolute deadline. It authenticates all three selected source objects before building
  the effect-free successor, then publishes the exact output/manifest/HEAD chain. Memory and files use the same
  planner synchronously. The receipt retains only the exact three immutable IDs needed to reconstruct an uncertain
  attempt; it retains no caller handle, borrowed body, transport lease, or source/sink borrow.
- Certainty and recovery: pre-read and invalid-selection failures publish nothing. An uncertain output response is
  never retried under another identity; resolution rebuilds the exact selected triple and confirms the same bytes.
  Activation preserves a later database-log suffix independently of the checkpoint. After cacheless reopen, each
  sorted SST contributes only its highest-sequence entry per key to live state, so a retained middle tombstone masks
  every older version from the same merged object.
- Constants and allocation: every production allocation remains checked and derived lazily from authenticated SST
  extents plus persisted database/family limits. Test-only three-run counts, one-byte values, identity offsets, and
  manifest/L0 bounds are adjacent-documented witness geometry. No approved existing value is reopened and no public
  constant or default is introduced.
- Verification: `./tests/scripts/test.sh` passes repository provenance at Object Storage `00959177`, memory/files
  exact-three publication and cacheless recovery, authenticated client-owned selected reads and same-identity output
  reconciliation, filesystem crash recovery, all 32 comparative tests, and pinned TidesDB 4/4. The maintained TLA
  and SPARK gates remain green at 12,288 exact-three TLC states, seven TLAPS obligations, and 1,090/1,090 selected
  SPARK checks; exact pre/post formal-process audits are clean.
- Findings cycle: the first operational test exposed one P1 recovery error: a tombstone with no already-loaded value
  could be forgotten before an older put retained in the same merged SST was visited. Recovery now considers only
  the first, highest-sequence entry for each key in each structurally validated SST. The middle-tombstone/source-loss
  regression passes on memory and files, the full suite is green, and the repeated ownership, certainty, ordering,
  bounds, compatibility, public-surface, and unnecessary-allocation sweep finds no remaining P0, P1, P2, or P3.

## Accepted composable UploadPartCopy dependency qualification

- Parent: exact-three-run compaction kernel commit `fd1976c`.
- Scope and provenance: fast-forward only the ignored clean Object Storage build clone from
  `296b94f1ec7fd78c20838f2447d7dc4234e43c79` to exact authoritative local main
  `00959177c49f7e6e38f2ac19b8e958afba78c901`. The author checkout remains read-only coordination state, the root
  filesystem path pin is unchanged, indexed HTTP/QUIC remain unpinned at 0.1.3-dev, and no DB declaration, persisted
  format, allocation limit, task, retry, multipart policy, or publication protocol changes.
- Surface and ownership: Object Storage adds caller-owned `Upload_Part_Copy_Operation`, constructor and reusable
  operation-last `Upload_Part_Copy`, typed `Finish`, shared complete-response decoder, and a synchronous result
  overload that literally waits on the same owner-stack state machine. The request body is an owned known-empty
  one-shot source; no helper task, replay, or borrowed request retention is introduced.
- Certainty and reconciliation: exact validated CopyPartResult is `Published`, exact 412 is
  `Precondition_Failed`, and exact modeled non-mutating 400/401/403/404/501 rejection is definitely not published.
  Embedded HTTP-200 error, retryable/malformed/oversized response, or any failure after possible admission remains
  `Outcome_Unknown` and requires exact upload-ID/part-number ListParts reconciliation before retry or completion.
  Flyology.DB adds no multipart-copy call or retry policy in this dependency-only unit.
- Constants and compatibility: XML retention derives from `S3.XML.Default_Limits`; completion-set capacity derives
  from the maintained owner stack. Region, addressing, timeout, and cancellation defaults match the established
  synchronous surface. Qualification introduces no DB public constant, default, persisted value, or resource
  ceiling.
- Verification and findings: `./tests/scripts/test.sh` rebuilds the complete dependency closure at exact `00959177`,
  passes repository provenance, the local engine, authenticated client-backed create/commit/Flush/compaction/reopen,
  filesystem crash and cacheless recovery, all 32 comparative tests, and pinned TidesDB 4/4. `./scripts/prove.sh`
  proves 1,090/1,090 selected checks with its maintained success sentinel; exact pre/post host audits are clean.
  Upstream's reported 41/41 tests, 126 crash cases, full provider matrix, GNATdoc, and 936/936 proof are corroborating
  evidence rather than substitutes for the DB gates. API compatibility, owned-source lifetime, exact request/response
  binding, certainty mapping, reconciliation identity, author-checkout isolation, constants, and unnecessary-surface
  review find no remaining P0, P1, P2, or P3 issue.

## Accepted exact-three-run compaction kernel candidate

- Parent: composable GetObjectAttributes dependency qualification commit `7766301`.
- Scope and authority: add one private effect-free kernel for exactly three caller-selected consecutive SSTs and a
  successor builder for their three adjacent authenticated descriptors. Three is algorithm-qualification geometry,
  not a public or persisted trigger, fanout, level, capacity, scheduler, retry rule, or automatic selection policy.
- Algorithm and ownership: all three inputs must be structurally valid, share database/family authority, and carry
  strictly increasing disjoint sequence ranges. Checked entry, payload, and logical-byte sums authorize one exact
  output allocation; the merger never constructs pairwise temporary SSTs and publishes no partial candidate. Equal
  keys remain in descending sequence order, preserving every Put and Delete version. The successor replaces only the
  admitted three-descriptor slice and copies every retained family, run, replay boundary, identity, and persisted
  limit exactly.
- Formal boundary: exhaustive TLC checks 12,288 distinct states at depth 3 and rejects a probe that drops a middle
  tombstone when the last selected run has no mutation for that key. The concrete three-state witness validates the
  first-Put/middle-Delete/last-empty/suffix-Put path. TLAPS proves all seven arbitrary-key/value composition and
  retained-context obligations. This establishes read semantics, not operational publication or an Ada refinement
  theorem.
- Constants and allocation: the exact three-run count, one-key/two-value model, and five-descriptor retained-neighbor
  fixture are adjacent-documented qualification geometry. Production allocation extents derive only from validated
  SST discriminants with checked arithmetic and lazy exact allocation. No DB public constant, default, ceiling, or
  persisted format changes.
- Verification: the focused root/test builds and runtime corpus pass; `./tests/scripts/test.sh` passes repository
  provenance at Object Storage `296b94f1ec7fd78c20838f2447d7dc4234e43c79`, authenticated client and filesystem
  crash/recovery paths, all 32 comparative tests, and pinned TidesDB 4/4. Final maintained TLA and SPARK gate evidence
  is green: the complete `./scripts/check-tla.sh` campaign includes the 12,288-state/7-obligation three-run lane and
  all prior lanes, while `./scripts/prove.sh` proves 1,090/1,090 checks with its maintained success sentinel. Exact
  post-run host audits are clean.
- Findings cycle: architecture, ordering, checked arithmetic, allocation rollback, descriptor adjacency, retained
  slices, tombstone behavior, constants, public surface, and unnecessary-allocation review found one P2 coverage
  gap: the first test retained neighbors in the same family but did not verify a later family's derived flat-table
  offset. The added two-family fixture checks the exact shift by two and retained descriptor equality. Rebuild,
  deterministic rerun, and final re-review find no remaining P0, P1, P2, or P3 issue.

## Accepted composable GetObjectAttributes dependency qualification

- Parent: composable ListObjectVersions dependency qualification commit `5557db0`.
- Scope and provenance: fast-forward only the ignored clean Object Storage build clone from
  `ae567d0ab97bd0e970ca869c5190967da6a0f569` to exact authoritative local main
  `296b94f1ec7fd78c20838f2447d7dc4234e43c79`. The dirty author checkout remains read-only coordination state, the
  root filesystem path pin is unchanged, indexed HTTP/QUIC remain unpinned at 0.1.3-dev, and no DB declaration,
  persisted format, allocation limit, task, retry, metadata policy, or publication protocol changes.
- Surface and ownership: Object Storage adds caller-owned `Get_Object_Attributes_Operation`, constructor and
  same-client/same-token reusable operation-last `Get_Object_Attributes`, typed `Finish`, and a synchronous
  parameter-record overload that literally waits on the same operation. The parent owns the prepared request and
  XML-limit-bounded response through terminal drain, retains no caller request borrow, drives one HTTP child, and
  creates no helper task or replay path.
- Response binding and certainty: complete response decoding is shared by blocking and composable forms. A modeled
  success binds strict singleton metadata, exact requested opaque version echo, and Requester Pays admission to the
  prepared request. Read-only failures preserve HTTP terminal kind, causal phase, bounded detail, and admission
  diagnostics. Flyology.DB selects no attribute subset, pagination, polling, caching, retention, or retry policy in
  this unit.
- Constants and compatibility: the response extent derives from the maintained S3 XML decoder document limit and
  the synchronous completion-set capacity derives from the attributes-parent/HTTP/transport owner stack. Region,
  addressing, timeout, and cancellation defaults match the established synchronous API. Qualification introduces no
  DB public constant, default, persisted value, or resource ceiling.
- Verification: `./tests/scripts/test.sh` rebuilds the complete DB/Object Storage/XML/HTTP/QUIC closure at exact
  `296b94f`, passes repository provenance, local engine, authenticated client-backed
  create/commit/Flush/compaction/adjacent-merge/reopen, filesystem crash and cacheless recovery, all 32 comparative
  tests, and pinned TidesDB 4/4. `./scripts/prove.sh` exits zero and proves 1,090/1,090 selected DB checks with its
  maintained success sentinel; exact pre/post host audits are clean. Upstream's reported full tests and provider
  matrix, GNATdoc, and 936/936 proof are corroborating evidence, not substitutes for the DB campaign.
- Findings cycle: API compatibility, request-copy and response-buffer ownership, retained-owner restart rule,
  cancellation/finalization drain, shared complete-response decoder, exact version/payer binding, admission
  semantics, author-checkout isolation, constants, and unnecessary-surface review find no remaining P0, P1, P2, or
  P3 issue.

## Accepted composable ListObjectVersions dependency qualification

- Parent: owner-driven selected-run reader commit `b19e001`.
- Scope and provenance: fast-forward only the ignored clean Object Storage build clone from
  `a632cc4b0bd4687e02b09cff7923ab4f9fccbfcf` to exact authoritative local main
  `ae567d0ab97bd0e970ca869c5190967da6a0f569`. The dirty author checkout remains read-only coordination state, the
  root filesystem path pin is unchanged, indexed HTTP/QUIC remain unpinned at 0.1.3-dev, and no DB declaration,
  persisted format, allocation limit, task, retry, listing policy, or publication protocol changes.
- Surface and ownership: Object Storage adds caller-owned `List_Object_Versions_Operation`, constructor and reusable
  operation-last `List_Object_Versions`, typed `Finish`, and a synchronous parameter-record overload that literally
  waits on the same operation. The parent owns the prepared request and XML-limit-bounded response bytes through
  terminal drain, retains no caller request borrow, drives one HTTP child, and creates no helper task or replay path.
- Binding and pagination: a successful page binds bucket, prefix, delimiter, maximum, encoding, Requester Pays
  admission, and the paired key/version cursor to the exact prepared request. URL-encoded key markers are decoded
  before an explicit later Start while version IDs remain opaque. Each page is an independent service snapshot;
  Flyology.DB selects no listing, restart, polling, snapshot, retention, or garbage-collection policy in this unit.
  Read-only failures retain typed HTTP terminal kind, phase, bounded detail, and admission diagnostics.
- Constants and compatibility: the response extent derives from the maintained S3 XML decoder document limit and
  the synchronous completion-set capacity derives from the listing-parent/HTTP/transport owner stack. Region,
  addressing, timeout, and cancellation defaults match the established synchronous API. Qualification introduces no
  DB public constant, default, persisted value, or resource ceiling.
- Verification: `./tests/scripts/test.sh` rebuilds the complete DB/Object Storage/XML/HTTP/QUIC closure at exact
  `ae567d0`, passes repository provenance, local engine, authenticated client-backed
  create/commit/Flush/compaction/adjacent-merge/reopen, filesystem crash and cacheless recovery, all 32 comparative
  tests, and pinned TidesDB 4/4. `./scripts/prove.sh` exits zero and proves 1,090/1,090 selected DB checks with its
  maintained success sentinel; exact pre/post host audits are clean. Upstream's reported full deterministic matrix,
  GNATdoc, and 936/936 proof are corroborating dependency evidence, not substitutes for the DB campaign.
- Findings cycle: API compatibility, request-copy and response-buffer ownership, restart identity, cancellation and
  finalization drain, complete-response decoding, exact cursor/request binding, admission semantics, author-checkout
  isolation, constants, and unnecessary-surface review find no remaining P0, P1, P2, or P3 issue.

## Accepted owner-driven adjacent-merge selected-run reader

- Parent: selected-run planning seam commit `12fbcb0`.
- Scope and authority: connect only the private caller-selected adjacent two-run merge to the established
  composable Object Storage reads. The caller still supplies the older, newer, output, manifest, and transition
  identities. This unit adds no public compaction operation, trigger, level, fanout, schedule, retry, timeout,
  garbage-collection rule, helper task, or allocation ceiling.
- Owner-stack read path: after the effect-free authority snapshot, one DB parent serially drives bodyless HEAD,
  exact-generation frozen-header range, and same-generation bounded whole Get operations for every manifest-named
  SST. One caller-selected buffer token moves into the parent and is reused across all reads and immutable
  publication; typed `Finish` restores that exact token into any vacant same-pool handle. One absolute monotonic
  deadline and cancellation source cover the entire operation. The private synchronous client form literally waits
  on this state machine. Backend-neutral memory/files selected reads remain blocking without helper tasks.
- Validation and certainty: every complete read must retain the HEAD generation, exact object length, frozen header
  admission, manifest database/family/run descriptor, and complete SST decode before successor construction.
  Missing or generation-mismatched manifest authority fails closed. Selected-read failures publish nothing. Once
  immutable publication starts, the established receipt phases continue to distinguish definite failure from
  `Outcome_Unknown`; the operation never retries under a new identity.
- Dynamic allocation and constants: selected SST arrays use the exact authenticated manifest run extent, decoded
  keys/values use persisted database and per-family limits, and the synchronous buffer bound is derived by the
  maintained checked-arithmetic helper. The header range derives from frozen SST-v1 framing. Completion-set capacity
  four and buffer-pool capacity one document the exact serial owner stack and single moved-token geometry; neither
  is a public or persisted policy ceiling.
- Verification: `./tests/scripts/test.sh` passes repository provenance at exact Object Storage
  `a632cc4b0bd4687e02b09cff7923ab4f9fccbfcf`, the local engine, authenticated client-backed
  create/commit/Flush/compaction/adjacent-merge/reopen path, filesystem crash and cacheless recovery, all 32
  comparative tests, and pinned TidesDB 4/4. The focused client witness injects a definite failure before the first
  selected read, observes no publication, explicitly retries the same identities, validates the merged receipt, and
  reopens without local cache to recover the later value. `./scripts/prove.sh` exits zero and proves 1,090/1,090
  selected checks; its maintained success sentinel is present and the exact pre/post host process audits are clean.
  The abstract adjacent-merge algorithm is unchanged, so the previously accepted exhaustive TLC/TLAPS gate remains
  the formal algorithm boundary and is not represented as a fresh run for this execution-path unit.
- Findings cycle: architecture and implementation review covers generation capture, response completion, buffer and
  child-operation lifetime, cancellation races, deadline propagation, allocation rollback, publication certainty,
  public surface, constants, and synchronous/composable equivalence. The sweep identified and fixed one P1: an
  unexpected typed-child `Finish` exception could leave a consumed child operation's completion-set slot reserved;
  all three selected-read children now release that slot before terminal parent failure. It also fixed one P2 by
  documenting the selected-run zero cursor beside its declaration. Rebuild, full deterministic rerun, warning-strict
  proof, and final re-review find no remaining P0, P1, P2, or P3 issue.

## Accepted adjacent-merge selected-run planning seam

- Parent: complete PutObject and ListObjectsV2 dependency qualification commit `370a243`.
- Scope and authority: split the private adjacent-merge planner around its selected-run I/O without changing the
  synchronous execution path. The caller still supplies every older, newer, output, manifest, and transition
  identity; this unit adds no public API, trigger, level, fanout, schedule, retry, timeout, task, allocation ceiling,
  or garbage-collection policy.
- Ownership and validation: the first effect-free phase freezes the exact current HEAD generation, checkpoint
  manifest, and persisted family/run/identity extents. The loader-owned checkpoint plan is then consumed by one
  effect-free completion phase, which revalidates every populated SST against its authenticated database, family,
  and run descriptor before invoking the established adjacent-merge successor kernel. Every failure releases the
  complete source and candidate plans and publishes no object. The existing blocking wrapper remains the sole caller
  in this unit; the seam permits a later owner-driven Object Storage reader to populate the same exact plan without
  duplicating merge, suffix-history, or activation logic.
- Verification: `alr -n build` succeeds. `./tests/scripts/test.sh` passes repository provenance at exact Object
  Storage `a632cc4b0bd4687e02b09cff7923ab4f9fccbfcf`, local engine, authenticated client-backed
  create/commit/Flush/compaction/reopen, filesystem crash/cacheless recovery, all 32 comparative tests, and pinned
  TidesDB 4/4. `./scripts/prove.sh` proves 1,090/1,090 selected checks with its maintained warning-strict gate; the
  exact pre/post host process audits are clean.
- Findings cycle: architecture and implementation review covers snapshot coupling, exact descriptor binding,
  ownership consumption on every return and exception, suffix-history transfer, allocation classification,
  publication ordering, constants, public surface, and unnecessary duplication. The first compile found and fixed
  one mechanical phase-local generation reference. The explicit findings sweep then identified and fixed one P2:
  completion originally validated only the two selected SSTs indirectly through the merge kernel, which would let a
  future injected loader supply an invalid retained SST. Rebuild, deterministic rerun, proof, and final re-review
  find no remaining P0, P1, P2, or P3 issue.

## Accepted complete PutObject and ListObjectsV2 dependency qualification

- Parent: suffix-preserving adjacent-merge activation commit `71c0000`.
- Scope and provenance: fast-forward only the ignored clean Object Storage build clone from
  `4d6925e2138f18fca2d24d0f63ed0f0319bdbad9` to exact authoritative local main
  `a632cc4b0bd4687e02b09cff7923ab4f9fccbfcf`. The author checkout remains read-only coordination state, the root
  filesystem path pin is unchanged, indexed HTTP/QUIC remain unpinned at 0.1.3-dev, and no DB declaration, format,
  allocation limit, task, retry, compaction policy, or publication protocol changes.
- Complete PutObject ownership and certainty: the dependency adds `Client.Objects.Put_Object`, its reusable
  operation-last overload, typed `Finish`, and a buffer-owned synchronous overload that literally waits on that
  operation.
  Validation and signing complete before the acquired payload token moves; any vacant same-pool handle can receive
  the exact moved token at `Finish`, and no original caller-handle pointer is retained. The prepared request binds
  requested checksum and RequestCharged response fields. No path retries, creates a helper task, or retains borrowed
  input; every possibly admitted exchange failure retains conservative publication certainty for caller-driven
  generation-bound reconciliation.
- ListObjectsV2 ownership and result: `Client.Objects.List_Objects_V2`, its reusable operation-last overload, typed
  `Finish`, and the synchronous typed `Objects.List_Page` overload share one owner-driven state machine. It owns
  prepared request facts and XML-limit-bounded response bytes, retains no request borrow, and preserves either a
  complete modeled page
  or typed HTTP terminal/admission diagnostics. Successful pages bind bucket, prefix, delimiter, maximum,
  continuation/start cursor, encoding, Requester Pays admission, and singleton response headers to the exact request.
  Separate pages remain independent snapshots; DB selects no listing, pagination, discovery, or retry policy here.
- Constants and compatibility: all public region, addressing, cancellation, and timeout defaults are the established
  synchronous values. Response capacity derives from the existing S3 XML parser limit and the synchronous
  completion-set extent derives from the operation/HTTP/transport topology. This qualification adds no DB constant,
  public default, persisted value, or resource ceiling.
- Verification: `./tests/scripts/test.sh` rebuilds the complete DB/Object Storage/XML/HTTP/QUIC closure at exact
  `a632cc4`, passes repository provenance, local engine, authenticated client, memory/files crash and cacheless
  recovery, all 32 comparative tests, and pinned TidesDB 4/4. `./scripts/prove.sh` proves 1,090/1,090 selected DB
  checks (166 flow, 924 prover), with zero selected-unit warnings, unproved/justified checks, or `pragma Assume`; exact
  pre/post host audits are clean. Upstream's reported 41/41 plus 126 crash cases, 18/18 repeated provider lanes,
  GNATdoc, and 936/936 proof are corroborating dependency evidence, not substitutes for the DB campaign.
- Findings cycle: API, limited ownership, validation/move/rollback ordering, terminal drain/finalization, request and
  response binding, publication certainty, listing scope, dependency provenance, constants, and unnecessary-surface
  review found one P2 documentation ambiguity: inherited `Finish` prose could imply that the original caller handle
  was retained. Object Storage corrected both PutObject and UploadPart to state that any vacant same-pool handle
  receives the exact moved token. Rebuild, deterministic rerun, warning-strict proof rerun, and final re-review find
  no remaining P0, P1, P2, or P3 issue.

## Accepted suffix-preserving adjacent-merge activation

- Parent: composable DeleteObjects dependency qualification commit `917bcc1`.
- Scope and authority: extend only the private caller-selected adjacent two-run merge so an exact post-checkpoint log
  suffix can survive successor publication and local coordinator replacement. The caller still supplies every run,
  manifest, and transition identity. This unit adds no public API, trigger, level, fanout, schedule, retry, timeout,
  task, garbage-collection rule, or allocation ceiling.
- Prepublication ownership: under the existing quiescent checkpoint lifecycle, the planner allocates transaction and
  mutation descriptor arrays from each retained runtime batch's exact decoded extents, copies its complete scalar and
  descriptor authority, and retains shared ownership of the immutable batch image. It validates the newest batch
  against current HEAD, the oldest batch against the retained checkpoint transition, and every intervening batch
  predecessor. Allocation, shape, or authority failure releases the candidate and publishes no object.
- Activation and recovery: the activation base is derived strictly from the successor manifest's authenticated SSTs;
  retained SST ownership moves from the current plan and the new merged SST is cloned at its exact derived extent.
  The replacement coordinator recovers that base and then replays the plan-owned suffix oldest-to-newest, preserving
  values, snapshot write-conflict evidence, transaction IDs, batch IDs, and checkpoint identity authority. Cacheless
  recovery accepts a manifest-only HEAD descendant only when its already-validated predecessor chain contains the
  exact database, writer epoch, transition, and replay-boundary checkpoint anchors for the retained suffix.
- Deterministic and formal evidence: `./tests/scripts/test.sh` passes repository integrity, local engine, authenticated
  client, memory/files crash and cacheless recovery, all 32 comparative tests, and pinned TidesDB 4/4 against Object
  Storage `4d6925e2138f18fca2d24d0f63ed0f0319bdbad9`. The focused witness rejects injected history allocation without
  publication, publishes the second adjacent merge with a live suffix, retains duplicate-ID and write/write-conflict
  authority, removes all four retired inputs, and reopens from only the final merged output plus suffix. The complete
  TLA gate exhausts 3,145,728 partial-merge states at depth 3, proves 5/5 arbitrary-key/value TLAPS obligations,
  validates exact suffix/identity transfer, and detects the tombstone-dropping negative probe. `./scripts/prove.sh`
  proves 1,090/1,090 selected checks (166 flow, 924 prover), with zero selected-unit warnings, unproved/justified
  checks, or `pragma Assume`; exact pre/post formal-process audits are clean.
- Findings cycle: architecture review fixed three P1 risks before acceptance: rebuilding activation from the live view
  would conflate suffix and checkpoint authority; allocating suffix ownership after HEAD publication could leave no
  exact rollback path; and recovery authenticated the latest batch only against immediate HEAD rather than a valid
  manifest-only descendant. Executable recovery then exposed and fixed a second P1: the oldest suffix batch must bind
  to its exact predecessor checkpoint in the validated chain, not necessarily the current checkpoint. Implementation
  review fixed P2 ownership/type hardening for pre-owned copy targets, exact database/epoch anchors, and overlapping
  writable actuals; the full TLA run fixed a stale P2 concrete-witness expectation. Rebuild, deterministic rerun,
  formal rerun, constants/public-contract/ownership/certainty review, and final re-review find no remaining P0, P1,
  P2, or P3 issue.

## Accepted composable DeleteObjects dependency qualification

- Parent: private adjacent-merge publication commit `8bf41b0`.
- Scope and provenance: fast-forward only the ignored clean Object Storage clone from
  `c94239db8b588f003d637d787515e3c90c233ca0` to exact committed local main
  `4d6925e2138f18fca2d24d0f63ed0f0319bdbad9`. The dirty author checkout remains read-only coordination state, the
  root filesystem path pin remains unchanged, indexed HTTP/QUIC remain unpinned at 0.1.3-dev, and no DB declaration,
  persisted format, allocation limit, task, retry, compaction policy, or publication protocol changes.
- Surface and ownership: Object Storage adds caller-owned `Delete_Objects_Operation`, constructor and reusable
  reusable operation-last `Delete_Objects`, typed `Finish`, and a synchronous result overload implemented as a wait
  on that same provider-owned state machine. It copies and serializes the bounded request before admission, owns the
  exact XML as a one-shot non-replayable body, retains no borrowed request input, drives one HTTP child, and creates
  no helper task.
- Result and certainty boundary: only a validated HTTP 200 yields `Batch_Processed`, retaining the complete ordered
  per-entry Deleted/Error response. Definite rejection/non-admission and pre-admission cancellation are distinct;
  possible admission, transport loss, invalid/oversized response, or decoding failure remains
  `Batch_Outcome_Unknown`. A caller must reconcile every requested exact generation read-only before retry. DB does
  not expose batch deletion in this unit, so the qualification selects no DB deletion or reconciliation policy.
- Verification: `./tests/scripts/test.sh` rebuilds the complete DB/Object Storage/XML/HTTP/QUIC closure and passes the
  local engine, authenticated client, filesystem crash/recovery, all 32 comparative cases, pinned TidesDB 4/4, and
  repository provenance at exact `4d6925e`. `./scripts/prove.sh` proves 1,090/1,090 DB checks (166 flow, 924 prover),
  with zero warnings, unproved/justified checks, or `pragma Assume` and clean pre/post host audits. Upstream's reported
  936/936 proof is corroborating dependency evidence, not a substitute for the DB campaign.
- Findings cycle: dependency/API, limited ownership, request-copy and body lifetime, cancellation/finalization drain,
  per-entry response retention, publication/admission certainty, author-checkout isolation, constants,
  documentation, and unnecessary-surface review finds no remaining P0, P1, P2, or P3 issue.

## Accepted private adjacent-merge publication candidate

- Parent: composable CopyObject dependency qualification commit `ac97706`.
- Scope and authority: add one private synchronous execution path for a caller-selected adjacent two-run merge. The
  caller supplies the older, newer, output, manifest, and HEAD-transition identities; the unit adds no public API,
  trigger, schedule, fanout, level, retry, timeout default, helper task, or garbage-collection authority.
- Read and allocation boundary: under the exclusive checkpoint lifecycle, the planner binds the retained checkpoint
  manifest to the exact current HEAD/generation and copies its exact persisted family/run/identity extents. Every
  current SST is authenticated through the maintained frozen-header range read and same-generation bounded whole
  read before the manifest-aware kernel admits the selected pair. Allocation derives lazily from authenticated
  persisted extents and current database/per-family limits; every prepublication failure releases owned candidates
  and publishes nothing.
- Publication and certainty: the existing publisher confirms the merged SST and exact successor manifest before the
  conditional HEAD transition, then activates the prepared live image. A private receipt mode retains the exact
  selected identities only for `Objects_Unknown` reconstruction; resolution rebuilds those same bytes and cannot
  reinterpret the attempt as additive Flush or complete replacement. Accepted/lost immutable responses remain
  `Outcome_Unknown` until exact same-identity read-only reconciliation succeeds. No automatic retry occurs.
- Suffix safety: the successor intentionally preserves the current manifest replay/identity authority. The planner
  therefore requires that replay boundary to equal current HEAD's highest sequence and rejects a later log suffix
  before reads, allocation, or publication. This prevents local activation from retaining only live bytes while
  silently dropping suffix conflict-history and transaction-identity authority.
- Deterministic evidence: `./tests/scripts/test.sh` passes the root/tests/server build, local engine, authenticated
  client, memory/files crash/recovery, all 32 comparative cases, pinned TidesDB 4/4, and repository provenance at
  Object Storage `c94239db8b588f003d637d787515e3c90c233ca0`. The new memory/files witness creates three chronological
  L0 runs, rejects nonadjacent and aliased identities without publication, forces an accepted/lost merged-run
  response, resolves with the exact retained plan, removes both retired source objects, and reopens with the merged
  value plus the retained later run. A post-merge suffix is rejected without objects and remains visible after
  cacheless reopen.
- Proof evidence: `./scripts/prove.sh` passes 1,090/1,090 selected checks (166 flow, 924 prover), with zero warnings,
  unproved/justified checks, or `pragma Assume`; exact pre/post host-process audits are clean. The dynamic planner,
  Object Storage calls, lifecycle, and activation remain executable boundaries rather than inferred SPARK proof.
  The unchanged full `./scripts/check-tla.sh` regression gate is green; the partial-LSM lane exhausts 196,608 states,
  proves 5/5 TLAPS obligations, validates the retained older/selected/newer witness, and detects the dropped-tombstone
  negative probe. No Ada refinement theorem is claimed.
- Findings cycle: architecture review fixed a P1 suffix-activation authority loss by adding the exact-boundary
  precondition and witness. Implementation review fixed a P2 absent-checkpoint classification, a P2 output identity
  alias, a P2 impossible mixed receipt mode, and a test fault that initially targeted prerequisite reads rather than
  post-PUT reconciliation. Rebuild, full deterministic rerun, warning-strict proof, constants/ownership/certainty
  review, and final re-review find no remaining P0, P1, P2, or P3 issue.

## Accepted composable CopyObject dependency qualification

- Parent: effect-free partial-merge successor commit `f5574b7`.
- Scope and provenance: fast-forward only the ignored clean Object Storage clone from
  `82780e41632703df5efaa73356d3b2b53a598702` to the explicitly qualified local-only boundary
  `c94239db8b588f003d637d787515e3c90c233ca0`. The clean author checkout remains read-only coordination state, the
  root filesystem path pin remains unchanged, and no DB declaration, format, allocation limit, task, retry,
  compaction policy, or publication protocol changes in this unit.
- Surface and ownership: the dependency adds caller-owned `Copy_Operation`, constructor and reusable `Start` forms,
  typed `Finish`, and a synchronous result overload that literally waits on the same owner-driven state machine. It
  owns the prepared request, uses a one-shot empty source and XML-limit-bounded sink, retains no caller borrow after
  request preparation, has one HTTP child, and performs no replay or helper-task scheduling.
- Certainty boundary: exact validated completion is `Published`, and exact HTTP 412 is `Precondition_Failed`.
  Possibly admitted transport loss, invalid or oversized response, malformed embedded HTTP-200 error, and other
  post-admission failures remain `Outcome_Unknown`; a caller must reconcile with a generation-bound whole destination
  Get before retry. Flyology.DB does not expose CopyObject, so qualification adds no DB copy or reconciliation policy.
- Verification: the maintained deterministic suite rebuilds the complete DB/Object Storage/XML/HTTP/QUIC closure and
  exercises local engine, authenticated client, filesystem crash/recovery, comparative adapters, and repository
  provenance against the exact clean clone above. The warning-strict DB proof gate recompiles the dependency closure;
  it proves 1,090/1,090 DB checks (166 flow, 924 prover), with zero warnings, unproved/justified checks, or
  `pragma Assume` and clean pre/post process audits. It does not substitute upstream's reported 936/936 proof for DB
  evidence.
- Findings cycle: API compatibility, limited-operation ownership, empty-source and sink lifetime, cancellation and
  finalization drain, response bounds, embedded-success error handling, publication/admission certainty,
  author-checkout isolation, constants, documentation, and unnecessary-surface review finds no remaining P0, P1,
  P2, or P3 issue. Historical review entries retain the exact dependency used by their campaigns.

## Accepted effect-free partial-merge successor candidate

- Parent: bounded composable ListMultipartUploads dependency qualification commit `257a530`.
- Scope and semantics: add one private effect-free builder that combines the already admitted adjacent SST pair and
  an exact caller-prepared checkpoint successor base. It returns the merged immutable SST candidate and a complete
  successor manifest candidate, replacing only those two descriptors. It performs no object write, HEAD read,
  conditional publication, task creation, retry, trigger selection, or public API change.
- Persisted authority: the checkpoint predecessor rule moves unchanged from the operational recovery body into the
  selected `Manifest_Formats` package. Recovery and construction now require the same database, limits, exact family
  registry, predecessor identity, next revision, and reachable transition ordinal/epoch geometry. The builder copies
  every replay boundary, runtime limit, identity-ledger item, family rule, and retained run, and shifts later flat
  family slices by exactly one.
- Bounds and ownership: the existing manifest-aware merger rejects all input, adjacency, and output-identity errors
  before allocation. The successor allocation derives lazily from the current persisted family, run, and identity
  totals. Typed allocation failure releases the merged candidate and returns both outputs vacant; unexpected failure
  releases every candidate before propagation. Inputs remain borrowed only for the call.
- Constants and policy: no compaction trigger, fanout, level, capacity, timeout, retry, output identity generator,
  publication rule, or visible declaration is selected. Consequential test identities, extents, and two-family slice
  geometry are classified beside the fixture; production allocation continues to derive from persisted database and
  per-family limits.
- Verification: `./tests/scripts/test.sh` passes the warning-strict root/tests/server build, local model and engine,
  authenticated client, filesystem crash/recovery, all 32 comparative cases, pinned TidesDB 4/4, and repository
  provenance against Object Storage `82780e41632703df5efaa73356d3b2b53a598702`. The focused corpus verifies exact
  successor fields, invalid predecessor rejection before publication, merged-SST and successor-manifest round trips,
  and a retained second-family descriptor whose flat slice shifts from three to two. `./scripts/prove.sh` proves
  1,090/1,090 checks (166 flow, 924 prover), with zero warnings, unproved/justified checks, or `pragma Assume`; clean
  executable-name audits bracket the campaign.
- Findings cycle: architecture review identified a P2 coverage gap in a one-family-only corpus, so the accepted test
  includes a retained second family. Implementation review found a P2 one-past cursor update after consuming a final
  source entry or pair; cursor advancement now occurs only when entries remain. Rebuild, full deterministic rerun,
  proof, constants/ownership/compatibility review, and final re-review find no remaining P0, P1, P2, or P3 issue.

## Accepted bounded composable ListMultipartUploads dependency qualification

- Parent: manifest-admitted partial SST merge commit `b912f3d`.
- Scope and provenance: fast-forward only the ignored clean Object Storage clone from
  `fa418173c048ed9e59e67ac36afbd4973a37adac` to the explicitly qualified local-only boundary
  `82780e41632703df5efaa73356d3b2b53a598702`. The dirty author checkout remains read-only coordination state, the
  root filesystem path pin remains unchanged, and no DB declaration, format, allocation limit, task, retry,
  compaction policy, or publication protocol changes in this unit.
- Surface and ownership: the dependency adds caller-owned `List_Multipart_Uploads_Operation`, constructor and reusable
  `Start` forms, typed `Finish`, and a synchronous result overload that literally waits on the same owner-driven state
  machine. It owns the prepared request, retains no credential borrow after signing, has one HTTP child and no helper
  task or replay, bounds retained response bytes by the existing S3 XML decoder limit, and drains the child before
  releasing request/response storage during terminal consumption or finalization.
- Result boundary: the read-only result preserves complete modeled response or typed HTTP terminal failure plus
  admission certainty. Successful decoding binds bucket, paired key/upload markers, prefix, delimiter, maximum,
  encoding, and Requester Pays admission to the exact prepared request. The same response-binding correction applies
  to ListParts. Separate pages have no shared service snapshot. Flyology.DB still has no multipart operation, so this
  qualification deliberately introduces no DB discovery/reconciliation API or pagination policy.
- Verification: the maintained deterministic suite rebuilds the complete DB/Object Storage/XML/HTTP/QUIC closure and
  exercises local engine, authenticated client, filesystem crash/recovery, comparative adapters, and repository
  provenance against the exact clean clone above. The warning-strict DB proof gate recompiles the dependency closure
  and proves all 1,088 selected DB checks; this unit does not substitute or claim upstream proof as DB evidence.
- Findings cycle: API modes/default compatibility, limited-operation ownership, request/credential lifetimes,
  cancellation/finalization drain, response bounds, paired-cursor and Requester Pays binding, read-only certainty,
  author-checkout isolation, constants, documentation, and unnecessary-surface review finds no remaining P0, P1,
  P2, or P3 issue. Historical review entries retain the exact dependency used by their campaigns.

## Accepted manifest authority for partial SST merge

- Parent: bounded composable ListParts dependency qualification commit `17e80c8`.
- Scope and semantics: add one private runtime entry point that accepts the existing version-preserving merge only
  when both structurally valid SSTs exactly match two adjacent descriptors in one structurally valid authenticated
  manifest family. The output identity must be absent from every current descriptor. No run is selected
  automatically, and the lower merge still retains every version and tombstone.
- Authority boundary: adjacency and current run identities derive only from persisted manifest order. The caller still
  must bind that captured manifest to current HEAD generation before any immutable publication or metadata effect.
  This unit adds no trigger, threshold, fanout, level, retry, task, timeout, capacity, persisted byte, or public API.
- Bounds and ownership: all rejection occurs before output allocation. A successful operation uses the merger's exact
  checked entry/payload/logical-byte sums, borrows both inputs and manifest only for the call, and returns one privately
  owned SST candidate or a vacant output.
- Verification: the maintained deterministic suite rebuilds root/tests/server, passes local/client/files crash and
  reopen paths, all 32 comparative cases, pinned TidesDB 4/4, and repository provenance against Object Storage
  `fa418173c048ed9e59e67ac36afbd4973a37adac`. The focused corpus covers exact adjacency, reversed authority,
  nonadjacent descriptors, selected-input identity reuse, retained-run identity collision, and exact output round trip.
- Findings cycle: the first sweep found one P2: the lower kernel rejected input-ID reuse but the manifest-aware entry
  could accept an output ID belonging to a different retained run. The entry now rejects collision with every current
  descriptor and the corpus includes the retained-run witness. Rebuild, deterministic rerun, constants audit, and
  re-review find no remaining P0, P1, P2, or P3 issue. The project-independent formatter changed unrelated existing
  layout; that churn was removed and the changed-source 110-column audit is clean.

## Accepted bounded composable ListParts dependency qualification

- Parent: private version-preserving SST merge kernel commit `55b2dfd`.
- Scope and provenance: fast-forward only the ignored clean Object Storage clone from
  `425acbaa41833ed0613e277f50f68576b54f81f3` to the explicitly qualified local-only boundary
  `fa418173c048ed9e59e67ac36afbd4973a37adac`. The dirty author checkout remains read-only coordination state, the
  root filesystem path pin remains unchanged, and no DB declaration, format, allocation limit, task, retry,
  compaction policy, or publication protocol changes in this unit.
- Surface and ownership: the dependency adds caller-owned `List_Parts_Operation`, constructor and reusable `Start`
  forms, typed `Finish`, and a synchronous result overload that literally waits on the same owner-driven state
  machine. It owns the prepared request, retains no credential borrow after signing, has one HTTP child and no helper
  task or replay, bounds retained response bytes by the existing S3 XML decoder limit, and drains the child before
  releasing request/response storage during terminal consumption or finalization.
- Result boundary: the read-only result preserves complete modeled response or typed HTTP terminal failure plus
  admission certainty. Successful decoding validates bucket, key, exact upload ID, part marker, and requested page
  maximum echoes. Separate pages have no shared service snapshot. Flyology.DB has no multipart operation yet, so this
  qualification deliberately introduces no DB reconciliation API or pagination policy.
- Verification: the maintained deterministic suite rebuilds the complete DB/Object Storage/XML/HTTP/QUIC closure and
  exercises local engine, authenticated client, filesystem crash/recovery, comparative adapters, and repository
  provenance against the exact clean clone above. The warning-strict DB proof gate recompiles the dependency closure
  and proves all 1,088 selected DB checks; this unit does not substitute or claim upstream proof as DB evidence.
- Findings cycle: API modes/default compatibility, limited-operation ownership, request/credential lifetimes,
  cancellation/finalization drain, response bounds, echo validation, read-only certainty, author-checkout isolation,
  constants, documentation, and unnecessary-surface review finds no remaining P0, P1, P2, or P3 issue. Historical
  review entries retain the exact dependency used by their campaigns.

## Accepted private version-preserving SST merge kernel

- Parent: policy-neutral partial-LSM formal boundary commit `1eca15b`.
- Scope and semantics: add one private runtime operation that coalesces two structurally valid SSTs from the same
  database/family when the older sequence range ends strictly before the newer begins. The caller supplies a fresh
  output identity. The merge retains every version and tombstone in canonical key/descending-sequence order, so it
  reduces a future descriptor count without selecting a snapshot-retention horizon or pruning policy.
- Bounds and ownership: entry, payload, and logical-byte extents are exact checked sums of the authenticated inputs;
  there is no key/value, output, run, or memory default. Allocation is lazy, typed failure leaves the output vacant,
  and an unexpected exception releases the candidate before propagation. Inputs are borrowed only for the call.
- Compatibility boundary: no public declaration, persisted byte, descriptor layout, dependency, trigger, fanout,
  level, schedule, publication protocol, manifest selector, or garbage-collection policy changes. A later publisher
  must establish that the two descriptors are adjacent in current manifest authority before using this kernel.
- Verification: the maintained deterministic suite rebuilds root/tests/server, passes local/client/files crash and
  reopen paths, 32 comparative cases, and pinned TidesDB 4/4. The focused SST test merges same-key histories plus
  side-specific keys, verifies every Put/Delete version and tombstone, round-trips the exact output, and rejects
  reversed ranges and input-identity reuse. The warning-strict SPARK gate remains 1,088/1,088 (165 flow, 923 prover,
  maximum 6,890), with zero warnings/unproved/justified/Assume; the runtime merger itself is an executable boundary.
- Findings cycle: the first sweep found two P2 issues: cursor progression used one-past indices, and unexpected
  post-allocation exceptions lacked a cleanup boundary. Explicit remaining counts now avoid one-past arithmetic and
  the exception path releases the candidate. Re-review found a third P2: the cross-SST comparator duplicated the
  existing single-array lexicographic loop while its focused fixture used equal-length keys. The established
  comparator is now a wrapper over the cross-array implementation, so the existing ordering/corruption corpus
  exercises the merger's exact comparison logic. Rebuild, full deterministic rerun, proof, and re-review find no
  remaining P0, P1, P2, or P3 finding. The project-mode formatter remained blocked by the repository's global
  preprocessor symbols; the three changed files were formatted in no-project mode, unrelated formatter churn was
  removed, and the 110-column audit is clean.

## Accepted policy-neutral partial-LSM merge boundary

- Parent: multipart-abort dependency qualification commit `478cca7`.
- Scope and authority: add only a formal read-equivalence lane for replacing two selected consecutive runs while
  retaining one older and one newer run in order. The merger preserves the newest selected mutation per key,
  including tombstones. This is an algorithmic consequence of oldest-to-newest run recovery, not a selected trigger,
  fanout, level size, schedule, resource capacity, publication protocol, public declaration, or operational Ada
  partial merger.
- Bounded evidence: TLC exhausts all 196,608 states at depth 3 over four two-key/two-value mutation maps and exercises
  both semantic actions. The negative probe drops a newest selected tombstone and violates safety. The checked
  three-action witness retains older/newer runs, merges the selected pair, preserves the tombstone in the output, and
  validates exact pre/post point reads.
- Unbounded evidence: strict SMT-backed TLAPS proves 5/5 obligations over arbitrary nonempty key/value sets for
  newest-mutation selection, tombstone retention, mutation composition, selected-pair equivalence, and equality after
  surrounding older/newer runs. The maintained combined TLA/TLAPS gate reruns all prior publication, isolation, LSM,
  cache, retention, replica, and range-normalization lanes.
- Findings cycle: the first explicit sweep found one P2: the finite model's named tombstone-retention invariant used
  disjoined implications and was weaker than its name, although exact merged-run equality still protected safety.
  The invariant now requires both tombstone cases conjunctively. Reverification and re-review find no remaining P0,
  P1, P2, or P3 issue. No Ada constants, allocations, tasks, persisted bytes, dependencies, or ownership contracts
  change in this unit.

## Accepted multipart-abort Object Storage qualification

- Parent: multipart-completion dependency qualification commit `9b20428`.
- Scope and provenance: fast-forward only the ignored clean Object Storage clone from
  `aeb10422ba8caafc7b3eda3eceaa9619fddbd005` to the explicitly qualified local-only boundary
  `425acbaa41833ed0613e277f50f68576b54f81f3`. The dirty author checkout remains read-only coordination state, the root
  filesystem path pin remains unchanged, and no DB declaration, format, allocation limit, retry, task, or publication
  policy changes in this unit.
- Surface and certainty: the dependency adds a caller-owned provider operation for AbortMultipartUpload and a
  synchronous result overload that literally waits on the same state machine. Only validated HTTP 204 is
  `Multipart_Aborted`; definite
  non-admission and pre-admission cancellation retain distinct spellings. Every complete rejection or post-admission
  failure is abort-outcome unknown and requires exact-upload read-only reconciliation. Its one-shot empty source is
  not replayed, no helper task is created, and no caller borrow survives the operation lifetime.
- Verification: the DB root build and maintained deterministic suite compile the complete DB/Object Storage/XML/HTTP/
  QUIC closure and exercise local engine, authenticated client, filesystem crash/recovery, the 32-case comparative
  adapter suite, and pinned TidesDB 4/4. Repository checks bind the campaign to the exact clean clone above. The
  warning-strict DB proof gate recompiles the dependency closure and proves all unchanged 1,088 selected checks; this
  unit does not substitute or claim upstream proof as DB evidence.
- Findings cycle: dependency provenance, API compatibility, abort certainty, empty-source lifetime, indexed transport
  resolution, author-checkout isolation, constants, tests, documentation, and unnecessary-surface review finds no
  remaining P0, P1, P2, or P3 issue. Historical review entries retain the exact dependency used by their campaigns.

## Accepted multipart-completion Object Storage qualification

- Parent: client-bound synchronous Flush convergence commit `5b30cdd`.
- Scope and provenance: fast-forward only the ignored clean Object Storage clone from
  `7550e45be97a0f5a1012ec81962a8bdff22decc2` to the explicitly qualified local-only boundary
  `aeb10422ba8caafc7b3eda3eceaa9619fddbd005`. The dirty author checkout remains read-only coordination state, the root
  filesystem path pin remains unchanged, and no DB declaration, format, allocation limit, retry, task, or publication
  policy changes in this unit.
- Surface and certainty: the dependency adds caller-owned provider operations for UploadPart preparation and
  CompleteMultipartUpload to its existing conditional Put, generation-bound whole/range Get, Head, Delete, and
  CreateMultipartUpload state machines. The synchronous multipart-completion form is a literal wait over the same
  operation. Exact serialized XML is owned and non-rewindable; there is no replay, helper task, or retained borrow.
  Only validated success is definite.
  A complete rejection, embedded HTTP-200 error, or post-admission failure remains completion-outcome unknown and
  requires destination plus exact-upload read-only reconciliation before any retry or abort.
- Verification: the DB root build and maintained deterministic suite compile the complete DB/Object Storage/XML/HTTP/
  QUIC closure and exercise local engine, authenticated client, filesystem crash/recovery, the 32-case comparative
  adapter suite, and pinned TidesDB 4/4. Repository checks bind the campaign to the exact clean clone above. The
  warning-strict DB proof gate recompiles the dependency closure and proves all unchanged 1,088 selected checks; this
  unit does not substitute or claim upstream proof as DB evidence.
- Findings cycle: dependency provenance, API compatibility, certainty, owned-body lifetime, indexed transport
  resolution, author-checkout isolation, constants, tests, documentation, and unnecessary-surface review finds no
  remaining P0, P1, P2, or P3 issue. Historical review entries retain the exact dependency used by their campaigns.

## Accepted client-bound synchronous Flush convergence candidate

- Parent: additive Object Storage composable-surface qualification commit `945b481`.
- Scope and compatibility: change no public declaration, parameter mode, default, result, persisted byte, dependency,
  task, retry, compaction policy, or memory/files behavior. Client-bound synchronous `Flush` now lazily owns a private
  completion set and buffer token and waits over the existing public additive `Flush_Operation`; backend-neutral
  memory/files `Flush` retains the existing synchronous publisher.
- Lifecycle and ownership: synchronous entry first holds an ordinary database lifecycle lease while it reads persisted
  sizing authority. After all operation validation and visible-slot reservation, one protected action atomically
  exchanges that exact lease for exclusive checkpoint ownership. A concurrent close, resolve, or checkpoint consumes
  the lease and returns `Invalid_State`; no gap can expose a dangling storage context. Start rollback restores the
  lifecycle, slot, and exact moved token. Typed `Finish` remains the sole normal token-restoration authority, and scope
  abandonment drains nested Object Storage/HTTP work before the private token returns to its pool. No helper task or
  retained caller handle is added.
- Bounds and certainty: the private four-slot completion set derives from the exact DB/Object Storage/HTTP/transport
  owner stack. Its one-token scratch pool is allocated only for the synchronous call. Checked U64 arithmetic derives
  the block extent from persisted live-entry, live-byte, total-run, identity, and immutable family-name authority plus
  frozen SST-v1, manifest-v3, and HEAD framing; there is no new public or private byte ceiling. Declarative allocation
  failure is definite `Capacity_Exceeded`. Any later exception is classified at the retained receipt phase, so a
  post-entry mutation is never mislabeled pre-admission and unknown publication remains `Outcome_Unknown`.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository/provenance checks, deterministic
  memory/files cases, authenticated client operations, subprocess crash/reopen, all 32 comparative cases, and pinned
  TidesDB 4/4. The client probe covers synchronous definite pre-run failure, successful synchronous accepted-but-lost
  run reconciliation and local activation, composable definite pre-HEAD failure with exact tagged-token restoration,
  and later composable replacement/reopen. Warning-strict GNATprove proves 1,088/1,088 selected checks (165 flow, 923
  prover; maximum 6,890 steps), with zero warnings, unproved/justified checks, or `pragma Assume`; the operational
  lifecycle and provider stack remain executable-test boundaries rather than SPARK-proved code. The unchanged
  combined TLC/TLAPS gate passes every maintained publication, LSM, compaction, cache, retention, replica, isolation,
  and range-normalization lane plus its checked witnesses and deliberate negative probes; this unit adds no lifecycle
  refinement claim.
- Findings cycle: the first ownership sweep found a P1 self-deadlock when the fallback retained its own read lease
  while requesting exclusive checkpoint mode; explicit release before the unchanged backend-neutral publisher fixed
  it. The next sweep found a P1 declarative allocation escape and a P2 missing successful synchronous-client witness;
  an already-elaborated call boundary and stronger probe fixed both. The final certainty sweep found a P1 late-cleanup
  misclassification risk; body-entry tracking now distinguishes definite allocation from post-entry receipt phases.
  Repeated API, lifecycle, ownership, certainty, allocation, constants, tests, proof, documentation, and
  unnecessary-surface review finds no remaining P0, P1, P2, or P3 issue.

## Accepted additive Object Storage composable-surface qualification

- Parent: operational scan-range normalization commit `b8c2cda`.
- Scope and provenance: fast-forward only the ignored clean Object Storage clone from `ab88c9117194a062ec208ee6d1503606ffd96307`
  to the explicitly qualified local-only boundary `7550e45be97a0f5a1012ec81962a8bdff22decc2`. The author checkout remains
  read-only coordination state, the root filesystem path pin remains unchanged, and no DB declaration, format,
  allocation limit, retry, task, or publication policy changes in this unit.
- Surface and certainty: the dependency adds caller-owned provider operations for Delete and CreateMultipartUpload
  to its existing conditional Put, generation-bound whole/range Get, and Head state machines. Existing DB checkpoint
  calls
  continue using the same conditional-Put and whole-Get paths. No mutation result is inferred from an exception:
  absent definite pre-admission certainty remains `Outcome_Unknown`, read-only reconciliation is generation-bound,
  and no automatic retry or retained borrowed input is introduced.
- Verification: the root build and maintained deterministic suite compile the complete DB/Object Storage/XML/HTTP/
  QUIC closure and exercise local engine, authenticated client, filesystem crash/recovery, the 32-case comparative
  adapter suite, and pinned TidesDB upstream 4/4. Repository checks bind the campaign to the exact clean clone above.
  The warning-strict DB proof gate recompiles the dependency closure and proves all unchanged 1,088 selected checks;
  this unit does not substitute or claim upstream proof as DB evidence.
- Findings cycle: dependency provenance, API compatibility, certainty, ownership, indexed transport resolution,
  author-checkout isolation, constants, tests, documentation, and unnecessary-surface review finds no remaining P0,
  P1, P2, or P3 issue. Historical review entries retain the exact dependency used by their original campaigns.

## Accepted operational transaction-owned scan-range normalization

- Parent: formal normalization boundary `8d94972`.
- Scope and compatibility: implement the frozen half-open union rule inside the existing public `Observe_Range` and
  `Scan` behavior without adding a declaration, result literal, default, persisted field, dependency, task, request,
  retry, or publication path. Snapshot calls still validate without retention. Serializable calls now count
  normalized components rather than exact distinct predicates, so overlapping/touching calls that previously could
  reach `Capacity_Exceeded` can succeed without weakening any conflict.
- Ownership and atomicity: production computes transitive same-family closure and the final endpoints before count
  admission. It fully allocates and copies one replacement node, then unlinks and frees every merged component and
  publishes the exact derived count. Node/lower/upper allocation failure frees only the unlinked replacement and
  leaves every old node and endpoint exact. The coordinator owns an admitted arena, so the list cannot race caller
  mutation; rollback, consumption, and finalization retain the existing complete-list release path.
- Bounds and authority: the persisted database-wide range count continues to be the sole component ceiling, and the
  selected family's persisted key limit remains the endpoint authority. Merging is admitted even at the ceiling;
  only a new disjoint component can exceed it. The reference model's `Max_Ranges` closure passes derive from its
  complete fixed oracle array and establish no runtime retry, capacity, or work budget. Test counts, families, keys,
  fault sites, identities, and tags retain adjacent corpus-authority comments; no production value is introduced.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository checks, deterministic memory and
  files campaigns, authenticated client operations, subprocess crash/reopen, 32 pinned comparative cases, and
  TidesDB 4/4. New witnesses cover containment, cross-family separation, disjoint one-over rejection, two-component
  bridge rollback and retry, lower/upper replacement rollback, open-lower expansion at full capacity, and a
  post-Begin conflict inside the merged union. Warning-strict GNATprove proves 1,088/1,088 checks (165 flow, 923
  prover; maximum 6,890 steps) with zero warnings, unproved/justified checks, or `pragma Assume`. The unchanged
  combined TLA gate remains green at 3,419 states and 19/19 obligations for this lane.
- Findings cycle: immediate ownership review found two P1 draft defects before execution: one comparator referenced
  an unbuilt candidate, and endpoint-source pointers could have outlived freed nodes. Total stored/input comparison
  and rebinding to the fully built candidate removed both hazards. The proof sweep found a P1 semantic mismatch in
  the exact-deduplicating SPARK oracle; it now publishes a complete normalized replacement atomically. A first
  conflict witness correctly exposed missing transaction mutation admission and was repaired with an out-of-range
  marker. The repeated API, ownership, concurrency, bounds, constants, formal-model, tests, documentation, and
  unnecessary-surface sweep finds no remaining P0, P1, P2, or P3 issue.

## Accepted transaction-owned scan-range-normalization boundary

- Parent: canonical empty-output L0-compaction commit `c8003b5`.
- Scope and compatibility: add one independent TLA+/TLAPS lane that freezes normalization before modifying the
  private transaction-owned range list. It changes no Ada declaration or behavior, persisted byte, dependency,
  public default, count, endpoint bound, or allocation policy. The current runtime therefore remains exact-distinct
  until the paired operational unit lands.
- Authority and semantics: same-family half-open ranges coalesce when overlapping or touching; a bridge atomically
  merges every connected component. Cross-family ranges remain distinct. A merge is admissible at the persisted
  count ceiling, while a new disjoint component can produce typed backpressure. Capacity and modeled allocation
  failure preserve the exact retained set and covered-key union. Two families, four key positions, and count two are
  finite qualification geometry only; no product value is selected.
- Verification: focused TLC exhausts 3,419 states at depth 4 with nonzero coverage for success, capacity rejection,
  and allocation rejection. The negative probe performs an incomplete bridge merge and violates `Safety`. The
  independently parsed eight-state witness covers two separated ranges, transitive bridging, cross-family
  retention, disjoint-component backpressure, a merge while full, and allocation rollback. TLAPS proves 19/19
  strict obligations over arbitrary range and qualified-key universes under the explicit pure-normalizer contract.
  The authoritative combined TLA+/TLAPS gate passes with the new lane enabled.
- Findings cycle: the first proof attempt exposed that recursive finite-set cardinality was outside the SMT kernel;
  it was replaced with an explicitly abstract count while concrete cardinality remains exhaustively checked by TLC.
  The review also made the runtime-not-yet-landed boundary explicit and retained exact rejection state in the
  witness validator. The repeated semantics, capacity, atomicity, constants, witness, negative-probe, script,
  documentation, and unnecessary-surface sweep finds no remaining P0, P1, P2, or P3 issue.

## Accepted LSM compaction read-equivalence boundary

- Parent: private monotonic replica-refresh commit `84b04f7`.
- Scope and compatibility: add one independent TLA+/TLAPS lane for the concrete point-read equation of complete
  live-state replacement. It changes no Ada declaration, persisted byte, dependency, public compaction trigger,
  schedule, run-level policy, retention rule, or capacity.
- Authority and semantics: a replacement emits the captured live value for each key and no mutation for captured
  absence; it never persists a tombstone in the complete live-state output. Applying that run to an empty view must
  reconstruct every captured read, and applying any later Put/Delete/no-mutation delta must equal applying the same
  delta directly to the capture. Two keys and two values are finite qualification geometry only; the TLAPS kernel is
  quantified over arbitrary nonempty key/value sets.
- Verification: focused TLC exhausts 576/576 states at depth 4 with nonzero coverage for build, recovery, and later
  replay. The negative probe omits one captured live key and violates `Safety`. The independently parsed four-state
  trace captures one live and one absent key, recovers them exactly, then deletes the former and puts the latter.
  TLAPS proves 6/6 strict obligations for canonical replacement and read equivalence.
- Findings cycle: the repeated sentinel-separation, total-function-domain, absence-versus-tombstone, witness,
  negative-probe, script-pinning, documentation, compatibility, and unnecessary-surface sweep finds no P0, P1, P2,
  or P3 issue. The authoritative combined gate passes with the new lane enabled.

## Accepted private monotonic replica-refresh candidate

- Parent: private composable L0-replacement commit `68f89d8`.
- Scope and compatibility: add one private, synchronous, caller-triggered refresh over the existing lifecycle and
  cacheless recovery path. It adds no public declaration, replica registration, polling task/cadence, lease, retry,
  promotion policy, persisted field, format change, cache budget, or provider behavior.
- Authority and concurrency: refresh drains queued work and active lifecycle leases before capturing the installed
  HEAD transition ordinal/writer epoch. It validates one complete immutable recovery graph, installs only a strictly
  newer lexicographic pair, treats the exact same HEAD as a no-op, and discards older observations. Allocation occurs
  before the old worker is joined; definite allocation failure reopens the unchanged engine. A fenced handle returns
  `Stale_Writer`, so refresh cannot act as implicit writer promotion.
- Bounds and constants: every recovery/engine allocation retains existing authenticated database and per-family
  limits with checked arithmetic and lazy ownership. The test's two keys/values and following identities separate
  lag, catch-up, local-loss, and fencing roles only. No cache capacity or refresh timeout/default is invented; the
  operation receives its sole monotonic deadline from the private caller.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository/provenance checks, deterministic
  memory/files cases, authenticated client and filesystem crash/recovery, all 32 comparative cases, and pinned
  TidesDB 4/4. Focused memory/files witnesses cover lagging absence, first catch-up, exact same-HEAD no-op, allocation
  failure with the newer key still absent, retry to the exact newer values, close/reopen local loss, stale-write
  fencing, and refusal to refresh the fenced handle. The combined TLA gate preserves the 1,460-state/11-obligation
  refresh proof and both stale-writer and rollback negative probes; GNATprove preserves 1,084/1,084 selected checks.
- Findings cycle: the first compile found a testing literal/type name collision and warning-strict redundant
  annotations; both were narrowed without semantic change. The first findings sweep found a P2 witness gap: sequence
  checks alone did not prove failed refresh kept newer bytes absent. The strengthened test reads that absence and
  also performs complete local-loss reopen. The repeated authority, monotonicity, fencing, concurrency, ownership,
  allocation, constants, tests, proof, documentation, and unnecessary-surface sweep finds no remaining P0, P1, P2,
  or P3 issue.

## Accepted private composable L0-replacement candidate

- Parent: formal replica-refresh and fencing commit `75a1319`.
- Scope and compatibility: route the already-operational complete current-run replacement algorithm through the
  existing caller-owned `Flush_Operation` behind the parent package's private test surface. Public `Start_Flush`
  remains additive; no public declaration, default, trigger, schedule, task, persisted field, retention rule, or
  physical deletion authority is added.
- Ownership and certainty: one body-local constructor contains the shared start transaction. Validation, lifecycle
  and completion-slot admission precede the exact token move; initiating exceptions roll back the slot and ownership.
  Both modes use the same Object Storage children, absolute deadline, typed `Finish`, receipt projection, and
  same-identity whole-Get reconciliation. The driver retains only private Boolean algorithm mode, adjacent-commented
  as nonpersisted and nonpolicy.
- Bounds and constants: the authenticated fixture's three manifest-history slots are exactly root, additive
  checkpoint, and replacement checkpoint. IDs 9/10/11 distinguish the replacement run/manifest/transition, and the
  existing one-token/four-slot geometry is unchanged. These are test witnesses, not library defaults; production
  allocations remain lazy and checked against persisted database and per-family limits.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository/provenance checks, deterministic
  memory/files cases, authenticated additive Flush plus replacement and cacheless reopen, filesystem crash/recovery,
  all 32 comparative cases, and pinned TidesDB 4/4. The replacement witness loses the run response after provider
  entry, reconciles exact bytes without retry, restores the exact tagged token, reports replacement authority, and
  reopens with the committed bytes. Warning-strict GNATprove proves 1,084/1,084 selected-unit checks; the combined
  TLA gate preserves the 15-state/26-obligation compaction proof and all earlier formal lanes.
- Findings cycle: the first executable pass exposed the fixture's two-entry manifest history as insufficient for a
  root plus two checkpoints; the test now authorizes exactly three. The API sweep added the same ownership contract
  to the private constructor as public `Start_Flush`. A formatter fallback touched unrelated whitespace after the
  maintained project-mode formatter rejected global preprocessor symbols; the complete accidental delta was removed
  before verification. The repeated API, certainty, crash safety, concurrency, ownership, constants, tests, proof,
  documentation, and unnecessary-surface sweep finds no remaining P0, P1, P2, or P3 issue.

## Accepted formal replica-refresh and fencing candidate

- Parent: immutable-object retention commit `c24ea4c`.
- Scope: freeze exact writer fencing and monotonic read-only refresh without Ada/API/format changes or polling,
  lease, promotion, tasking, or retry policy. A captured confirmed HEAD pair may install after authority advances, but
  never below the replica high-water pair; writer ordinal and epoch must both remain exact at publication.
- Verification: TLC exhausts 1,460 states/depth 15 with all nine actions covered. Stale-writer and rollback probes
  violate `Safety`; the validated 16-state witness covers fencing, replacement publication, lagging installation,
  and catch-up. TLAPS proves 11/11 obligations over arbitrary natural ordinal/epoch values; the finite two/one bounds
  are adjacent-commented qualification geometry.
- Findings cycle: the first executable pass found a P2 malformed disjunction token in the captured-refresh invariant;
  correction produced the complete safe graph. The first strict proof pass found eight proof-boundary failures
  because named finite phase sets were not unfolded through `TypeOK`; inlining those exact phase sets made all 11
  obligations explicit and proved. The repeated fencing, monotonicity, certainty, constants, proof/model,
  documentation, and unnecessary-surface sweep finds no remaining P0, P1, P2, or P3 issue.

## Accepted formal immutable-object retention candidate

- Parent: formal immutable-cache commit `42a78f6`.
- Scope and compatibility: freeze deletion safety without changing Ada, public declarations, persisted formats, or
  storage behavior. Current authority, snapshots, replicas, required predecessors, and unresolved publication
  attempts independently protect exact immutable identities. Listing plus explicit age eligibility only nominate a
  candidate; deletion rechecks live protection, and deleted identities are never reused.
- Authority and constants: object storage remains the sole durable authority, while the database's reachability and
  active leases grant retention authority. The exhaustive two-identity graph and third orphan identity in the exact
  witness are adjacent-commented qualification geometry. No age duration, clock source, lease timeout, delete batch
  size, retry, public constant/default, or physical reclamation policy is introduced.
- Verification: focused TLC exhausts 75,337 distinct states at depth 16 with nonzero coverage for all 13 semantic
  actions. The listing-only negative probe violates `Safety`; the exact 24-state machine-validated witness covers
  snapshot/replica/predecessor/unknown protection, release and predecessor deletion, disposable discovery loss,
  reconstruction, and resolved-orphan deletion. Strict TLAPS proves all 15 arbitrary-set action-preservation
  obligations. The combined TLA and repository gates preserve all earlier campaigns.
- Findings cycle: the initial unconstrained three-object inventory was safe but produced 3,209,921 distinct and
  40,997,304 generated states, too broad for the maintained fast gate. The final exhaustive graph removes only one
  symmetric identity while the exact witness retains the distinct orphan and TLAPS retains arbitrary-set generality.
  The first witness pass found a P1 terminal-predicate error expecting discovery evidence to survive an explicit
  discard; the corrected predicate requires it empty after reconstructed O2 evidence is consumed. The architecture
  repeat found a second P1 abstraction gap: current authority was one object rather than the complete reachable
  closure. Both finite and arbitrary-set kernels now protect a nonempty current-object set and atomically transfer
  that full set to snapshot, replica, and predecessor retention. The repeated authority, race, listing, age,
  identity reuse, uncertainty, constants, model/proof, documentation, and
  unnecessary-surface sweep finds no remaining P0, P1, P2, or P3 issue. Concrete traversal, clocks, retention
  horizons, provider deletion certainty, batching, progress, public API, and Ada refinement remain later units.

## Accepted formal immutable-cache candidate

- Parent: indexed HTTP/QUIC dependency handoff commit `8eae273`.
- Scope and compatibility: freeze a disposable exact-generation cache/coalescing safety algorithm without changing
  Ada, public declarations, persisted formats, disk layout, or resource policy. A read captures one immutable object
  generation; cache hits, fetch ownership, joined waiters, and results must match it exactly. Corruption is a miss,
  and complete local loss removes only disposable cache/fetch state.
- Authority and constants: object storage remains the sole authority and old immutable generations remain stored
  history rather than aliases for current data. The finite two-entry/two-reader and zero-versus-one-capacity values
  are adjacent-commented qualification geometry. No cache-byte ceiling, default, timeout, retry, eviction rule,
  public constant, or compatibility promise is introduced.
- Verification: focused TLC exhausts 623 distinct states at depth 12 with nonzero coverage for all 11 semantic
  actions. The stale-generation negative probe violates `Safety`; the exact 20-state machine-validated witness covers
  coalescing, authority advance, local loss with a retained request, refetch, corruption rejection, and final exact
  recovery. Strict TLAPS proves all 13 arbitrary-set action-preservation obligations. The combined TLA and repository
  gates preserve all earlier campaigns.
- Findings cycle: the first proof pass found a P1 inductiveness defect in the abstract kernel: a completed result
  could start another fetch for the same entry and then `FinishRead` could remove the last request supporting that
  fetch. `FinishRead` now requires the entry not be fetching. The repeat sweep found a P2 fidelity gap in that repair:
  abstract `StartFetch` still admitted already-cached or already-completed requests unlike the finite algorithm. It
  now requires an uncached, noncorrupt entry with a pending exact request. The first proof also found two P2 boundary
  omissions: `Init` did not restate the assumed initial-entry membership, and quiescence did not expand the variable
  tuple. Both are explicit now, and the repeated authority, stale-generation, coalescing, corruption, loss,
  constants, proof/model, documentation, and unnecessary-surface sweep finds no remaining P0, P1, P2, or P3 issue.
  Operational allocation, capacity/eviction policy, disk cache, checksum implementation, progress, and Ada
  refinement remain later units.

## Accepted indexed HTTP/QUIC dependency handoff

- Parent: private operational L0-compaction spine commit `12e6600`.
- Scope and provenance: fast-forward only the ignored clean Object Storage clone from `e8362f7` to the explicitly
  qualified no-pin boundary `ab88c9117194a062ec208ee6d1503606ffd96307`. The dirty author checkout remains
  read-only coordination state and its newer unqualified commits are not build inputs. The root filesystem path pin
  remains unchanged and no source or public DB declaration changes.
- Solve: the refreshed Object Storage manifest requires exact indexed `flyology_http=0.1.3-dev`; Alire resolves HTTP
  and QUIC unpinned at source commit `a65f24f473bd771356a4fcb355fc10f961202534`. The generated ignored lock contains
  no pinned HTTP/QUIC entry. This replaces the provisional PR-head closure without selecting a floating source.
- Verification: the root build and maintained deterministic suite compile the complete DB/Object Storage/XML/HTTP/
  QUIC closure and exercise local engine, authenticated client, filesystem crash/recovery, the 32-case comparative
  adapter suite, and pinned TidesDB upstream 4/4. The DB proof and repository gates are rerun against the exact clean
  clone rather than treating upstream qualification as a substitute.
- Findings cycle: dependency, API compatibility, certainty, ownership, transport pinning, generated solve, author-
  checkout isolation, historical evidence, and unnecessary-surface review finds no P0, P1, or P2 issue. Historical
  review entries retain the dependency SHA used by their original campaigns; only current-campaign provenance moves.

## Accepted private operational L0-compaction spine

- Parent: formal L0-compaction freeze commit `2b47dcc`.
- Scope and compatibility: implement complete current-run replacement behind the private testing surface without a
  new public declaration, persisted field, default, trigger, scheduling rule, or physical reclamation. Additive
  `Flush` remains unchanged. Replacement emits one complete live-state run per nonempty family and a successor
  checkpoint manifest naming only those fresh runs at the captured replay boundary.
- Authority, bounds, and effects: database and family run admission derives from authenticated persisted limits;
  exact snapshot, SST, manifest, and activation-base allocations are lazy and checked before provider entry. A
  current immutable run identity is rejected. Allocation or identity failure publishes no run, manifest, or HEAD.
  Superseded objects remain stored; test-only removal proves depublication and grants no deletion authority.
- Certainty and ownership: the shared synchronous checkpoint publisher preserves immutable-object confirmation before
  conditional HEAD admission and retains the existing receipt/result mapping. A private receipt bit records only
  whether exact `Objects_Unknown` reconstruction is additive or replacement, preventing reconciliation from changing
  bytes or authority. Accepted response loss remains `Outcome_Unknown`; resolution uses the same identities and
  performs no retry. The exclusive checkpoint gate drains active work, and activation transfers the prepared graph
  before the replaced engine is joined and released.
- Verification: `./tests/scripts/test.sh` passes all maintained builds, repository checks, memory/files engine cases,
  authenticated client, filesystem crash/recovery, 32-case pinned adapter suite, and TidesDB 4/4 corpus. New cases
  cover all replacement allocation classes, current-ID rejection, exact full-view entry counts, tombstone removal,
  publication order, live activation, retired-run removal, cacheless reopen, and lost immutable-output response
  reconciliation. GNATprove proves 1,084/1,084 checks. The combined TLA gate preserves every prior lane and reports
  L0 compaction at 35 states/depth 10 and 26/26 TLAPS obligations with ordinary and canonical-empty witnesses plus
  the negative probe. The memory/files corpus now creates Put and tombstone L0 runs, publishes a zero-run successor,
  removes both retired SSTs, reopens the absent value, and then publishes/reopens an exact later delta. Repository
  and 110-column checks pass. Project-aware `gnatformat` cannot load the global preprocessing symbols, so the new
  procedure was range-formatted at 110 columns in project-free mode without reformatting unrelated code.
- Constants audit: the broad added-value inventory reduces to a private Boolean algorithm mode and isolated test
  identities/allocation-site geometry. Adjacent comments record their runtime/test classification and compatibility
  impact. All capacities and extents remain derived from persisted database/per-family authority; no new timeout,
  retry count, byte ceiling, format tag, public constant, or default is introduced.
- Findings cycle: the first independent sweep found a P1 documentation mismatch that still described every
  operational compaction component as pending. README, milestone, architecture, proof-status, and review claims now
  distinguish the private planner/publisher from the still-pending public synchronous/composable surface, automatic
  policy, retention, and GC. The unnecessary-surface pass also removed a speculative replacement-mode field from the
  composable driver because no authorized constructor can select it yet. The repeated API, certainty, crash safety,
  concurrency, ownership, bounds, formats, constants, tests, proof, documentation, and unnecessary-surface sweep
  finds no remaining P0, P1, P2, or P3 issue.

## Accepted formal L0-compaction candidate

- Parent: operational additive-L0 commit `236fd1c`.
- Scope and compatibility: freeze complete replacement of an accumulated current run set without changing Ada,
  public declarations, persisted formats, automatic scheduling, or physical reclamation. The successor manifest
  names only fresh complete compacted output; superseded current runs remain confirmed immutable stored history.
- Authority and certainty: compaction captures exact visible and admitted-identity authority at the current replay
  boundary. Output and manifest confirmation precede the exact-generation HEAD transition. Definite output-capacity
  rejection has no effects; an accepted lost response remains unknown until read-only resolution. Missing compacted
  output fails recovery closed. The finite zero-versus-one capacity is branch geometry, not a product default.
- Verification: focused TLC exhausts 15 states at depth 10 with nonzero action coverage. The early-HEAD probe violates
  safety, and the machine-validated ten-action witness selects admission, complete output/manifest confirmation,
  accepted-lost publication, resolution, crash, and exact recovery from only the compacted run. Strict TLAPS proves
  all 26 obligations for arbitrary fresh output sets and unbounded cycles. The combined model gate preserves every
  earlier graph, witness, probe, and proof.
- Findings cycle: the first proof found that freshness cannot be stated as disjointness from all stored runs after an
  output has itself been stored. It is now retained as separation from current and retired authority, while the Begin
  guard establishes initial disjointness from storage. A second proof pass confirmed that this stronger stable
  relation makes retired/current separation inductive across publication. Repeated authority, certainty, capacity,
  retention, recovery, constants, model, witness, documentation, and unnecessary-surface review finds no remaining
  P0, P1, P2, or P3 issue. Public API spelling, automatic policy, snapshot/replica retention, physical GC, concrete
  merge, and Ada refinement remain explicit later units.

## Accepted operational additive-L0 accumulation candidate

- Parent: formal additive-L0 freeze commit `06d47e4`.
- Scope and compatibility: implement the frozen suffix-delta algorithm without a new public declaration or persisted
  format. First Flush still emits complete family runs. Each later Flush emits at most one canonical newest-mutation
  run per affected family, preserves tombstones, retains prior descriptors oldest-to-newest, and permits a
  manifest-only empty suffix under the existing receipt contract.
- Capacity and effects: exact dynamic run/image/base extents derive from authenticated manifests, SSTs, persisted
  database limits, and per-family limits. Checked arithmetic, allocation rollback, per-family run admission, and the
  independent database-wide run admission all complete before storage publication. Deterministic tests confirm both
  capacity failures publish no run, manifest, or HEAD object.
- Recovery and ownership: cacheless Open reads and authenticates every named run, applies deletes before replacements
  and absent inserts within each run, merges runs oldest-to-newest, and trims merge scratch to the exact live base.
  Local activation retains the quiescent coordinator's exact live images instead of rereading storage. The new engine
  alone owns the transferred image/base/manifest graph; replacement joins the old worker before releasing its graph.
  No helper task, retry, provider listing, retained borrowed caller input, or second certainty authority was added.
- Verification: `./tests/scripts/test.sh` passes the full memory/files, authenticated-client, files crash/recovery,
  32-case pinned adapter, and 4/4 TidesDB upstream corpus. The two-generation witness proves newer Put replacement,
  tombstone masking, unchanged-key recovery from the older run, exact sequence authority, and cacheless reopen.
  `./scripts/prove.sh` proves 1,084/1,084 checks. `./scripts/check-tla.sh` preserves every prior graph and proves the
  additive-L0 49-state/24-obligation campaign with its negative probe and exact lost-response recovery witness.
  Repository checks and `git diff --check` pass. Project-mode `gnatformat` remains blocked by the repository's global
  preprocessor symbols; warning-strict compilation and a 110-column source audit are clean.
- Findings cycle: the separate compatibility, capacity, certainty, crash safety, concurrency, ownership, allocation,
  constants, documentation, and unnecessary-surface sweep found no remaining P0, P1, P2, or P3 issue. Compaction,
  run pruning, automatic flush policy, physical merge iteration, and remote-provider qualification remain explicit
  later units rather than implied claims.

## Accepted formal additive-L0 accumulation candidate

- Parent: successive whole-state checkpoint commit `3f19103`.
- Scope and compatibility: freeze the next algorithm without changing Ada runtime behavior or public declarations.
  A new per-family suffix run appends to the existing oldest-to-newest descriptor set; it never rewrites an immutable
  run. The delta retains its newest exact-key Put or tombstone, advances the replay boundary, and preserves exact
  identity authority. Empty families consume no mapped identity; an empty suffix may publish a manifest-only
  successor, preserving the established Flush completion contract. Multi-run Ada activation/recovery and compaction
  remain separate units, so this change makes no operational or full-LSM claim.
- Authority and certainty: independent family and aggregate run admission derives solely from persisted
  `Maximum_L0_Runs` and `Maximum_Total_L0_Runs`; the model's one-versus-two values are finite branch geometry, not
  defaults. Every new run and manifest must be stored and confirmed before the conditional HEAD transition. A lost
  accepted response remains unknown until read-only resolution. There is no retry, replacement identity, helper task,
  transport rule, new format field, or new resource ceiling.
- Verification: focused TLC exhausts 49 states at depth 17 with nonzero semantic-action coverage. Its negative early
  HEAD action violates safety. A machine-validated 18-action witness selects admitted two-run accumulation, explicit
  tombstone masking, accepted-lost response, resolution, crash, and exact recovery while retaining both immutable
  runs and the predecessor manifest. Strict TLAPS proves all 24 obligations in the arbitrary-set, unbounded-cycle
  kernel. The combined repository model gate preserves every earlier pinned graph, witness, negative probe, and proof.
- Findings cycle: the architecture sweep kept suffix tombstones explicit and retained oldest-to-newest disjoint
  sequence ordering rather than treating absence or provider listing as authority. It also preserved successful empty
  Flush semantics through a manifest-only successor instead of inventing an automatic-flush threshold or a new
  public operation. The formal sweep separated concrete tombstone merge (finite TLC) from abstract append and
  publication safety (unbounded TLAPS) and states that no refinement to Ada is proved. Repeated compatibility,
  certainty, capacity, constants, storage, model, witness, and documentation review finds no remaining P0, P1, P2,
  or P3 issue.

## Accepted successive whole-state checkpoint candidate

- Parent: bounded fixed-snapshot scan commit `eb96a96`.
- Scope and compatibility: extend the existing synchronous/composable `Flush` state machine so every later nonempty
  flush writes one complete current-state SST per family, publishes a new immutable checkpoint manifest naming only
  those replacement runs, and advances the existing conditional authority head. Public signatures, result kinds,
  defaults, formats, and ownership do not change. Old runs and manifests remain immutable stored predecessors for
  later garbage collection. This is repeated complete-snapshot replacement, not multi-run L0 accumulation or
  compaction, and makes no full-LSM claim.
- Authority, certainty, and ownership: the authenticated `Maximum_Manifest_History` is the sole chain-depth authority;
  an exhausted history returns `Capacity_Exceeded` before run, manifest, or HEAD effects. `Registry_Revision` is the
  exact one-based chain depth. The operation owns its plan and exact caller-supplied identities, uses no helper task or
  retry, and retains the established conditional publication mapping. A lost accepted replacement HEAD response is
  `Outcome_Unknown` until read-only reconciliation proves the exact transition or a conclusive successor. Recovery
  reads every dynamic predecessor header-first, validates the checkpoint-specific chain, reconstructs only the
  current replacement runs, and fails closed when a named predecessor is absent or malformed.
- Constants audit: 282 added nonblank Ada lines yield 67 broad numeric/default/Boolean inventory matches and 14
  declared constants. Consequential values reduce to exact ordinal/epoch gaps derived from persisted predecessor and
  successor fields, isolated replacement identity ranges, and the two-slot persisted-history branch fixture. Their
  adjacent comments state purpose, stable source authority, test or derived classification, and compatibility impact.
  Routine indexing, increments, neutral initialization, scenario bytes, and values directly copied from persisted
  authority introduce no independent choice. No production capacity, byte ceiling, timeout, retry, format tag,
  default, or public constant is introduced, and no policy decision remains unresolved.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository checks, deterministic memory/files
  engine tests, authenticated create/commit/Flush/reopen, filesystem subprocess crash/recovery, 32 comparative cases,
  pinned TidesDB 4/4, and all fixtures. New witnesses cover two successive checkpoints, exact replacement state,
  fixed-snapshot reads, cacheless reopen, old immutable retention, missing dynamic predecessor corruption, persisted
  two-slot backpressure without effects, and accepted-but-lost replacement HEAD reconciliation. The combined
  `./scripts/check-tla.sh` gate adds a 37-state/depth-17 model, validated 18-action recovery witness, rejected early
  HEAD probe, and 24/24 strict TLAPS obligations while preserving every prior lane. Warning-strict FSF GNATprove
  16.1.0 proves 1,084/1,084 selected-unit checks (164 flow, 920 prover; maximum 6,890 steps), with zero warnings,
  unproved/justified checks, or `pragma Assume`.
- Findings cycle: the runtime sweep found a P1 cacheless-recovery defect: older dynamic checkpoint predecessors were
  decoded through the fixed legacy path and then checked with the ordinary registry predicate. Header-first decode of
  every dynamic predecessor plus an exact checkpoint-base predecessor predicate fixes the chain without weakening
  corruption rejection. The formal sweep made initial identity/transaction authority explicit for TLAPS, required
  the execution witness to resolve the lost response before crash, and added the missing-predecessor corruption case.
  A formatting sweep removed broad mechanical churn after project-mode `gnatformat` rejected the repository's global
  preprocessor configuration. Repeated API, ownership, concurrency, bounds, constants, format, certainty, test,
  documentation, and proof review finds no remaining P0, P1, P2, or P3 issue.

## Accepted bounded fixed-snapshot scan candidate

- Parent: operational serializable range-validation commit `2f64062`.
- Scope and API: add limited controlled `Scan_Result`, synchronous `Scan`, exact row count, and one-based row-copy
  access. `Scan` materializes the complete selected-family half-open interval at the transaction's fixed snapshot,
  applies transaction-local Put/Delete precedence, and orders arbitrary-byte keys lexicographically as unsigned
  bytes. Endpoint flags and validation are identical to `Observe_Range`; there is no page token, batch size, timeout,
  storage request, helper task, or compatibility default. Exact result rows and combined key/value bytes use the
  persisted database live-entry/live-state limits, while individual extents use the selected family's persisted
  limits. Rows are replaced atomically only on Success. Serializable predicate retention follows complete
  materialization, so failure changes neither the prior result nor the transaction observation set.
- Allocation, ownership, and concurrency: a lifecycle lease prevents close or checkpoint replacement while transient
  descriptors borrow immutable checkpoint and retained-batch images. Exact source requirements and copying are brief
  protected operations; source-array allocation, fixed-snapshot lookups, byte copying, descriptor sorting, and result
  construction occur outside the coordinator. Post-snapshot commits cannot enlarge the eligible source set because
  only transaction sequences no later than Begin are copied. The result owns one exact descriptor array and combined
  payload through a controlled state pointer; successful empty scans own no allocation. Four deterministic fault
  points cover source, state, descriptor, and payload allocation. Every failure releases scratch, leaves the old
  result byte-exact, and classifies allocation exhaustion as `Capacity_Exceeded` without partial publication.
- Constants audit: 1,080 added nonblank Ada lines produced 320 broad inventory matches for numerals, defaults,
  aggregates, ranges, and type-bound references, including 25 declared constants. Consequential findings reduce to
  the isolated identity/key witness domain, four test-only allocation positions, the endpoint one-byte-over derivation,
  the persisted eight-entry/2,560-byte checkpoint fixture, and the exact two-row/four-byte boundary fixture. Each has
  adjacent purpose, authority, classification, and compatibility commentary. Derived lengths, offsets, one-based
  loops, comparator arithmetic, neutral initialization, and scenario bytes introduce no independent choice. No
  production bound, timeout, retry, format tag, capacity, or default is introduced, and no policy decision remains
  unresolved.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository/provenance checks, deterministic
  format/policy/model and memory/files engine tests, authenticated create/commit/Flush/reopen, filesystem subprocess
  crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and every adapter fixture against clean Object Storage
  `e8362f72e5edf4cc8eb16e31d1fdbfba74db384b`. New memory/files witnesses cover arbitrary-byte ordering, fixed
  snapshot after replace/delete/insert, local Put/Delete/insert precedence, half-open endpoints, invalid/bounded
  endpoints, all allocation failures, invalid row access, Snapshot non-retention, Serializable retention/retry and
  phantom conflict, checkpoint plus suffix after reopen, and exact/one-over persisted row and byte limits.
  `./scripts/check-tla.sh` preserves every model lane, including the 112,031-state publication graph, and passes the
  44,244-state/10-obligation serializable gate and every negative probe. Warning-strict FSF GNATprove 16.1.0 proves
  1,084/1,084 selected-unit checks (164 flow, 920 prover; maximum 6,890 steps), with zero warnings,
  unproved/justified checks, or `pragma Assume`. Public leading-style GNATdoc HTML renders `Scan_Result`, `Scan`, all
  nine parameters, `Scan_Row_Count`, and `Read_Scan_Row`; the warning inventory remains confined to existing older
  repository and dependency entities.
- Findings cycle: the first compile/API sweep replaced a directly controlled visible result representation with one
  private controlled owner, avoiding multiple controlling tagged operands without weakening automatic reclamation.
  The concurrency sweep moved exact source allocation out of the protected coordinator and retained only immutable
  borrows under the lifecycle lease. The executable sweep added checkpoint/suffix/reopen coverage, gave the scan
  fixture enough explicitly documented persisted checkpoint authority rather than weakening Flush validation, and
  tightened individual seed diagnostics and fixture identity documentation. A formatting sweep removed accidental
  legacy-file churn after project-mode `gnatformat` rejected the repository's global preprocessor configuration; all
  changed handwritten Ada is independently verified at no more than 110 columns. Repeated API, ownership,
  concurrency, bounds, constants, format, certainty, test, documentation, and proof review finds no remaining P0,
  P1, P2, or P3 issue.

## Accepted operational serializable range-validation candidate

- Parent: operational serializable point-validation commit `ba12783`.
- Scope and API: add public `Observe_Range` as a low-level predicate operation, not a row-returning scan. Explicit
  endpoint flags represent one canonical half-open interval; false means unbounded and makes the corresponding bytes
  irrelevant. Two present endpoints require strict bytewise `Lower < Upper`. Snapshot validates without retention;
  Serializable retains exact distinct predicates. Empty/reversed intervals use existing `Invalid_State`, while
  family-bound, allocation, and persisted-count exhaustion use existing `Capacity_Exceeded`. No default endpoint,
  result count, result byte ceiling, persisted field, format value, or compatibility overload is introduced.
- Allocation and ownership: each distinct Serializable range is one lazily allocated transaction-owned node. Only
  present endpoints are copied, each under the selected family's persisted `Max_Key_Bytes`; the independent persisted
  range count is the only node-count authority. Node and endpoint copies complete before linkage. Count exhaustion or
  failure at the node, lower, or upper allocation point frees the unlinked candidate and leaves the set unchanged.
  Exact duplicates consume no slot, ignored endpoint bytes are never copied, and arena rollback, consumption, or
  finalization releases the complete list without retaining caller bytes.
- Conflict and concurrency: bytewise history comparison implements `Lower <= Key < Upper`, including prefix, open,
  and whole-family forms. Admission and prepublication validation check every post-Begin committed Put or Delete
  against writes, points, and ranges. Group members retain independent external-history validation and deterministic
  internal ordering. The coordinator owns each admitted arena, so no range list can race caller mutation. No helper
  task, completion slot, storage request, retry, or publication-certainty path is added. Missing retained batch images
  now fail conflict validation closed instead of silently bypassing every key predicate.
- Constants audit: 643 added Ada lines produced 95 raw textual inventory matches and 19 constant declarations. Four
  comparator locals and two absolute queue deadlines are mechanically derived. Ten identity/key declarations are
  fixed deterministic witness geometry, one oversized endpoint is derived as exactly one byte beyond the existing
  family authority, and the remaining two declarations are the documented persisted two-range test ceiling and
  two-second queue-barrier budget. Inline two-member group geometry, three test-only allocation-fault states, and the
  established 8 MiB task stack carry adjacent authority comments. Routine indexing, increments, neutral vacant
  initialization, and scenario bytes were excluded from policy findings. No production bound, timeout, format tag,
  retry count, capacity, or default was invented; no constants decision remains unresolved.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository/provenance checks, deterministic
  format/policy/model and memory/files engine tests, authenticated create/commit/Flush/reopen, filesystem subprocess
  crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and every adapter fixture against clean Object Storage
  `e8362f72e5edf4cc8eb16e31d1fdbfba74db384b`. New memory/files witnesses cover snapshot non-retention, invalid and
  prefix ordering, ignored absent endpoints, family bounds, exact duplicate/exact/one-over capacity, independent
  point capacity, node/lower/upper allocation rollback, inclusive/exclusive/disjoint/open/whole/family-separated
  intervals, Put and Delete conflicts, group rejection, and a writer-first queued prepublication race.
  `./scripts/check-tla.sh` preserves every lane and passes the serializable 44,244-state/10-obligation gate.
  Warning-strict FSF GNATprove 16.1.0 proves 1,084/1,084 selected-unit checks (164 flow, 920 prover; maximum 6,890
  steps), with zero warnings, unproved/justified checks, or `pragma Assume`. Public leading-style GNATdoc HTML renders
  `Observe_Range` and all eight parameter descriptions without a warning on the new entity; repository/dependency
  documentation warnings remain outside this unit.
- Findings cycle: the first API/ownership/concurrency sweep retained the low-level observation primitive rather than
  inventing a bounded result-stream policy and required full construction before linkage. The executable sweep fixed
  four P2 coverage/documentation findings: differing ignored endpoint bytes, independent point/range capacity,
  committed tombstone intersection, and explicit public endpoint-borrow lifetime. The repeated API, ownership,
  concurrency, bounds, constants, format, certainty, test, documentation, and proof review finds no remaining P0,
  P1, P2, or P3 issue.

## Accepted operational serializable point-validation candidate

- Parent: manifest-v3 serializable-limit commit `e6043cf`.
- Scope and compatibility: add public runtime-only `Isolation_Level` and an explicit-isolation
  `Begin_Transaction` overload. The existing overload is a literal Snapshot call, so existing source and behavior
  remain unchanged and no public default is introduced. Serializable Begin rejects manifest-v1/v2 authority as
  `Unsupported_Format`; it never supplies a fallback count or migrates persisted state. External successful and
  absent `Get` calls retain exact family/key predicates; duplicates deduplicate and own Put/Delete reads bypass
  observation capacity, matching the accepted formal algorithm. Normalized scan/range tracking remains a separate
  unit.
- Allocation and ownership: each new distinct point is one lazily allocated transaction-owned node whose key length
  is already bounded by the selected family's persisted `Max_Key_Bytes`. The database's persisted point count is the
  only node-count authority; there is no chunk size, global key ceiling, or eager full-capacity allocation. A node
  and its exact key are completely constructed before linkage. Count exhaustion, node allocation failure, or key
  allocation failure returns `Capacity_Exceeded`, leaves the set unchanged, clears returned data, and keeps the
  transaction active. Arena rollback, failed pre-admission commit, terminal consumption, and finalization release the
  complete list without retaining caller bytes.
- Conflict and concurrency: admission and prepublication validation scan every post-Begin committed mutation against
  both the write set and retained point set. Group members validate independently against external history and retain
  existing deterministic intra-group ordering. The coordinator owns the arena after admission, so protected scans
  cannot race caller mutation; no helper task, new completion slot, persisted byte, storage request, or publication
  certainty rule is added.
- Constants audit: 518 added Ada lines produced 167 raw literal/default matches and 21 constant declarations. Three
  declarations are a copied result and absolute deadlines derived from the documented queue duration. The remaining
  18 declarations are the persisted two-point test limit, isolated test identities/keys, and the queue duration;
  adjacent comments classify their corpus purpose and authority. Routine loops, one-based indexing, increments, and
  vacant zero/null state were excluded from findings. The inline two-member atomic group and runner-qualified 8 MiB
  task stack are documented test geometry. No production capacity, byte ceiling, timeout, retry, format tag, or
  default was introduced, and no constant-policy decision remains unresolved.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository/provenance checks, deterministic
  format/policy/model and memory/files engine tests, authenticated client-backed create/commit/Flush/reopen,
  filesystem subprocess crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and every adapter fixture against
  clean Object Storage `e8362f72e5edf4cc8eb16e31d1fdbfba74db384b`. New memory/files witnesses cover
  snapshot compatibility, present and absent conflicts, disjoint success, duplicate/exact/one-over capacity,
  own-write bypass, node/key allocation rollback, group rejection, and a writer-first queued prepublication race.
  `./scripts/check-tla.sh` preserves all lanes and passes the serializable 44,244-state/10-obligation gate.
  Warning-strict FSF GNATprove 16.1.0 proves 1,084/1,084 selected-unit checks (164 flow, 920 prover; maximum 6,890
  steps), with zero warnings, unproved/justified checks, or `pragma Assume` in analyzed units. Public leading-style
  GNATdoc HTML renders the new enum literals, overload contract, exact parameter descriptions, and updated `Get`
  behavior; a warning run reports no undocumented element on those new/modified entities. Existing repository and
  dependency documentation warnings remain outside this unit.
- Findings cycle: the first sweep rejected eager full-ceiling descriptor allocation in favor of one exact node per
  observed point, required value-copy failure to occur before point publication, and kept group-internal ordering
  outside external-history validation. The executable-test sweep found missing setup-result assertions and tightened
  every Begin/Get/Put oracle. The formatting sweep removed project-wide mechanical churn and corrected one token
  spacing failure exposed by the authoritative runner. Follow-up API, ownership, concurrency, bounds, constants,
  format, certainty, test, and proof review finds no remaining P0, P1, P2, or P3 issue.

## Accepted manifest-v3 serializable-limit candidate

- Parent: formal serializable-validation commit `06741c7`.
- Scope: persist caller-selected independent point-read and scan-range counts in current manifest version 3, retain
  the exact manifest-v2 bytes as a backward-read contract, and carry the authenticated limits through Create, Open,
  create reconciliation, first-checkpoint planning, and live engine authority. This unit does not add a public
  isolation or scan API, allocate transaction observations, implement range normalization, or claim that runtime
  serializable validation has landed.
- Compatibility and authority: v3 extends the authenticated header from 220 to 228 bytes with U32 fields at offsets
  220 and 224. Both are required nonzero for new Create and have no library default. Point keys and scan endpoints
  continue to use the selected column family's persisted maximum key length; the database fields bound counts only.
  Operational decode retains exact v2 objects with zero/zero as an explicit absence of serializable authority.
  Snapshot operation remains readable; serializable Begin and Flush must reject v2 as unsupported rather than invent
  limits or perform an implicit migration. All consequential wire values and fixture capacities retain adjacent
  source authority comments.
- Verification: the independent generator exactly reproduces the retained 358-byte v2 golden, current 366-byte v3
  golden, and 164-byte SST golden. `./tests/scripts/test.sh` passes repository/provenance checks, deterministic
  format/policy/model and memory/files engine tests, authenticated client-backed create/commit/Flush/reopen,
  filesystem crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and all adapter fixtures against clean Object
  Storage `e8362f72e5edf4cc8eb16e31d1fdbfba74db384b`. The warning-strict FSF GNATprove 16.1.0 gate proves
  1,084/1,084 selected-unit checks (164 flow, 920 prover; maximum 6,890 steps) with zero warnings,
  unproved/justified checks, or `pragma Assume`.
- Findings cycle: the first sweep rejected arbitrary intermediate header probe lengths and found that v2 Flush could
  fall through to a v3 encoder without persisted point/range authority. The amendment admits only exact versioned
  headers plus the deliberate current-width v2 recovery probe, adds exact/intermediate header tests, and returns
  `Unsupported_Format` before v2 checkpoint planning. A constants audit distinguished persisted wire fields and
  caller-selected limits from derived widths, neutral legacy zeroes, and documented fixture geometry. Follow-up
  review finds no remaining P0, P1, P2, or P3 issue.

## Accepted formal serializable-validation candidate

- Parent: operational fixed-snapshot point-read commit `7460bdb`.
- Scope: freeze serializable point/range conflict and capacity semantics before selecting a public Ada isolation or
  scan contract. Snapshot mode retains no observations and continues to reject only post-Begin writes to its write
  set. Serializable mode retains successful/absent point reads and normalized range predicates, rejecting a commit
  when a later committed write intersects the write set, a retained point, or a retained range. Independent capacity
  rejection prevents silently omitted observations. This unit adds no Ada runtime behavior, public outcome, persisted
  field, range encoding, allocation policy, or refinement claim. Conservative rejection below the checkpoint-history
  boundary remains owned by the separate snapshot-isolation lane.
- Constant authority: two transactions, two keys, two modeled ranges, and one point/range slot are finite
  qualification geometry. One slot both admits one observation and forces a second distinct observation through the
  capacity branch. `R1` contains one key and `R2` both keys only to witness point versus phantom conflict. These values
  do not authorize product defaults or persisted ceilings; eventual capacities remain caller- or persisted-limit
  decisions.
- Verification: the authoritative combined `./scripts/check-tla.sh` gate preserves every earlier lane and exhausts
  44,244 new states at depth 13 with nonzero coverage for every serializable semantic action. Four independent trace
  checks validate point conflict, range conflict, snapshot non-retention, and read-your-writes at full point capacity;
  the unsafe-commit probe is rejected.
  Strict TLAPS proves 10/10 action-preservation obligations. Shell syntax, Python bytecode compilation,
  `./scripts/check-repository.sh`, and `git diff --check` pass.
- Findings cycle: the model sweep separated snapshot from serializable observation retention, added explicit
  point/range capacity outcomes, constrained the snapshot witness to a read-only transaction before a distinct
  writer, and added the deliberately unsafe commit probe. Follow-up review corrected own-write reads to bypass point
  retention and capacity, matching the existing reference algorithm, and added an exact regression witness. The proof
  sweep narrowed the TLAPS claim after recursive
  finite-set cardinality resisted the focused SMT proof: capacity invariants remain exhaustively checked by TLC and
  are not reported as unbounded proof. The final sweep finds no remaining P0, P1, P2, or P3 issue.

## Accepted operational fixed-snapshot point-read candidate

- Parent: accepted formal fixed-snapshot point-read commit `cff2048`.
- Scope: make public `Get` implement the frozen selection rule without changing its signature or persisted bytes.
  Buffered Put/Delete wins. Otherwise the protected coordinator selects the newest exact retained mutation whose
  committed sequence is no later than Begin, then falls back to exact checkpoint-base descriptors. Formal `TooOld`
  maps to existing public `Conflict`. The coordinator returns a borrowed immutable image slice; the lifecycle lease
  keeps it alive while copying occurs outside the protected operation.
- Allocation and authority: checkpoint-base descriptors are allocated lazily from the checked sum of authenticated
  SST entry counts and bounded by persisted `Maximum_Live_Entries`; no capacity-sized duplicate payload table, public
  default, format field, or new ceiling is introduced. The 48 numeric lines in the raw added-Ada inventory reduce to
  routine one-based indexing/arithmetic, neutral vacant values, persisted-limit comparisons, and deterministic test
  fixtures. The six-site recovery array derives from its six enumerated fault points; IDs 160..179 and 227..229,
  payload bytes 1..13, the A4 key, and the two same-width checkpoint values carry adjacent fixture authority comments.
  No unresolved constant-policy finding remains.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository/provenance checks, deterministic
  memory/files engine and format suites, authenticated client-backed create/commit/Flush/reopen, filesystem subprocess
  crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and all adapter fixtures against clean Object Storage
  `e8362f72e5edf4cc8eb16e31d1fdbfba74db384b`. New witnesses cover prior-value selection, absence before later insert,
  own Put/Delete, exact checkpoint-boundary lookup, too-old rejection, allocation failure before engine installation,
  and checkpoint-base preservation after a later suffix replacement. Warning-strict GNATprove preserves 1,078/1,078
  selected-unit checks (164 flow, 914 prover), with zero warnings, unproved/justified checks, or `pragma Assume`.
- Findings cycle: the first implementation sweep moved result allocation/copying out of the protected coordinator.
  Follow-up review added exact slice and descriptor-array bounds validation so malformed retained authority fails
  `Corrupt` instead of escaping through an indexing exception, and verified unwind ownership for every allocation
  boundary. The final sweep finds no remaining P0, P1, P2, or P3 issue. The formal `cff2048` witness/model evidence is
  unchanged; executable correspondence tests do not claim a refinement proof.

## Accepted formal fixed-snapshot point-read candidate

- Parent: operational snapshot write-validation commit `589f941`.
- Scope: freeze point-read selection before production changes. A transaction reads its buffered Put/Delete first;
  otherwise it selects the newest committed value no later than its fixed Begin sequence. A snapshot below the
  retained checkpoint boundary reports `TooOld` rather than substituting incomplete or latest authority. This unit
  adds no Ada runtime behavior, public outcome, allocation, persisted format, serializable predicate, group rule, or
  claim of refinement.
- Constant authority: two transactions, two values, and two committed-version slots are finite qualification geometry
  complete for the bounded scenario, not product retention, key/value, or transaction limits. Sequence one and the
  first model value seed one real committed prior version so the witness exercises old-value selection; zero is the
  no-checkpoint/absent-history sentinel. The pinned 7,530-state/depth-14 graph changes only after model-graph review.
- Verification: `./scripts/check-tla.sh` preserves the existing 112,031/286/819/336-state commit, manifest,
  checkpoint, and write-validation lanes and their 23/12/43/6 TLAPS obligations. The new lane exhausts 7,530 states
  at depth 14 with nonzero Begin, Put/Delete buffer, Commit, Read, and Checkpoint coverage; validates exact old-value,
  read-your-writes, and checkpoint-too-old traces; rejects the deliberately wrong latest-value read; and proves 7/7
  strict TLAPS obligations. `./scripts/check-repository.sh`, Python bytecode compilation, shell syntax, and
  `git diff --check` pass.
- Findings cycle: the first sweep replaced an absence-only trace with a real prior-value witness. The proof sweep
  changed the bad-read flag from a type-only monitor to an explicit selected-versus-expected comparison and made the
  initial value-membership authority an explicit theorem premise after TLAPS rejected the implicit assumption. The
  integration sweep fixed the instrumented `RecordRead` coverage label and an incompletely specified negative action;
  the complete gate then passed. Final review finds no remaining P0, P1, P2, or P3 issue in this formal-only boundary.

## Accepted operational snapshot write-validation candidate

- Parent: accepted formal snapshot write-validation commit `b32ce26`.
- Scope: capture the authenticated global sequence at Begin, retain exact decoded post-checkpoint batch descriptors
  with their already-owned immutable images, and reject a singleton or atomic group when any written family/key was
  committed later. Admission validation leaves rejected transactions active; the second check immediately before
  publication consumes already-admitted conflicts. Transactions older than the authenticated checkpoint replay
  boundary reject conservatively. Groups validate against external history and preserve their established atomic
  deterministic ordering for overlaps within the group. This unit changes no persisted bytes, provider operation,
  public signature, retry/certainty mapping, fixed-snapshot read behavior, or serializable predicate policy.
- Constant-authority audit funnel: a raw added-Ada-line scan found 56 lines containing numeric tokens. Loop/index
  arithmetic, neutral resets, family-one use, and byte payloads were classified separately from consequential values.
  The Begin/root zero sentinel, persisted replay-boundary derivation, two-member group fixture, IDs/key bytes, two-task
  queue depth, 8 MiB native test stack, and two-second test barrier carry adjacent source authority and compatibility
  comments. No new product default, key/value ceiling, queue capacity, timeout, or persisted-format value remains.
- Verification: `./tests/scripts/test.sh` passes the root/test/server builds, repository/provenance checks,
  deterministic memory/files engine and format suites, authenticated client-backed create/commit/Flush/reopen,
  filesystem subprocess group/manifest/Flush crash recovery, 32 comparative cases, pinned TidesDB 4/4, and all
  adapter fixtures against clean Object Storage `e8362f72e5edf4cc8eb16e31d1fdbfba74db384b`. The new tests cover exact Put,
  tombstone, empty-key, disjoint, external group, checkpoint-stale, pre-admission ownership, and two genuinely queued
  Ada-task commits with exactly one success and one admitted conflict. Warning-strict FSF GNATprove 16.1.0 preserves
  the selected deterministic boundary at 1,078/1,078 checks (164 flow, 914 prover), with zero warnings, unproved or
  justified checks, or `pragma Assume`. `./scripts/check-tla.sh` preserves the existing 112,031/286/819-state and
  23/12/43-obligation lanes and passes the snapshot lane at 336 states/depth 10 and 6/6 obligations, including all
  checked witnesses and the negative unsafe-commit probe.
- Findings cycle: the first sweep corrected an incompatible proposal to reject overlapping writes inside an explicit
  atomic group; existing executable semantics intentionally order those members within one co-commit. Follow-up
  review added the prepublication check needed for two independently admitted same-snapshot calls, retained tombstones
  as exact conflict authority, exercised the checkpoint history boundary, and made the model's group exclusion and
  the runtime's latest-value `Get` limitation explicit. The authority sweep then closed adjacent comments for the
  replay-boundary sentinel and concurrency geometry. The final sweep finds no remaining P0, P1, P2, or P3 issue.

## Accepted formal snapshot write-validation candidate

- Parent: caller-composable first-checkpoint commit `ce462a8`.
- Scope: freeze the first snapshot-isolation write/write rule before production implementation. A transaction captures
  the global sequence at Begin, validates every written key against later exact write authority, and rejects
  conservatively when its snapshot predates the retained checkpoint-history boundary. This unit adds no Ada runtime
  behavior, read-version retention, serializable predicate tracking, grouped-commit rule, persisted format, or public
  API.
- Constant authority: the two-transaction/two-key TLC dimensions are finite qualification geometry, not product
  limits. The pinned 336-state/depth-10 graph is a reviewed gate against accidental model narrowing; it can change
  only with a fresh graph review. Sequence zero is the model's canonical initial authority, not a persisted default.
- Verification: `./scripts/check-tla.sh` preserves the existing 112,031/286/819-state commit, manifest, and checkpoint
  lanes and their 23/12/43 TLAPS obligations. The new lane exhausts 336 states at depth 10 with nonzero coverage for
  every normal action, validates exact same-key conflict, disjoint-success, and checkpoint-stale traces, rejects the
  deliberately unsafe commit probe, and proves 6/6 strict TLAPS obligations. `./scripts/check-repository.sh`, Python
  bytecode compilation for the validator, and `git diff --check` pass.
- Findings cycle: the initial sweep strengthened type safety with snapshot/last-write sequence bounds and added the
  disjoint-success witness so the conservative checkpoint rule cannot be mistaken for global serialization. The
  follow-up sweep confirms the model states its exclusions, the validator checks semantic authority rather than
  accepting any invariant trace, and no P0, P1, P2, or P3 finding remains in this formal-only boundary.

## Accepted authenticated synchronous client binding candidate

- Parent: Object Storage provenance update `1a6f98c`.
- Scope: bind one storage context to caller-owned HTTP and signing state, copy all wire-policy selections explicitly,
  and route conditional immutable Put plus bounded whole/range Get through the buffer-owned Object Storage wrappers.
  Those wrappers are literal waits over the provider-owned `Client.Objects` operations, so the engine gains
  authenticated I/O without a helper task,
  retry path, or second certainty implementation. Reads preserve opaque ETag generations; an initially unbound range
  performs HeadObject and then uses that exact generation. This unit adds no DB-level composable operation and makes
  no remote-provider qualification claim.
- Constant authority: request/response buffer capacities are one-token operation geometry, while their block sizes
  derive lazily from an encoded immutable image or an authenticated/persisted read bound. Region, addressing, content
  type, owner, requester-pays, and checksum choices are required caller inputs. The empty provider version selector is
  derived from the DB's ETag-only persisted generation model. Loopback credentials, ports, timeouts, readiness budget,
  family limits, and object namespace in the black-box gate are documented fixtures, not product defaults.
- Verification: `./tests/scripts/test.sh` passes root/test/server builds, repository/provenance checks, deterministic
  engine and format suites, authenticated memory-server bucket/create/commit/close/cacheless-reopen byte recovery,
  filesystem subprocess crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and all adapter fixtures against
  Object Storage `cad6f37d8e3370b13e4462720858c7ac7ec7e311` with its HTTP/QUIC PR #33 pin
  `98c0e26f7665df4fecc299abd96ca5827590f0f8`. The unchanged TLA+/TLC/TLAPS gate remains green at
  112,031/286/819 commit/manifest/checkpoint states and 23/12/43 obligations, all witnesses, and all negative probes.
  Warning-strict forced FSF GNATprove 16.1.0 proves the unchanged six-unit deterministic boundary at 1,078/1,078
  checks (164 flow, 914 prover), zero warnings, unproved/justified checks, or `pragma Assume`, maximum 6,840 steps.
- Findings cycle: the first sweep moved publication-attempt accounting after client-side allocation and hashing,
  made command-line validation precede probe argument access, and documented the ETag/current-version authority. The
  proof sweep repaired the typed HTTP/Object Storage compilation closure with a proof-only project and generation-only
  Alire setup while retaining the exact selected DB units. The final ownership/certainty/bounds/documentation sweep
  finds no remaining P0, P1, P2, or P3 issue in this binding boundary.

## Accepted cacheless first-checkpoint recovery candidate

- Parent: caller-owned checkpoint identity commit `53e8405`.
- Scope: header-first, generation-bound recovery of one complete nonempty manifest-v2 checkpoint; exact dynamically
  allocated SST decode under persisted database/family authority; installation of live values, last-write sequences,
  and the checkpoint identity ledger; and replay of only the strictly later batch suffix. A private synchronous
  success-path publisher creates deterministic fixtures and fences its stale local engine. This unit adds no public
  Flush, publication receipt, ambiguous-write reconciliation, multiple-checkpoint support, or composable overload.
- Constant authority: manifest/SST header ranges are the frozen 220-byte/96-byte format widths; whole-object and
  engine allocations derive from authenticated object lengths and persisted limits. The run namespace is a frozen
  object-key compatibility choice. Negative-fixture identity domains and mutation offsets are documented adjacent to
  their declarations and do not become database defaults. No global key/value ceiling is introduced.
- Verification: `./tests/scripts/test.sh` passes root/test builds, repository/provenance checks, deterministic Ada,
  filesystem subprocess crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and all adapter fixtures against
  Object Storage `386865021321bf95b133efbaab4d8e77086cac0b`. Memory and files backends recover exact checkpoint state,
  identity nonreuse, and a later suffix; missing, checksum-corrupt, and checksum-valid wrong-family runs fail closed.
  Five injected recovery allocation sites return `Capacity_Exceeded` without partial engine installation. The TLA+
  gate remains green at 112,031/286/819 commit/manifest/checkpoint states and 23/12/43 TLAPS obligations, including
  committed/rejected/recovery witnesses and all negative checkpoint probes. Warning-strict forced FSF GNATprove
  16.1.0 proves the selected deterministic boundary at 1,078/1,078 checks (164 flow, 914 prover), zero warnings,
  unproved/justified checks, or `pragma Assume`, maximum 6,840 steps; operational recovery I/O and tasking remain the
  stated executable-test boundary.
- Findings cycle: the first sweep fixed exact-range validation for backend reads and prevented an exact attempted
  HEAD with a missing named receipt batch from reactivating empty state. The second sweep added deterministic
  allocation-failure coverage and separate run-publication accounting, then re-ran executable, TLA+/TLAPS, and SPARK
  gates. The final implementation sweep found and fixed one P1 planner defect: a database whose persisted manifest
  history admits only the root could otherwise publish an unreopenable first-checkpoint successor. Admission now
  rejects that plan before any run, manifest, or HEAD publication, with a zero-publication regression. The final
  follow-up sweep finds no remaining P0, P1, P2, or P3 issue in this recovery boundary.

## Accepted caller-owned checkpoint identity candidate

- Parent: exact whole-checkpoint plan commit `f5c0355`.
- Scope: a public immutable family/run mapping value and planner admission that requires exact coverage of the
  persisted family registry, joins mappings by family ID, rejects missing/unknown/duplicate families, rejects zero or
  duplicate run IDs and collisions with the manifest/transition IDs, and copies only nonempty-family IDs into owned
  SSTs. This unit still performs no object I/O, HEAD transition, public Flush, recovery change, or composable work.
- Constant authority: the library invents no identity, count, default, or allocation ceiling. Every run, manifest,
  and transition ID is caller-owned; authenticated registry size and family IDs determine exact map admission. The
  two run IDs and successor IDs in the regression are stable operation fixtures with no persisted-format authority.
- Verification: `./tests/scripts/test.sh` passes root/test builds, repository/provenance checks, deterministic Ada,
  filesystem crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and all adapter fixtures against Object
  Storage `386865021321bf95b133efbaab4d8e77086cac0b`. The focused corpus accepts a permuted exact map, builds both
  nonempty-family runs, and rejects zero, incomplete, duplicate-family, duplicate-run, unknown-family, and
  manifest-colliding inputs without changing batch/manifest/HEAD publication counts. Selected SPARK units and
  TLA+/TLAPS models are unchanged.
- Findings cycle: the sweep confirms the public constructor cannot manufacture zero identity state, planner
  validation occurs before exact checkpoint allocations, caller storage is never retained, and canonical output is
  independent of input order. Follow-up review finds no remaining P0, P1, P2, or P3 issue in this identity boundary.

## Accepted exact whole-checkpoint plan candidate

- Parent: exact first-SST snapshot commit `3d16863`.
- Scope: assemble one exact immutable SST for every nonempty canonical family and one exact successor manifest under
  the exclusive checkpoint lifecycle. The plan captures the expected opaque provider generation and transition,
  advances the persisted successor fields once, records the committed replay boundary, copies and canonically sorts
  the exact never-reused identity authority, and revalidates the operational manifest. It performs no object write,
  HEAD transition, public Flush, recovery change, or composable operation.
- Constant authority: all allocation extents and backpressure limits come from authenticated database/family LSM
  policy and measured quiescent state. The three structural-ID domains are explicitly test/reference fixtures and
  cannot become public run/manifest/transition authority; the later public operation must receive stable caller-owned
  IDs. The registry increment is existing persisted predecessor policy, not a new configurable limit.
- Verification: the focused deterministic engine suite builds two family runs, retains the exact singleton identity
  ledger and committed replay boundary, encodes the complete manifest, and proves injected manifest-allocation
  failure is `Capacity_Exceeded` with unchanged batch/manifest/HEAD publication counts. The authoritative full suite
  is the acceptance gate for the exact commit; selected SPARK units and TLA+/TLAPS models are unchanged.
- Findings cycle: review found and fixed one P1 omission where a complete plan failed to retain the exact provider
  generation required by its future conditional HEAD call. Follow-up review finds no remaining P0, P1, P2, or P3
  issue in this unpublished planning boundary.

## Accepted exact first-SST snapshot candidate

- Parent: live-entry sequence retention commit `772d969`.
- Scope: an exclusive checkpoint lifecycle and reusable first-run builder that measures actual family state, checks
  persisted memtable/run authority, allocates exact transient references and SST storage, sorts arbitrary byte keys,
  rejects duplicate live keys, retains exact write sequences, and passes the complete result through the operational
  SST encoder. This unit performs no object write, manifest transition, public Flush, or recovery change.
- Constant authority: the builder introduces no key/value, entry, payload, run, timeout, or task default. Allocation
  extents come from the quiescent live snapshot and are admitted by persisted family/database limits. Zero fields are
  documented transient sentinels; the three-entry/48-byte test family derives its memtable extent from its explicit
  key/value/count corpus, and the run identity is an operation fixture.
- Verification: `./tests/scripts/test.sh` passes after regenerating ignored Alire state for the released HTTP graph:
  root/test builds, repository/provenance checks, deterministic engine/format suites, filesystem subprocess recovery,
  32 comparative cases, pinned TidesDB 4/4, and every adapter fixture against Object Storage
  `00ac6b925ea884fb94853a0e315556b9d94c1bd1`. The test builds a canonical encoded SST from deliberately unsorted keys
  and proves both allocation faults return `Capacity_Exceeded` without changing batch/manifest/HEAD publication counts.
- Findings cycle: review fixed one P1 unwinding defect by separating cancellable checkpoint admission from
  success-only completion, and one P2 integrity gap by rejecting duplicate live keys before SST construction.
  Follow-up review finds no remaining P0, P1, P2, or P3 issue in this unpublished snapshot boundary.

## Accepted live-entry sequence retention candidate

- Parent: live LSM-authority retention commit `2270798`.
- Scope: retain each installed key's exact authenticated last-write transaction sequence through projection,
  replacement, and cacheless batch replay. The sequence is internal state for the later SST snapshot; this unit adds
  no Flush API, object publication, allocation ceiling, persisted format, or public default.
- Verification: the focused engine case checks the first committed sequence, a same-key replacement advancing to
  the next receipt sequence, and cacheless recovery preserving both the replacement bytes and exact sequence. The
  authoritative repository suite is the acceptance gate; the unchanged TLA+/TLAPS models and selected SPARK units
  are not rerun for this internal projection correction.
- Findings cycle: the initial sweep requires malformed mutation-to-transaction mappings to fail before projection
  and keeps zero solely as a vacant/test-output sentinel. Follow-up review finds no remaining P0, P1, P2, or P3
  issue in this retention boundary.

## Accepted live LSM-authority retention candidate

- Parent: operational manifest-v2 root commit `5e9ed61`.
- Scope: retain the authenticated manifest-v2 database/family LSM policy across direct Create activation,
  cacheless Open, create reconciliation, and ambiguous-commit resolution. The fixed family table mirrors the frozen
  base registry only; it stores no key/value/run/identity data and adds no runtime allocation default. Nonempty
  checkpoints and Flush I/O remain unsupported in this unit.
- Verification: the focused engine suite exercises direct and cacheless activation of the exact persisted policy,
  legacy no-LSM state, and a competing root whose base projection is identical but memtable policy differs. The
  latter must be `Already_Exists`, never accepted as the same database. The authoritative repository suite remains
  the acceptance gate for the exact commit.
- Findings cycle: review found and fixed one P1 reconciliation defect where equality of manifest-v1 base projections
  could hide different LSM policy. Follow-up review binds reconciliation to database and per-family policy while
  deliberately excluding replay/run successor state. The final sweep finds no remaining P0, P1, P2, or P3 issue in
  this retention boundary.

## Accepted operational manifest-v2 root candidate

- Parent: accepted operational first-LSM codec commit `6bc7abe`.
- Scope: public create-time database run/identity and per-family memtable/L0 limits, exact empty manifest-v2 root
  construction, prepublication allocation classification, v2 root recovery, and legacy manifest-v1 log-only
  readability. Create canonicalizes family IDs before pairing their LSM extensions. This unit publishes no SST,
  nonzero replay boundary, run descriptor, checkpoint identity, implicit migration, remote provider, or composable
  operation.
- Constant authority: the public API has no LSM defaults. Every database/family value is caller-selected and
  persisted; zero remains only an invalid construction sentinel. The empty-root transport extent is derived from
  frozen format widths and compile-time checked against the existing small-metadata boundary. Test run/identity
  capacities cite their family counts and history-reservation formulas adjacent to the fixtures.
- Verification: `./tests/scripts/test.sh` passes the root/test builds, repository/provenance checks, deterministic
  Ada engine/format suites, filesystem subprocess crash/recovery, 32 comparative cases, pinned TidesDB 4/4, and all
  adapter fixtures against Object Storage `00ac6b925ea884fb94853a0e315556b9d94c1bd1`. `./scripts/check-tla.sh`
  remains green at 112,031/286/819 commit/manifest/checkpoint states and 23/12/43 TLAPS obligations, including all
  generated witnesses and negative probes. A fresh forced warning-strict FSF GNATprove 16.1.0 run proves the
  unchanged selected deterministic boundary at 1,078/1,078 checks (164 flow and 914 prover), with zero warnings,
  unproved or justified checks, or `pragma Assume`.
- Findings cycle: the first sweep fixed P2 failures to distinguish checkpoint allocation/length exhaustion from
  invalid state and to prevent test-only v2-to-v1 fixture projection from implying migration. Follow-up review added
  a compile-time root-extent compatibility assertion, re-raised unexpected decoder faults instead of misclassifying
  them as corrupt input, and injected every new prepublication allocation site to prove typed `Capacity_Exceeded`,
  an empty receipt, and zero object publication. The final sweep finds no remaining P0, P1, P2, or P3 issue in this
  empty-root boundary.

## Accepted operational first-LSM codec candidate

- Parent: APM v0.3 agent-resource refresh `97061ea`.
- Scope: a private byte-identical operational manifest-v2/SST-v1 codec with header-first admission, checked extent
  arithmetic, exact dynamically sized family/run/identity/entry/payload objects, explicit ownership release, and
  null-output failure. Persisted database and per-family limits remain the only allocation and backpressure policy;
  this unit does not activate checkpoint publication, recovery, compaction, remote providers, or public API.
- Constant authority: the audit funnel reviewed every changed declaration and literal. Frozen wire values cite the
  persisted format, computed extents cite their field-width formulas, host representation checks identify their
  compatibility effect, and regression dimensions are labeled fixtures. Neutral initialization and loop arithmetic
  add no policy. No unresolved default, timeout, capacity, or key/value ceiling remains.
- Verification: `./tests/scripts/test.sh` passes the exact root/test builds, repository/provenance gate, deterministic
  Ada format/policy/model/local engine, files crash/recovery probes, 32 comparative cases, pinned TidesDB 4/4, and all
  adapter fixtures against Object Storage `00ac6b925ea884fb94853a0e315556b9d94c1bd1`. The selected SPARK tree was
  proved after sharing the run descriptor and wire constants: warning-strict FSF GNATprove 16.1.0 proves 1,078/1,078
  checks (164 flow and 914 prover), with zero warnings, unproved or justified checks, or `pragma Assume`; later
  amendments affect only the runtime codec, tests, comments, and documentation outside that proof boundary.
- Findings cycle: review fixed a P1 compact-payload indexing defect and a P1 unencodable allocation extent. P2 fixes
  make persisted self-contradictions malformed state rather than host-limit failures, validate replay/run and ledger
  ordering before allocation, exercise shifted array bounds, pin the exact dependency provenance, and close adjacent
  authority comments. Follow-up review finds no remaining P0, P1, P2, or P3 issue in this codec boundary.

## Accepted legacy constant-authority audit

- Parent: accepted first-LSM exact-format commit `1ae755268f47822ce1ae1b9ed658c7d17ecf29ce`.
- Scope: adjacent stable authority/classification and compatibility comments for consequential legacy Ada constants,
  record initializers, persisted offsets, derived sizes, runtime allocation dimensions, and qualification fixtures.
  Repeated batch-v1 tags and test deadlines are named without changing their values. The audit adds no public default,
  persisted ceiling, provider assumption, or allocation policy; authenticated database and per-family limits remain
  runtime authority, while small codec values remain explicitly reference/proof dimensions.
- Verification: `./tests/scripts/test.sh` passes the root build and repository/provenance checks, deterministic Ada
  formats/policy/model/local engine, files crash/recovery, 32 comparative cases, and pinned TidesDB 4/4 set. A forced
  warning-strict FSF GNATprove 16.1.0 run proves 1,078/1,078 checks (164 flow and 914 prover), with zero warnings,
  unproved or justified checks, or `pragma Assume`; maximum proof effort is 6,840 steps.
- Findings cycle: the sweep fixed one P1 formatter-induced source-encoding corruption and four P2 documentation
  defects: vacant mutation comments contradicted supported empty keys, a zero-duration task yield was mislabeled as an
  expired operation timeout, two corpus descriptions overstated their provenance, and a derived batch-frame extent
  lacked adjacent authority. Follow-up review finds no remaining P0, P1, P2, or P3 issue.

## Accepted first-LSM exact-format candidate

- Parent: constants-skill agent-resource refresh `59597cbadf17d8f43c03192bd1aeccddf644248e`.
- Scope: exact immutable checkpoint-manifest-v2 and SST-v1 bytes, private bounded SPARK reference codecs, independent
  golden generation, corruption/cap/lower-bound tests, and proof-project integration. It does not activate checkpoint
  publication, production dynamic decoding, recovery, compaction, remote providers, or composable I/O.
- Constant authority: every consequential new persisted, derived, proof, fixture, and test value has an adjacent
  stable source comment identifying its role, authority/classification, and compatibility effect. Generic capacities
  are explicitly reference/proof representation dimensions; persisted database and family limits remain the later
  operational allocation authority.
- Verification: `./tests/scripts/test.sh` passes repository checks, the deterministic Ada format/policy/model/local
  engine, files crash/recovery, 32 comparative cases, and the pinned TidesDB 4/4 set with no compiler warning. The
  final warning-strict FSF GNATprove 16.1.0 widening proves 1,078/1,078 checks (164 flow and 914 prover) with zero
  warnings, unproved or justified checks, or `pragma Assume`. The independent Python generator reproduces the frozen
  358-byte manifest and 164-byte SST images.
- Findings cycle: the first sweep found two P2 issues and one P3 issue. Unused family LSM slots could hold nonzero
  state that the encoder silently omitted, the TLA+ README still described the now-decodable reference formats as
  future, and one private decode status was unreachable. The amendment requires canonical zero family tails and
  tests the rejection, aligns the formal boundary wording, removes the dead status, and also exercises successful
  decoding from nonzero array lower bounds. Follow-up review finds no remaining P0, P1, P2, or P3 issue.

## Pending first-LSM checkpoint model/design candidate

- Parent: owned synchronous byte-spine candidate `c909c57227596a49e4d4dedd793fd615e15bd149`.
- Scope: a staged future manifest-v2/SST semantic decision, bounded two-family checkpoint-publication TLC model,
  committed/rejected/cacheless-recovery witness validation, four integrated unsafe-action probes, and a smaller
  unbounded TLAPS safety kernel.
- Boundary: this candidate changes no Ada production code or current supported persisted-format version. It freezes
  no binary offsets or golden bytes and does not implement memtables, SST reads, flush, compaction, scans, GC, remote
  providers, or composable I/O. The proof kernel is not a codec or implementation refinement proof.
- Verification status: the focused lane exhausts 819 TLC states at depth 19, validates three deterministic witnesses,
  pins nonzero coverage for every normal action, rejects four integrated unsafe-action probes, and proves all 43
  strict TLAPS obligations. The repository-shape gate also passes. Independent review remains pending; no acceptance
  claim is made.

## Accepted owned synchronous byte-spine candidate

- Parent: accepted operational HEAD-v2/root-family commit `6b9f29fd5a4f9df6395ed2f8bafb8e34effd9610`.
- Scope: borrowed public byte-array mutation input, owned unbounded Get output, dynamically sized transaction/state/
  identity/history descriptors, exact reference-counted immutable batch images, offset/view live state, and
  allocation-failure classification for the synchronous memory/files engine.
- Evidence: `tests/scripts/test.sh` covers deterministic memory/files 20/400 and 4 KiB/1 MiB CRUD/group/cacheless
  reopen, exact/one-over family/transaction/batch/live budgets, 257-mutation/live-entry dynamic tables, whole-image
  ownership accounting, injected allocation failures, subprocess crash/recovery, and pinned TidesDB conformance.
  The repository gate and unchanged TLA+/TLAPS gate pass. A root-owned warning-strict GNATprove run proves 643/643
  checks across the five selected format/policy/reference units with zero warnings, unproved/justified checks, or
  `pragma Assume`.
- Review of exact candidate `defa21e` rejected two P1 and two P2 findings: Resolve could wait behind queued callers'
  lifecycle leases, the runtime decoder could allocate from structurally impossible admitted counts, group mutation
  totals narrowed through U32 before a wider-`Natural` guard, and proof/milestone wording overstated the selected-unit
  boundary. The amendment drains queued slots before resolution quiescence, rejects impossible framing before image
  allocation, validates the group wire width before conversion, and narrows the documentation. Committed and rejected
  resolution campaigns include queued singleton/group work. Independent re-review accepted exact amended commit
  `c909c57227596a49e4d4dedd793fd615e15bd149` with no P0, P1, P2, or P3 findings; local `main` was fast-forwarded to
  that commit.

## Pending operational HEAD-v2 root-family candidate

- Parent: accepted manifest-v1 format/policy commit `a02a569a932230ed28c4559c17f9352d94410007`.
- Scope: explicit create-time database/family limits, canonical root-manifest publication, version-aware HEAD
  inspection, operational HEAD-v2 Create/Open/recovery, stable ID/name family handles, and manifest-aware commit and
  replay validation over the existing provider-neutral synchronous engine.
- Boundary: this candidate does not add dynamic family changes, owned large-value arenas, SST/LSM state,
  authenticated S3 binding, composable provider operations, or full Milestone 2 acceptance. HEAD v1 is inspection
  only and has no migration path in this unit.
- Verification status: `./tests/scripts/test.sh` passes the deterministic memory/files engine, repository checks,
  three files subprocess crash/restart boundaries, and the pinned TidesDB suite. Focused cases cover canonical family
  permutations, exact name/ID and stale/cross-database handles, lower persisted limits, manifest ambiguity and local
  activation failure, legacy HEAD rejection, missing/corrupt/wrong-identity/over-cap manifests, and cacheless
  manifest-first replay. The unchanged selected proof-unit tree carries the root-owned warning-strict 644/644 result
  recorded in `proof-status.md`; independent re-review is pending and no acceptance is claimed.
- Independent-review amendment: the first candidate classified every non-exact observed create HEAD as a competing
  creator, rejected valid exact-cap overwrites through conservative Put counts, and allowed delayed create resolution
  to trust retained manifest bytes without rereading the immutable object. The pending amendment validates the full
  manifest-first and batch chain and its exact root ancestor before accepting a later HEAD, collapses each batch to
  its final last-write-wins image before applying live entry/byte caps, and requires an authoritative whole-manifest
  byte match for every resumable create phase. Additional closures distinguish unsupported HEAD versions, freeze an
  independent HEAD-v2
  golden and repaired semantic corruption, gate the exact manifest-key prefix boundary, and remove unused manifest
  read diagnostics. Independent re-review remains required.

## Accepted additive manifest-v1 candidate

- Parent: accepted TidesDB comparative-adapter commit `a641f89157a64a48142f041db5b40c0dfcee3a07`.
- Scope: private manifest-v1 codec/policy, independent golden and corruption/cap tests, future HEAD-v2 publication
  predicates, and a focused TLC/TLAPS registry-publication model.
- Boundary: this candidate does not activate operational manifests, change public Create/Open, qualify a remote
  provider, allocate production transaction arenas, or claim full Milestone 2 acceptance.
- Accepted candidate: `a02a569a932230ed28c4559c17f9352d94410007`.
- Verification status: deterministic Ada and repository tests plus the combined TLC/TLAPS gate are green. The final
  amended, rebased five-unit warning-strict SPARK gate proves 639/639 checks: 114 flow checks and 525 prover checks,
  with zero warnings, unproved or justified checks, or `pragma Assume` statements. Independent re-review remains
  complete. Independent re-review accepted the exact candidate before fast-forward integration.
- Initial independent-review findings: an exact or immediate-successor recovery reference did not bind the HEAD
  predecessor identity; transaction count could exceed the total batch mutation count; fixed family-name tails were
  not canonicalized; and decoder precedence wording omitted the total representation-admission check. The amended
  candidate binds both recovery edges, enforces the count relation, rejects nonzero name tails, and aligns the spec,
  tests, and format document with the implementation's admission order.

## Accepted local-provider log-only slice

- Parent: accepted Slate/pooling contract commit `865f02e20be129c73b15e26d73570e6168ea16e5`.
- Accepted implementation candidate: `7387c66ab173d647494c282edf3fbbb0f55189d1`.
- Scope: provider-neutral memory/files adapter, bounded native group coordinator, log-only publication/recovery,
  provisional numeric-family CRUD, receipts, and deterministic storage faults.
- Acceptance boundary: this candidate does not claim authenticated remote-provider qualification, stable family
  creation authority, full Milestone 2 acceptance, MVCC isolation, or production durability/performance.
- Verification: on the final rebased source, `./scripts/check-repository.sh` validates canonical-state vectors,
  workloads, provenance, and repository shape; `./scripts/check-tla.sh` reports 112,031 TLC states at depth 14 and
  23/23 TLAPS obligations; and `./tests/scripts/test.sh` passes against memory/files, including a fresh-process files
  group crash/reopen probe. The warning-strict `./scripts/prove.sh` gate proves 421/421 checks: 84 flow and 337
  prover checks, with zero reported warnings, unproved or justified checks, or `pragma Assume` statements. The SPARK
  boundary is limited to selected deterministic packages documented in `proof-status.md`; storage I/O, lifecycle
  synchronization, and tasking are executable-test boundaries.
- Review status: accepted. The first implementation revision was rejected with P1 lifecycle, admission,
  reconciliation, deadline-isolation, identity, cap, and fault-evidence findings. Follow-up amendments reserve every
  admitted group/member identity, serialize shared storage-context fault controls and counters with a protected
  object, retain receipt identities on every admitted terminal path, and reject transaction-local reads and mutation
  buffering after a writer fence or uncertain publication. Expanded executable gates cover the 576-identity
  reservation boundary, a concurrent two-database shared-context case, and active read, buffered mutation,
  singleton/group admission, rollback, resolution, and recovery while a lost HEAD response leaves publication
  uncertain. Independent final re-review of the exact accepted candidate against the stated parent reports no
  P0, P1, P2, or P3 findings.

## Foundation root commit

- Parent: empty tree.
- Reviewer: independent read-only task `/root/foundation_review`.
- First reviewed revision: `c63cc5125c33c3ed256eaef100858d370f614e18`.
- First amended revision: `0ead79a74deb60d6400ab29262f81287814bb78c`.
- Final amended revision: `8b9ff8c338e4ffb346b0a18ff234646671dd2fd5`.
- Initial P1 findings: unreachable older batches, structurally unreachable HEAD images, and reconciliation dependent
  on unenforced transition-ID nonreuse.
- Initial P2/P3 findings: incomplete format corruption/golden coverage, overstated proof claims, permissive workload
  records, unassertive recovery workload, exposed internal children, own-write/read-capacity ordering, and unused
  AUnit.
- First follow-up P1 finding: an `Outcome_Unknown` commit remained replayable and receipt resolution was unrelated to
  the attempted transaction.
- First follow-up P2/P3 findings: equal transition/predecessor IDs remained structurally accepted, schema/validator
  drift was ungated, and planned tasking was described as implemented.
- Disposition: commit batches now require predecessor links; HEAD transitions carry monotonic ordinals and fail closed
  on unreachable shapes; reconciliation binds ID and ordinal; private units, exhaustive length/corruption tests, a
  fixed golden image, exact range deduplication, own-write ordering, operation-specific schema rules, schema-rule
  equivalence checks, receipt lifecycles, no-replay negative traces, and asserted recovery workloads were added.
  Proof documentation was narrowed, full range-union normalization was assigned to Milestone 3, and AUnit was removed.
- Verification: `./tests/scripts/test.sh`, `./scripts/prove.sh`, `./scripts/check-repository.sh`, and
  `git diff --check` pass. The current SPARK gate proves every reported check with no warning or unproved check.
- Follow-up status: accepted. The independent reviewer reported no P0, P1, P2, or P3 findings and reran every listed
  gate against the exact final revision with clean root and dependency worktrees.
