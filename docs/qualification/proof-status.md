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
from retained tool output and are not hard-coded here. No assumptions, false-positive suppressions, or imported ghost
axioms are admitted.

Current selected packages:

- `Flyology.DB.Head_Policy`, covering initial-head validity, writer acquisition, commit sequence/identity transitions,
  monotonic transition ordinals, and conservative ambiguous-outcome reconciliation;
- `Flyology.DB.Formats`, covering explicit big-endian head encoding, bounds, CRC-32C calculation, and fail-closed
  structural decoding; and
- `Flyology.DB.Reference_Model`, covering absence of runtime checks and definite initialization in bounded MVCC state
  transitions. Executable tests, rather than current functional proof contracts, establish the model's fixed-snapshot,
  conflict, atomic-commit, and rollback examples. Exact duplicate scan predicates are deduplicated; full range-union
  normalization and its functional proof remain a Milestone 3 target.

The proof does not establish provider atomicity, read freshness, transport behavior, durability barriers, or that a
concrete I/O adapter supplies bytes faithfully. Object Storage conformance and executable boundary tests gate those
trusted boundaries.

## TLA+ state-machine assurance

`./scripts/check-tla.sh` is the authoritative distributed-state-machine gate. It is separate from the SPARK gate:

- TLC exhausts 105,663 distinct states of the bounded two-writer, two-transaction commit-publication model and checks
  type, reachable-chain, durable-acknowledgment, no-replay, explicit stale-publication history, and
  cacheless-recovery invariants. A separate negative model deliberately applies the shared publication-history
  function after a writer becomes stale and must violate the stale-publication invariant.
- A deliberate witness predicate emits an accepted-but-response-lost publication path. A checked converter validates
  every state and projects the scenario to `oracles/workloads/tla_commit_publication_witness.ndjson`.
- TLAPS, in strict mode with its SMT backend, proves all 20 obligations in the unbounded inductive safety kernel.
  These obligations cover initialization and preservation by every abstract action.

The TLAPS kernel is an abstraction of the executable TLC model. It proves publication-epoch monotonicity, while the
executable TLC model separately checks stale-writer exclusion with a history monitor. The mapping and deliberately
excluded claims are documented in `formal/tla/README.md`; a machine-checked refinement theorem between the two
models is not yet claimed.
