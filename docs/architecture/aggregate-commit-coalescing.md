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

## Adaptive cohort foundation

The exact-width experiment establishes the physical saving but is not an ordinary-commit policy. A
promotable private successor may freeze the oldest compatible prefix when a caller-selected maximum
member count, maximum encoded-byte count, or maximum queue wait is reached. Close freezes a remaining
nonempty tail only while its predecessor is conclusive. If an active cohort is unknown, close preserves
that cohort's member authorities, fails still-unfrozen queued members without publication, and permits
the unknown members to resolve after reopen. An individually valid transaction larger than the
coalescing byte target is published alone; coalescing cannot make it uncommittable. The admission depth
remains an independent caller-selected bound. These values are persisted only if a future profile needs
recovery to reject incompatible publication semantics; measurements on one host do not select defaults.

Coordinator admission remains the ownership cut. Cancellation observed before admission leaves the
transaction active. After admission, cancellation is a drain request and cannot withdraw a member.
A deadline that expires while its transaction is still queued may classify that member `Timed_Out`
with zero publication. Freeze fixes the complete member list, sequences, payload, and shared physical
identity. A failure before HEAD can possibly enter applies to the frozen cohort. Once HEAD may have
entered, every member retains `Outcome_Unknown` until the exact attempted successor or a conclusive
different successor is observed. No member can receive a definite negative result while a sibling can
still become visible.

The first private runtime prototype rejects finite commit deadlines before admission. Its maximum
cohort wait is a separate scheduling target and cannot become an operation deadline. A future ordinary-
commit profile may expire a member only while it remains unfrozen; after freeze, each admitted member
drains to the shared publication certainty even if its caller deadline later passes. That broader
profile needs an explicit compatibility decision because it changes when a finite-timeout caller can
regain control; the bounded model explores the safety boundary but does not authorize that policy.

The adaptive profile does not require a separately allocated physical identity. Its batch ID is the
oldest frozen member's caller-owned, never-reused transaction ID. That ID occurs exactly once in the
member ledger; all siblings remain distinct. This is the same alias authority already used by a
singleton, but it is selected by the aggregate profile and member count rather than inferred from ID
equality. Explicit `Commit_Group` continues to require a group ID distinct from every member. A
restarted caller must not resubmit the oldest transaction ID with different cohort membership; a
returned unknown is recovered only through its full-cohort receipt or exported durable authority.
Existing aggregate roots whose physical batch IDs are distinct from every member remain readable.
The leader-alias shape is a private new-root experiment: an older reader rejects it, so this work does
not claim rollback compatibility or migrate an existing root to the adaptive shape.

One immutable aggregate and one conditional HEAD remain the complete durability boundary. Every
member receipt names its own transaction and sequence plus the shared batch and exact predecessor and
attempted HEAD. Resolution authenticates the full cohort and the requested member, reads HEAD
authority, and performs no publication. Resolving or releasing one receipt cannot invalidate sibling
authority. Conditional rejection and conclusive rejected resolution fence the writer immediately;
confirmed HEAD followed by local installation failure remains durable success and fences local reuse
until recovery.

The finite model must cover width-, byte-, wait-, and close-triggered tails, queued expiry, admitted
cancellation, conflict exclusion, all shared publication outcomes, crash/reopen, independent member
authority, and stalled-provider executions. Its liveness claims require explicit fairness for clock,
coordinator, and provider progress; unknown resolution additionally requires caller action and
responsive authoritative reads. The unbounded TLAPS kernel proves safety only. Neither finite geometry
nor fairness assumptions become runtime policy.

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
