# SPARK proof status

The proof boundary is initially limited to deterministic format arithmetic, head transition validation,
publication reconciliation, and runtime safety of the bounded reference-model implementation.
Object I/O, protected-object serialization, tasking, filesystem behavior, HTTP, and provider atomicity are trusted
integration boundaries with executable tests.

Authoritative command:

```sh
./scripts/prove.sh
```

No selected unit may report an unproved check or warning. Proof commands use `--output-header`; proof totals are read
from retained tool output. No assumptions, false-positive suppressions, or imported ghost axioms are admitted.

The provider-centric Object Storage migration at source
`3455cde3158fd589480281beac39bea51305bb5e` reruns this maintained gate without changing the selected SPARK
algorithms or their proof boundary. The exact campaign proves 1,090/1,090 selected checks: 166 by flow analysis and
924 by provers, with zero warnings, unproved or justified checks, or `pragma Assume` statements. The dependency's
own 936/936 report is corroborating upstream evidence rather than a substitute for this DB campaign. Provider I/O,
tasking, and the public limited-profile executable remain trusted integration boundaries exercised by maintained
tests.

The final local-provider log-only candidate reports 421/421 checks: 84 flow checks and 337 prover checks, with zero
reported warnings, unproved or justified checks, or `pragma Assume` statements. This result applies only to the
selected deterministic packages below. The operational storage port, protected lifecycle/coordinator, native task,
filesystem behavior, and fault scheduling remain trusted integration boundaries covered by executable tests.
The proof project exposes the pinned Object Storage source directory only so GNATprove can resolve the
HTTP-independent backend interfaces named by `Flyology.DB`'s private representation. It intentionally does not
import or analyze the complete Object Storage client/server build, its HTTP closure, or its XmlAda dependencies.

Current selected packages:

- `Flyology.DB.Head_Policy`, covering initial-head validity, writer acquisition, commit sequence/identity transitions,
  monotonic transition ordinals, and conservative ambiguous-outcome reconciliation;
- `Flyology.DB.Formats`, covering explicit big-endian head encoding, bounds, CRC-32C calculation, and fail-closed
  structural decoding;
- `Flyology.DB.Batch_Formats`, covering runtime safety and definite initialization of the bounded encoder and
  structural/latest decoders, helper contracts for lengths and byte copies, decoder success/failure postconditions,
  and predecessor-policy arithmetic; and
- `Flyology.DB.Manifest_Formats`, an additive bounded manifest-v1 candidate covering runtime safety, definite
  initialization, length/UTF-8 arithmetic, decoder success/failure postconditions, and publication/predecessor
  predicate arithmetic;
- `Flyology.DB.LSM_Formats.Reference`, instantiated with deliberately small representation-only proof capacities,
  covering exact current checkpoint-manifest-v3 and SST-v1 length arithmetic, structural validation, fail-closed
  arbitrary-bound decoding, exact cursor and slice bounds, and definite initialization; and
- `Flyology.DB.Reference_Model`, covering absence of runtime checks and definite initialization in bounded MVCC state
  transitions. Executable tests, rather than current functional proof contracts, establish the model's fixed-snapshot,
  conflict, atomic-commit, and rollback examples. Its same-family scan predicates now normalize overlap, endpoint
  contact, transitive bridges, and open bounds before capacity. GNATprove establishes safety and termination of the
  bounded algorithm; functional union equivalence remains in the separate TLC/TLAPS lane rather than a refinement
  claim.

The proof does not establish provider atomicity, read freshness, transport behavior, durability barriers, or that a
concrete I/O adapter supplies bytes faithfully. Object Storage conformance and executable boundary tests gate those
trusted boundaries.

`Flyology.DB.Batch_Formats` is one private bounded reference/proof representation rather than a public generic. Its
helper contracts split header, transaction, and mutation encoding, and split bounded count, extent, and byte-copy
decoding, so GNATprove checks each bound without constructing one monolithic verification condition. The operational
runtime codec is a separate dynamically allocated v1 implementation governed by persisted resource limits. The
persisted 32-bit/64-bit wire widths remain independent of the reference-instance caps; widening either implementation
must repeat its applicable memory-budget, corruption-test, and proof or executable-boundary gates.

Executable golden-byte, corruption, boundary, HEAD-binding, and cacheless-recovery tests establish byte ordering,
CRC-32C behavior, semantic rejection classes, and concrete publication/predecessor predicate examples. The current
SPARK contracts do not claim functional equivalence between those byte-level behaviors and an independent codec.

