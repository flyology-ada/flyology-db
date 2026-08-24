# Review record

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
  Those wrappers are literal waits over `Client.Scoped`, so the engine gains authenticated I/O without a helper task,
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
