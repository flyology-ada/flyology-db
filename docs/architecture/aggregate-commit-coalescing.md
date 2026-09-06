# Aggregate commit coalescing experiment

This document defines a private, new-root-only performance experiment. It is not a public API,
default, migration policy, or claim that ordinary independent `Commit` has changed semantics.

## Question and publication boundary

Can independently submitted transactions retain their transaction identities and pre-freeze
validation while sharing one physical immutable batch and one conditional HEAD transition after a
bounded cohort freezes?

The caller selects an exact cohort width and a never-reused physical-batch ordinal range through the
private benchmark bridge. Neither value is persisted as scheduling policy or selected from the host.
The aggregate profile is persisted only to prevent a root from being opened under ordinary or
independent-member publication semantics. Ordinary roots and explicit `Commit_Group` are unchanged.

Before admission, invalid, cancelled, or expired candidates terminate independently. After
admission and before freeze, candidates that conflict with newly committed history or earlier cohort
members terminate independently. An admitted cancellation request drains to an exact terminal
result; it does not remove an underfilled member from the queue. An exact-width conflict-free cohort
then receives contiguous sequences and one caller-owned physical batch identity. The coordinator
encodes all members into one batch-v1 object, publishes it once, and attempts one HEAD transition
over the complete sequence range. No member succeeds before the HEAD transition is authoritative.
A lost HEAD response returns a separate receipt for every member; each receipt resolves the same
retained batch and HEAD read-only without replaying a transaction.

## Deliberate differences from ordinary Commit

- `Receipt_Transaction_ID` and `Receipt_Sequence` remain member-specific, while
  `Receipt_Batch_ID` is the shared physical aggregate identity.
- Exported version-3 durable authority contains the complete aggregate batch, including sibling
  application keys and values. It is suitable only for one caller-approved trust domain and remains
  bearer authority requiring authenticated, confidential storage and higher-level request binding.
- Every member shares the post-freeze publication fate. A failure before the HEAD attempt fails the
  frozen cohort; a conclusive competing HEAD fences the writer.
- Finite deadlines remain unsupported in the exact-width experiment, and an underfilled tail waits
  for more admissions or close. No timer, partial-tail rule, or public latency promise is implied.
- The caller must never reuse the supplied physical identity range. A surviving orphan object is
  detected by conditional create and fences reuse; if no object survived, the store cannot prove
  that the caller reused an identity.

## Configuration and promotion boundary

Width, admission pipeline depth, and the first physical-batch ordinal are independent benchmark
inputs. Qualification must report all three and compare matched total transactions, mutations,
bytes, durability, reopen verification, and final state identity on the same host. A winning width or
depth is workload and provider evidence, not a hard-coded product default.

Promotion requires maintained deterministic and provider tests for exact one-batch/one-HEAD
geometry, member identity, full-cohort authority import and resolution, corruption, allocation,
collision, conflict, cancellation, unknown outcomes, crash, reopen, and zero-write resolution. The
TLA+ model and TLAPS kernel must establish the corresponding all-or-none visibility, no replay,
identity separation, pre-freeze exclusion, crash recovery, and authority properties before runtime
results can justify any broader API or policy proposal.

## Executable authority-recovery replay

`AggregateCommitCoalescingAuthorityReplay` projects the accepted aggregate HEAD witness onto eight
observable API steps: submit and finish two independent singleton commits with a lost accepted HEAD
response; export member one; export member two; close and destroy the complete quiescent local
session; open a fresh session and read both values; import member one; import member two; resolve
member one. The memory backend and caller-owned exported bytes are the only surviving storage and
reconciliation authority. The original database, context, receipts, operations, and family handles
do not survive the session boundary.

The private Ada adapter verifies the exact member transaction IDs and contiguous sequences, the
shared physical batch identity, and both exported complete batch images through the envelope and
batch decoders. Every step reports the receipt states, recovered values, and cumulative batch, run,
manifest, and HEAD publication counts. Import and resolution must add zero publications. Resolving
one member leaves its sibling receipt unknown until that sibling is explicitly reconciled.

The maintained TLA runner generates and validates the canonical trace through `flyology-tla`, then
runs the adapter with `--aggregate-authority --max-steps 8`. Its deliberate `--buggy` lane resolves
the sibling and must diverge at `ResolveMember`. Update mode permits only this named addition and
the two existing live-suffix witnesses; existing canonical bytes remain immutable. The repository
shape becomes 42 canonical traces only after the generated aggregate trace is accepted. The four
existing L0 checkpoint-policy replays and their intentional divergence remain separate lanes.

This boundary exercises explicit local teardown after `Outcome_Unknown` has returned. It does not
claim process termination inside Commit, a provider-specific replay, a liveness guarantee, or a
general refinement proof. The finite aggregate model and unbounded safety kernel cover their own
documented abstractions. Source wiring alone is not passing replay evidence; the maintained runner
must generate the trace and execute both the conformant and divergent Ada lanes successfully.