Manifest golden-byte, every-truncation, repaired semantic corruption, cap, UTF-8, publication, and predecessor tests
likewise establish concrete byte/predicate behavior. The manifest proof boundary does not claim CRC correctness,
semantic completeness of the corruption corpus, provider publication, or operational HEAD-v2 refinement.

The first-LSM format candidate adds a warning-strict forced selected-unit run on 2026-08-23 using FSF GNATprove
16.1.0, `--mode=all --level=1 -j0 --output=oneline --output-header --report=all --warnings=error -f`. It proves
1,078/1,078 checks: 93 initialization checks, 522 run-time checks, 91 assertions, 300 functional contracts, and 72
termination checks; 164 are discharged by flow analysis and 914 by provers. It reports zero warnings, unproved or
justified checks, and zero `pragma Assume` statements. A focused bounded instance first proved 435/435 checks. These
results establish runtime safety and the stated contracts of the reference format implementation; they do not prove
CRC functional correctness, equivalence to the independent golden generator, operational dynamic allocation,
provider publication, recovery I/O, or refinement from the TLA+ model.

The operational empty-root candidate reran that exact forced warning-strict selected-unit gate after changing the
root package's public limits and Create/Open integration. The retained report again proves 1,078/1,078 checks: 164
by flow analysis and 914 by provers, with zero warnings, unproved or justified checks, and zero `pragma Assume`
statements; maximum successful proof effort is 6,840 steps. The root builder, dynamic operational codec allocation,
storage publication, recovery I/O, protected tasking, and fault injection remain executable-test boundaries rather
than SPARK-proved implementations.

The cacheless first-checkpoint recovery candidate reran the same authoritative forced selected-unit gate after its
root private declarations changed. FSF GNATprove 16.1.0 proves 1,078/1,078 checks: 93 initialization, 522 run-time,
91 assertion, 300 functional-contract, and 72 termination checks; 164 are discharged by flow and 914 by provers.
There are zero reported warnings, unproved or justified checks, or `pragma Assume`, and the maximum successful proof
effort is 6,840 steps. This preserves the established deterministic format/model proof boundary. Header/range I/O,
dynamic operational decode, protected installation, Ada tasking, and provider behavior remain trusted integration
boundaries covered by the memory/files recovery and corruption campaigns plus the checkpoint TLC/TLAPS model.

The final warning-strict forced five-unit gate on the amended, rebased candidate proves 639/639 checks: 65
initialization checks, 309 runtime checks, 54 assertions, 161 functional contracts, and 50 termination checks; 114
are discharged by flow analysis and 525 by provers. It reports zero warnings, unproved or justified checks, or
`pragma Assume` statements. Independent re-review remains required before acceptance.

The root-owned warning-strict forced five-unit gate for the operational HEAD-v2/root-family candidate proves 644/644
checks: 66 initialization checks, 310 runtime checks, 54 assertions, 160 functional contracts, and 54 termination
checks; 119 are discharged by flow analysis and 525 by provers. The FSF GNAT 16.1 invocation uses `mode=all`,
`--level=1`, `-j0`, `--warnings=error`, `-f`, and an output header. It reports zero warnings, unproved or justified
checks, or `pragma Assume` statements. The amendment after independent review changes no selected unit relative to
the exact proved `71329fe` tree, so that evidence carries forward without another prover run. Protected
lifecycle/tasking, storage I/O, create reconciliation, and manifest-aware runtime replay remain trusted
executable-test boundaries.

The owned synchronous runtime candidate changes `Manifest_Formats` mutation/live-count semantics and therefore does
not inherit the 644/644 selected-unit result above. A fresh root-owned forced run on 2026-08-23 used FSF GNATprove
16.1.0, `--mode=all --level=1 -j0 --output=oneline --output-header --report=all --warnings=error -f`, and the same five
selected units. It proved 643/643 checks: 66 initialization, 309 run-time checks, 54 assertions, 160 functional
contracts, and 54 termination checks; 119 were discharged by flow analysis and 524 by provers. There were zero
reported warnings, unproved or justified checks, and zero `pragma Assume` statements. Runtime codec behavior,
ownership/refcounting, dynamic allocation, the protected coordinator, tasking, and storage source/sink I/O remain
trusted executable-test boundaries. Independent re-review accepted exact commit `c909c572` with no P0-P3 findings;
that review does not expand the selected-unit proof boundary.

