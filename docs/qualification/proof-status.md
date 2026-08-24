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
  covering exact checkpoint-manifest-v2 and SST-v1 length arithmetic, structural validation, fail-closed arbitrary-
  bound decoding, exact cursor and slice bounds, and definite initialization; and
- `Flyology.DB.Reference_Model`, covering absence of runtime checks and definite initialization in bounded MVCC state
  transitions. Executable tests, rather than current functional proof contracts, establish the model's fixed-snapshot,
  conflict, atomic-commit, and rollback examples. Exact duplicate scan predicates are deduplicated; full range-union
  normalization and its functional proof remain a Milestone 3 target.

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
  TLC lane; retained-history sufficiency remains in the separate snapshot model. Range normalization, persisted
  sizing, allocation, public API shape, progress, and refinement to Ada are not proved.

The TLAPS kernel is a batch-atomic abstraction assigning every batch an arbitrary nonempty transaction set, with
pairwise-disjoint ownership between batches. It proves publication-epoch monotonicity, acknowledged whole-batch
visibility, and derives transaction-level no-active-replay from batch no-replay plus ownership. The executable TLC
model separately checks sequence arithmetic, recovery, and stale-writer exclusion. The mapping and deliberately
excluded claims are documented in `formal/tla/README.md`; no machine-checked refinement theorem is claimed.
