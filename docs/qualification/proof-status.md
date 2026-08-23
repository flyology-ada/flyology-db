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
- `Flyology.DB.Reference_Model`, covering absence of runtime checks and definite initialization in bounded MVCC state
  transitions. Executable tests, rather than current functional proof contracts, establish the model's fixed-snapshot,
  conflict, atomic-commit, and rollback examples. Exact duplicate scan predicates are deduplicated; full range-union
  normalization and its functional proof remain a Milestone 3 target.

The proof does not establish provider atomicity, read freshness, transport behavior, durability barriers, or that a
concrete I/O adapter supplies bytes faithfully. Object Storage conformance and executable boundary tests gate those
trusted boundaries.

`Flyology.DB.Batch_Formats` is one private bounded operational instance rather than a public generic. Its helper
contracts split header, transaction, and mutation encoding, and split bounded count, extent, and byte-copy decoding,
so GNATprove checks each bound without constructing one monolithic verification condition. The persisted
32-bit/64-bit wire widths remain independent of those operational caps; a future larger instance must repeat the
memory-budget, corruption-test, and proof gates.

Executable golden-byte, corruption, boundary, HEAD-binding, and cacheless-recovery tests establish byte ordering,
CRC-32C behavior, semantic rejection classes, and concrete publication/predecessor predicate examples. The current
SPARK contracts do not claim functional equivalence between those byte-level behaviors and an independent codec.

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

The TLAPS kernel is a batch-atomic abstraction assigning every batch an arbitrary nonempty transaction set, with
pairwise-disjoint ownership between batches. It proves publication-epoch monotonicity, acknowledged whole-batch
visibility, and derives transaction-level no-active-replay from batch no-replay plus ownership. The executable TLC
model separately checks sequence arithmetic, recovery, and stale-writer exclusion. The mapping and deliberately
excluded claims are documented in `formal/tla/README.md`; no machine-checked refinement theorem is claimed.