The operational snapshot write-validation candidate reruns that warning-strict selected-unit gate and preserves
1,078/1,078 checks: 164 discharged by flow analysis and 914 by provers, with zero warnings, unproved or justified
checks, or `pragma Assume`. The new exact history retention, protected admission/prepublication scans, ownership
transfer, and Ada-task race test live in the operational root body outside the selected SPARK units. Their assurance
comes from the deterministic memory/files tests and the separate snapshot TLC/TLAPS lane; this is not a refinement
proof between the model and implementation.

The operational fixed-snapshot point-read candidate reruns the same warning-strict gate and again proves
1,078/1,078 checks: 164 by flow analysis and 914 by provers, with zero warnings, unproved or justified checks, and
zero `pragma Assume`. The selected `Reference_Model.Get` remains proved at six checks. The production protected
history scan, borrowed-image lifetime, lazy checkpoint-base allocation, and recovery unwinding remain outside the
selected SPARK units and are qualified by executable memory/files, cacheless checkpoint, allocation-fault, and
authenticated-client tests. The separately accepted `cff2048` TLC/TLAPS model freezes the selection rule; no
refinement proof is claimed.

The manifest-v3 serializable-limit candidate reruns the authoritative warning-strict gate with the current
reference codec. FSF GNATprove 16.1.0 proves 1,084/1,084 checks: 93 initialization, 522 run-time, 91 assertion, 306
functional-contract, and 72 termination checks. Flow analysis discharges 164 and provers discharge 920; maximum
successful proof effort is 6,890 steps. Every selected unit reports zero warnings, unproved or justified checks, and
zero `pragma Assume` statements. The preliminary representation-information phase records that the root package spec
does not generate code and continues with partial representation data; this is not a selected-unit proof warning.
The dynamic v2/v3 operational decoder, header-first object I/O, runtime allocation, and protected engine state remain
executable-test boundaries rather than SPARK-proved code.

The operational serializable point-validation candidate preserves the same warning-strict result: 1,084/1,084
checks, comprising 93 initialization, 522 run-time, 91 assertion, 306 functional-contract, and 72 termination
checks. Flow analysis discharges 164 and provers discharge 920; maximum successful effort remains 6,890 steps.
Every selected unit reports zero warnings, unproved or justified checks, and zero `pragma Assume` statements. The
proved reference model continues to cover serializable point retention and conflict semantics. Production linked
point ownership, allocation rollback, and protected admission/prepublication scans remain outside the selected SPARK
units; deterministic memory/files fault, capacity, group, and queued-race tests plus the 44,244-state serializable
TLC and 10/10 TLAPS gate qualify those executable boundaries. No refinement proof is claimed.

The operational serializable range-validation candidate again preserves 1,084/1,084 warning-strict checks: 93
initialization, 522 run-time, 91 assertion, 306 functional-contract, and 72 termination checks; flow analysis
discharges 164 and provers discharge 920, with maximum successful effort 6,890 steps. Every selected unit reports
zero warnings, unproved or justified checks, and zero `pragma Assume`. The proved reference model covers the same
exact-deduplication, half-open interval, snapshot non-retention, independent-capacity, and phantom-conflict rule.
Production linked range ownership, allocation rollback, protected history comparison, and admission/prepublication
scans remain outside the selected SPARK units. Deterministic memory/files boundary, fault, tombstone, group, and
queued-race tests plus the 44,244-state TLC and 10/10 TLAPS campaign qualify those executable boundaries. This is not
a refinement proof between the reference model and production implementation.

The operational range-normalization candidate increases the warning-strict selected-unit result to 1,088/1,088:
94 initialization, 525 run-time, 91 assertion, 306 functional-contract, and 72 termination checks. Flow analysis
discharges 165 and provers discharge 923, with maximum successful effort 6,890 steps. Every selected unit reports
zero warnings, unproved or justified checks, and zero `pragma Assume`. The bounded reference model's normalization
loop, replacement indexing, and termination are proved; semantic exact-union preservation remains the independent
3,419-state TLC and 19/19 TLAPS boundary. Production linked-list closure, allocation, unlinking, deallocation, and
protected lifecycle ownership remain executable-test boundaries. Deterministic memory/files tests cover transitive
bridging, same-byte cross-family separation, merges at full persisted capacity, node/lower/upper allocation rollback,
open-bound expansion, and post-Begin conflict preservation. No refinement theorem is claimed.

