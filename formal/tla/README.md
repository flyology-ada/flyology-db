# TLA+ assurance lane

This directory specifies commit publication and recovery before the production engine implements them. It has
three related artifacts with deliberately different jobs.

`CommitPublication.tla` is the executable finite model. Two writers and two transactions can prepare
immutable batches, race conditional HEAD publication, lose a response before or after acceptance, reconcile a
receipt, acquire a new writer epoch, crash, discard all local state, and recover the exact remote chain.
`CommitPublication.cfg` asks TLC to exhaust the model under opaque-transition symmetry and check every safety
invariant. Transition identity is the pair of monotonic ordinal and opaque value: the model deliberately permits an
older opaque value to recur at a later ordinal, while prohibiting equality with the immediate predecessor. This
exercises the same anti-reuse defense as the persisted HEAD policy instead of assuming globally fresh opaque values.
`CommitPublicationStaleProbe.tla` deliberately applies the shared publication-history function after a writer has
become stale; the gate requires TLC to reject that negative probe through `NoStaleWriterPublication`. This keeps the
history monitor itself from becoming a vacuous green check.

`PublicationSafetyProof.tla` is an unbounded abstraction. TLAPS proves initialization and action-by-action
inductive preservation for these properties:

- visible batches were published remotely;
- acknowledged transactions are wholly visible;
- visible publication epochs never exceed the current epoch;
- a transaction that returned an unknown outcome can only resolve, never become active again; and
- local state is a discardable subset of remote state.

The proof kernel intentionally omits byte formats, conditional-write provider behavior, linked-batch ordering,
and progress. SPARK covers executable format and policy code; provider conformance tests cover storage atomicity.
TLC checks the richer linked-chain model over its complete finite state graph, including an explicit history flag
that would record any stale-writer publication. There is not yet a machine-checked refinement theorem from the TLC
model to the proof kernel, so the gate does not claim one. In particular, the TLAPS epoch property is monotonicity;
stale-writer exclusion is checked by the executable model and is not attributed to that proof-kernel property.

## Witness projection

`CommitPublicationWitness.tla` adds a deliberate invariant violation that asks TLC for one useful path. The
retained path is not treated as proof. `witness_to_workload.py` first rejects any trace whose exact action sequence
and critical state snapshots do not match the intended scenario, then applies this scenario projection:

| TLA+ action | Workload observation |
| --- | --- |
| `Prepare` | begin one snapshot transaction and buffer two cross-family puts |
| `StoreBatch`, `PublishHead`, `LoseAcceptedResponse` | commit returns `Outcome_Unknown` with one receipt |
| `ResolveCommitted` | resolving that receipt returns `Success`; the transaction is not replayed |
| `Crash` | the outer runner kills the adapter and discards every local cache/staging artifact |
| `Recover` | reopen, read both families, and assert the complete canonical state |

The checked-in result is `oracles/workloads/tla_commit_publication_witness.ndjson`. The formal gate regenerates
it from fresh TLC JSON, compares it byte-for-byte, and validates it with the normative workload validator.
Milestone 2 adds the actual replay runner; until then the witness is executable contract input, not implementation
evidence.

## Reproduction

Install the pinned tools under ignored `.deps/tla` as recorded in
`docs/qualification/dependency-provenance.md`, provide Java 11 or newer, and run:

```sh
./scripts/check-tla.sh
```

The checked configuration uses one TLC worker for deterministic breadth-first witness selection. The exhaustive
gate must report 105,663 distinct states at depth 14, and strict TLAPS must prove 20 of 20 obligations. Larger state
spaces belong to qualification campaigns and must not replace this fast per-change gate.