The client-bound synchronous-Flush convergence candidate preserves that 1,088/1,088 selected-unit result on the
final implementation tree: 94 initialization, 525 run-time, 91 assertion, 306 functional-contract, and 72
termination checks; flow analysis discharges 165 and provers discharge 923, with maximum successful effort 6,890
steps. Every selected unit reports zero warnings, unproved or justified checks, and zero `pragma Assume`. The new
atomic lifecycle-lease promotion, temporary completion set and buffer pool, owner-driven wait, exception certainty
mapping, and nested Object Storage/HTTP operations remain outside the selected SPARK units. The authenticated client
probe qualifies those integration boundaries through definite pre-run failure, accepted-but-lost immutable-object
reconciliation, successful local activation, exact composable token reuse, replacement, and cacheless reopen. No
refinement theorem is claimed.

The bounded fixed-snapshot scan candidate preserves that same 1,084/1,084 warning-strict result and does not widen
the selected SPARK units. The proved reference model and serializable TLA+/TLAPS lane continue to establish the
fixed-snapshot lookup and half-open predicate rules. Production source discovery, immutable-image borrowing, owned
result construction, sorting, allocation rollback, and checkpoint/suffix merge remain executable-test boundaries.
Deterministic memory/files tests cover ordering, snapshot and own-write visibility, persisted row/byte limits, every
scan allocation position, predicate-retention atomicity, and checkpoint-plus-suffix recovery. No refinement proof is
claimed between the formal algorithm and production `Scan`.

The successive whole-state checkpoint candidate again preserves the warning-strict 1,084/1,084 result: 93
initialization, 522 run-time, 91 assertion, 306 functional-contract, and 72 termination checks; flow analysis
discharges 164 and provers discharge 920, with maximum successful effort 6,890 steps. Every selected unit reports
zero warnings, unproved or justified checks, and zero `pragma Assume`. Complete-live-state checkpoint planning,
persisted manifest-history admission, dynamic predecessor object I/O, checkpoint-chain validation, protected
installation, and task activation remain outside the selected SPARK units. Deterministic memory/files replacement,
backpressure, lost-response reconciliation, cacheless reopen, and missing-predecessor tests plus the separate
successive-checkpoint TLC/TLAPS lane qualify those executable boundaries. No refinement proof is claimed.

The operational additive-L0 candidate preserves the same warning-strict 1,084/1,084 result, with zero warnings,
unproved or justified checks, and zero `pragma Assume`. The production suffix planner, dynamic image ownership,
oldest-to-newest merge, and protected installation remain outside the selected SPARK units; deterministic memory/
files, capacity, certainty, tombstone, unchanged-old-run, cacheless-reopen, crash, and allocation-failure tests qualify
those boundaries. The additive 49-state TLC and 24/24 TLAPS campaign remains the abstract publication proof; no
refinement theorem to the operational Ada implementation is claimed.

The private composable L0-replacement candidate preserves the same warning-strict 1,084/1,084 selected-unit result.
The production mode selection, owner-stack driver, dynamic planning, provider calls, and exact token restoration
remain executable integration boundaries rather than SPARK-proved code. The authenticated client probe drives a
lost accepted run response through read-only same-identity reconciliation, verifies the exact replacement receipt
and moved-token restoration, and reopens from only the replacement manifest's current runs. The L0 compaction
35-state TLC campaign covers both one-output and canonical-empty replacement, with independently validated
lost-response/crash/recovery witnesses for both branches; the unbounded kernel proves 26/26 TLAPS obligations while
permitting an empty fresh-output set. No refinement theorem to the operational Ada implementation is claimed.

The private version-preserving two-run merge candidate reruns the current warning-strict selected-unit gate and
proves all 1,088 checks: 165 by flow analysis and 923 by provers, with maximum successful effort 6,890 steps and zero
warnings, unproved or justified checks, or `pragma Assume`. The operational runtime merger remains outside those six
selected SPARK units. Its executable boundary is the deterministic exact-entry test: same-key histories from two
ordered nonoverlapping runs are merged newest-run-first while retaining every Put/Delete version, the exact combined
SST encodes/decodes unchanged, and reversed ranges plus input-identity reuse publish no output. Allocation extents are
checked sums of authenticated input shapes; run selection, publication, descriptor replacement, snapshot pruning,
and refinement from either TLA+ lane remain outside this unit.

The manifest-admission refinement reruns the same 1,088-check gate. The runtime merger remains outside the selected
SPARK units; deterministic executable evidence now requires exact descriptor equality and adjacency in one
structurally valid manifest family before allocation, rejects reversed and nonadjacent authority, and rejects output
identity collision with either selected or retained runs. Current-HEAD generation binding and publication remain
outside this refinement.

The effect-free partial-merge successor candidate increases the warning-strict selected-unit result to 1,090/1,090:
94 initialization, 526 run-time, 91 assertion, 306 functional-contract, and 73 termination checks. Flow analysis
discharges 166 and provers discharge 924, with maximum successful effort 6,890 steps. Every selected unit reports
zero warnings, unproved or justified checks, and zero `pragma Assume`. The newly selected checkpoint-predecessor
predicate proves its transition arithmetic and termination; recovery and successor construction now share that one
persisted-chain rule. The dynamically allocated runtime builder remains an executable boundary. Deterministic tests
cover exact adjacent replacement, retained fields, shifted later-family run slices, invalid successor authority,
merged-SST round trip, and successor-manifest round trip. Current-HEAD binding, immutable object I/O, conditional
publication, progress, policy selection, and refinement from the TLA+ partial-merge model remain outside this unit.

The private adjacent-merge publication candidate reruns that same warning-strict boundary at 1,090/1,090 checks:
166 by flow analysis and 924 by provers, with zero warnings, unproved or justified checks, or `pragma Assume`. The
dynamic planner and publisher remain outside the selected SPARK packages. Their executable qualification binds the
retained manifest to exact current HEAD/generation authority, authenticates every named SST with header-first and
same-generation whole reads, admits only the selected adjacent pair, confirms the merged SST and exact successor
before conditional HEAD publication, and reconstructs the same plan after an accepted/lost immutable response. A
later log suffix is now cloned before effects at its exact decoded extents and replayed after SST-only replacement
activation. Memory/files witnesses retain duplicate-identity and write-conflict authority, reject injected history
allocation before publication, remove all retired input runs, and reopen from the final merged output plus the suffix.
Recovery accepts the descendant HEAD only through exact validated manifest-chain anchors for the latest batch and
its checkpoint boundary. No SPARK proof of Object Storage, protected lifecycle, allocation, or Ada/TLA refinement is
claimed.

The owner-driven selected-run reader preserves that warning-strict boundary at 1,090/1,090 checks: 94
initialization, 526 run-time, 91 assertion, 306 functional-contract, and 73 termination checks; flow analysis
discharges 166 and provers discharge 924. The maintained `./scripts/prove.sh` wrapper exits zero with its explicit
success sentinel, every selected unit reports zero warnings or `pragma Assume` statements, and the report contains
no unproved or justified check. The new client-backed HEAD, exact-generation frozen-header range, same-generation
whole Get, moved-buffer ownership, cancellation, and synchronous wait remain executable integration boundaries
rather than selected SPARK units. The authenticated client probe qualifies their exact generation/length/descriptor
binding, pre-read failure without publication, explicit same-identity retry, merged receipt, and cacheless reopen.
The abstract adjacent-merge algorithm is unchanged, so this execution-path unit does not claim a fresh TLA+ run or
an Ada refinement theorem.

The exact-three-run algorithm lane remains separate from automatic pair publication policy. TLC
exhausts 12,288/12,288 states at depth 3, the deliberately broken middle-tombstone-loss transition violates Safety,
and the concrete first-Put/middle-Delete/last-empty/suffix-Put trace validates byte-for-byte. TLAPS proves all seven
strict obligations for arbitrary nonempty key and value sets: associativity, last/middle mutation retention, middle
tombstone retention, point and whole-view composition, and equality with retained older/newer runs plus any suffix.
The private Ada kernel retains the stronger snapshot-safe representation of every version and tombstone in one exact
checked allocation; deterministic tests bind three adjacent manifest descriptors, preserve retained neighbors, and
reject retained-identity reuse and reordered sequence authority. The private operational publisher now reads those
three exact inputs and publishes their successor through the existing Flush owner stack. Local tests additionally
cover reordered-input rejection before publication, an uncertain output response resolved from the exact same bytes,
middle-tombstone recovery after all source objects and local state are removed, and a retained later-log suffix. The
authenticated client probe covers the same selected-reader operation with a definite pre-read failure and an
uncertain output response. Automatic selection, fanout, trigger, levels, public API, and an Ada refinement theorem
remain outside this candidate. The warning-strict selected SPARK boundary remains green at 1,090/1,090 checks with
the maintained success sentinel; the dynamic runtime merger and Object Storage driver remain executable boundaries
rather than newly selected proof units.

## TLA+ state-machine assurance

`./scripts/check-tla.sh` is the authoritative distributed-state-machine gate. It is separate from the SPARK gate:

- TLC exhausts 112,031 distinct states of the bounded two-writer, two-transaction commit-publication model and checks
  type, reachable-chain, transaction-count sequence advancement, whole-batch visibility and outcomes,
  durable-acknowledgment, no-replay, explicit stale-publication history, and cacheless all-or-none recovery. The gate
  separately requires successful pooled-batch coverage. A negative model deliberately applies the shared
  publication-history function after a writer becomes stale and must violate the stale-publication invariant. A
  second negative model overlaps one transaction between an ever-unknown batch and an active batch and must violate
  the transaction-level no-active-replay invariant.
- A deliberate witness predicate emits a two-transaction, cross-family, accepted-but-response-lost publication path.
  A checked converter validates every state and projects the scenario to
  `oracles/workloads/tla_commit_publication_witness.ndjson`.
- Two additional checked witnesses require committed and failed reconciliation after two later valid HEAD
  transitions, guarding chain-descendant reasoning rather than only exact or immediate HEAD matching.
- TLAPS, in strict mode with its SMT backend, proves all 23 obligations in the unbounded inductive safety kernel.
  These obligations cover initialization and preservation by every abstract action, pairwise-disjoint transaction
  ownership across batches, and the derived transaction-level no-active-replay theorem.
- A separate manifest model exhausts 286 states at depth 10. It checks exact-byte confirmation after an ambiguous
  immutable Put, stored-before-HEAD publication, append-only registry configuration, committed and failed lost-HEAD
  reconciliation, later-writer successor publication, crash, and cacheless recovery. Checked witness traces cover
  both reconciliation conclusions, and a negative registry-mutation probe must fail. Its focused TLAPS kernel proves
  12/12 inductive obligations for stored/confirmed publication, predecessor storage, immutable existing
  configuration, and disposable local cache state.
- The staged first-LSM checkpoint model exhausts 819 states at depth 19. It covers exact two-family L0 placement and
  reconstruction, separate family/aggregate run and identity capacity, an exact captured ledger including admitted
  nonvisible identities, accepted and unaccepted lost HEAD responses, a real external prepublication advance, later
  manifest-preserving commit, crash, cacheless recovery, and missing/corrupt named-run rejection. Three independent
  validators check committed, rejected, and recovery traces. Integrated stale-publication, partial-run, wrong-family,
  and wrong-ledger probes must fail after reachable prefixes, and every normal action has nonzero TLC coverage. Its
  smaller unbounded kernel proves 43/43 strict TLAPS obligations for
  abstract stored-before-confirmed ordering, confirmed HEAD references, immutable registry, exact expected-generation
  publication, disjoint checkpoint/later authority, no replay overlap, exact recovery, and disposable local cache.
  It does not prove concrete run construction, sorting, corruption, capacity arithmetic, reconciliation, codecs, or
  refinement to Ada.
- The successive whole-state checkpoint model exhausts 37 distinct states at depth 17 with nonzero semantic-action
  coverage. It checks first and replacement checkpoint publication, complete current-state runs, immutable retained
  predecessors, exact persisted history backpressure before effects, accepted-but-lost second HEAD response,
  read-only reconciliation, crash, and cacheless recovery. A checked 18-action witness requires the lost response to
  be resolved before crash and validates the exact manifest/run/transaction/identity chain after recovery. A
  deliberately early second-HEAD probe must violate safety. Its arbitrary-set, unbounded-cycle kernel proves 24/24
  strict TLAPS obligations for stored/confirmed ordering, exact HEAD references, immutable history, complete
  checkpoint authority, recovery, and disposable local state. Concrete codecs, sorting, allocation, provider
  behavior, progress, garbage collection, multi-run levels, compaction, and refinement to Ada remain outside this
  proof.
- The additive-L0 model exhausts 49 distinct states at depth 17 with nonzero semantic-action coverage. It checks
  independent persisted family/global run backpressure before effects, preservation and append of the first run,
  explicit newer tombstone masking, a second-key Put, accepted-but-lost HEAD response, read-only resolution, crash,
  and exact recovery. Its checked 18-action witness validates both retained immutable runs, exact successor linkage,
  the tombstoned key's absence, the second value, and identity authority. A deliberately early HEAD probe must
  violate safety. Its arbitrary-set, unbounded-cycle kernel proves 24/24 strict TLAPS obligations for
  stored/confirmed ordering, current confirmed-run authority, append-only publication, exact checkpoint/suffix
  partitioning, recovery, and disposable local state. Concrete sequence ordering, key/value merge, codecs,
  capacities, provider behavior, progress, compaction, and refinement remain outside this proof. The operational Ada
  planner/recovery path is qualified separately by deterministic multi-run, tombstone, old-run, independent-capacity,
  certainty, cacheless-reopen, allocation-failure, and backend tests.
- The L0-compaction model exhausts 35 distinct states at depth 10 with nonzero semantic-action coverage. Starting
  from the qualified two-run authority, it checks definite output-capacity rejection before effects, one-output and
  canonical-empty successor-manifest confirmation, exact-generation publication, accepted-but-lost response and
  read-only resolution, removal of predecessor runs from current authority while retaining their immutable bytes,
  missing-present-output fail-closed recovery, crash, and exact recovery from either the compacted run or no current
  runs. Validated ten-action ordinary and nine-action empty-output witnesses fix both accepted-lost recovery paths,
  and a deliberately early HEAD action must violate safety. The arbitrary-set, unbounded-cycle kernel admits an empty
  fresh-output set and proves 26/26 strict TLAPS obligations for stored/confirmed ordering, confirmed current
  authority, fresh/current/retired separation, exact checkpoint/suffix authority, recovery, and disposable local
  state. A separate read-equivalence model exhausts 576 states at depth 4 across all two-key,
  two-value captured views and later Put/Delete/no-mutation maps. Its validated four-action witness deletes one
  recovered live key and puts one formerly absent key; omitting a live replacement entry must violate safety. The
  arbitrary-key/value kernel proves 6/6 strict TLAPS obligations for canonical Put-only replacement, exact recovery,
  and equivalence under any later delta. The policy-neutral partial-merge model separately exhausts 3,145,728 states
  at depth 3 across every two-key/two-value older/selected-pair/newer/suffix mutation map. Its validated three-action
  witness preserves exact reads and suffix transaction-identity authority through the merge, while a probe that
  transfers the suffix correctly but drops the newest selected tombstone must violate safety. The arbitrary-key/value
  kernel proves 5/5 strict TLAPS obligations for newest selected mutation and tombstone retention, mutation
  composition, selected-pair equivalence, and equality after any suffix over retained surrounding runs. These lanes
  do not prove operational merge refinement, run selection, snapshot retention sufficiency,
  physical reclamation, codecs, capacity arithmetic, provider behavior, progress, or a public trigger.
  The private operational
  Ada planner/publisher is qualified separately by deterministic replacement, allocation, certainty, depublication,
  and cacheless-recovery tests.
- The immutable-cache model exhausts 623 distinct states at depth 12 with nonzero coverage for read capture, exact
  cache hit, fetch ownership/join/completion, authority advance, corruption rejection, eviction, and complete local
  loss. Its validated 20-state witness fixes two-reader coalescing on one generation, later-generation refetch after
  local loss, corrupt-entry rejection without a result, and exact final recovery. A deliberately stale-generation
  hit must violate safety. The arbitrary-set kernel proves 13/13 strict TLAPS obligations for stored authority,
  exact captured requests/results, one in-flight fetch identity per immutable entry, verified/corrupt cache
  separation, and disposable local state. Zero-versus-one capacity is finite qualification geometry. Concrete
  capacities, allocation failure, eviction order, disk layout, checksum implementation, progress, public API, and
  refinement to Ada remain outside this proof.
- The immutable-object retention model exhausts 75,337 distinct states at depth 16 with nonzero coverage for object
  storage/discovery/age marking, snapshot and replica acquisition/release, authority advance, predecessor release,
  unknown-attempt begin/resolve, deletion, and discovery loss. Its validated 24-state witness retains exact objects
  through current, snapshot, replica, predecessor, and unresolved authority; reconstructs disposable discovery; and
  deletes only a fully released predecessor and resolved orphan. A listing-only deletion of the aged current
  reachability set must violate safety. The arbitrary-set kernel proves 15/15 strict TLAPS obligations for stored
  protection,
  discovery soundness, no identity reuse, and no protected deletion. The finite two-object graph and third witness
  identity are qualification geometry. Reachability traversal, age/clock policy, replica lease protocol, provider
  deletion certainty, batching, progress, public API, and refinement to Ada remain outside this proof.
- The replica-refresh model exhausts 1,460 distinct states at depth 15 with full action coverage. Its validated
  16-state witness fences a captured writer, publishes through the exact replacement epoch, loads ordinal one while
  authority reaches ordinal two, installs that lagging snapshot monotonically, and catches up. Stale-writer and
  rollback probes must violate safety. The arbitrary-natural kernel proves 11/11 TLAPS obligations for confirmed
  authority, nonfuture captured/installed pairs, high-water equality, no rollback, and no stale publication. A
  private synchronous Ada driver now qualifies complete graph validation, safe allocation failure, same-HEAD no-op,
  monotonic catch-up, fenced-writer refusal, and close/reopen local-loss continuity through deterministic memory/files
  tests. Transport certainty, polling, leases, promotion, progress, public/composable API, and formal refinement
  remain outside.
- The snapshot-isolation write/write model exhausts 336 states at depth 10. It checks fixed Begin sequences,
  per-written-key post-snapshot rejection, disjoint concurrent commits, checkpoint advancement of the retained exact
  history boundary, and conservative rejection below that boundary. Three independently validated witnesses cover
  same-key conflict, disjoint success, and checkpoint-stale rejection. A negative unsafe-commit action must violate
  the no-invalid-commit monitor. Its unbounded inductive kernel proves 6/6 strict TLAPS obligations for initialization
  and action-by-action preservation of state/sequence bounds and the invalid-commit monitor. It does not prove
  retention sufficiency, reads, serializable predicates, grouped commits, byte-key equality, progress, or refinement
  to Ada.
- The fixed-snapshot point-read model exhausts 7,530 states at depth 14. It checks read-your-writes before committed
  state, newest committed version selection no later than Begin, and conservative `TooOld` below the checkpoint
  history boundary. Independent validators require old-value, own-write, and too-old traces, while a negative model
  must trip the bad-read monitor when it substitutes latest state. Its unbounded kernel proves 7/7 strict obligations
  for type/sequence preservation and exact modeled selection. The two-version finite representation is qualification
  geometry, not product retention; byte lookup, allocation, retained-history sufficiency, progress, serializable
  predicates, and refinement to Ada remain outside this proof.
- The serializable-validation model exhausts 44,244 states at depth 13. It checks snapshot write conflicts,
  serializable point and normalized-range conflicts, and independent point/range capacity rejection with nonzero
  coverage for every semantic action. Independent validators require exact point-conflict, range-conflict,
  snapshot-non-retention, and full-point-set own-write traces; a negative unsafe action must violate the
  no-invalid-commit monitor. Its unbounded
  action-preservation kernel proves 10/10 strict TLAPS obligations for state/sequence soundness and guarded commit
  safety over arbitrary nonempty transaction/key/range sets. Finite cardinality/backpressure remains in the exhaustive
  TLC lane; retained-history sufficiency remains in the separate snapshot model. This lane does not prove range
  normalization, persisted sizing, allocation, public API shape, progress, or refinement to Ada; the dedicated lane
  below now owns the normalization rule.
- The scan-range-normalization model exhausts 3,419 states at depth 4. It checks same-family overlap and endpoint
  contact, transitive bridge coalescing, cross-family separation, full-capacity merging, disjoint-component
  backpressure, and allocation rollback. Its validated eight-state witness covers every critical branch, while an
  incomplete bridge merge must violate pairwise normalization. The arbitrary-universe action kernel proves 19/19
  strict TLAPS obligations for exact logical coverage, normalized retained authority, capacity preservation, and
  atomic rejection. The TLAPS kernel assumes a pure normalizer and an abstract range-count function; TLC checks the
  concrete finite endpoint algorithm. Byte storage, list ownership, allocation implementation, concurrency,
  progress, and refinement to Ada remain outside this formal boundary.

The TLAPS kernel is a batch-atomic abstraction assigning every batch an arbitrary nonempty transaction set, with
pairwise-disjoint ownership between batches. It proves publication-epoch monotonicity, acknowledged whole-batch
visibility, and derives transaction-level no-active-replay from batch no-replay plus ownership. The executable TLC
model separately checks sequence arithmetic, recovery, and stale-writer exclusion. The mapping and deliberately
excluded claims are documented in `formal/tla/README.md`; no machine-checked refinement theorem is claimed.
