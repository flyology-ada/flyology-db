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
members terminate independently in the initial exact-width experiment. The pipelined successor instead
keeps conflicts with unpublished candidates pending until their predecessor outcome is conclusive;
only installed history can establish that conflict rejection. An admitted cancellation request drains
to an exact terminal result; it does not remove an underfilled member from the queue. An exact-width
conflict-free cohort then receives contiguous sequences and one caller-owned physical batch identity.
The coordinator encodes all members into one batch-v1 object, publishes it once, and attempts one HEAD transition
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

The pipelined source foundation extends this boundary in place with independent bounded admission,
canonical per-transaction preparation, bounded aggregate assembly and ready ownership, and overlapping
successor preparation/immutable PUTs. Width, bytes, wait, admission depth, preparation concurrency,
pipeline depth, and total retained bytes are finite qualification parameters, not runtime profile
defaults. Admission reserves the current input, one future input-sized preparation or aggregate credit,
and one abstract envelope unit per pending member. Starting preparation transfers the future fragment
credit into resident storage; joining it transfers that credit to the future aggregate; freezing a
cohort consumes the member credits and releases all but its single aggregate envelope. This derived
reservation is conservative model geometry, not a public byte-limit formula or encoded runtime size.
The cohort `MaxBytes` target normally limits one encoded cohort independently of the total retained-byte
budget; the existing oversized-singleton rule may exceed that target but never the total byte budget.
Freeze preserves admission order, immutable predecessor identity, and independent member sequence
receipts. A candidate conflicting with an unpublished predecessor stays unfrozen until
conclusive revalidation. The finite conflict relation abstracts transaction-owned snapshot, mutation,
point-read, and normalized range evidence; canonical preparation must retain that evidence through join
and cohort selection. Its concrete encoding and ownership remain Ada correspondence obligations.
Completion slots remain occupied until coordinator `CollectTerminal`, independently of retained receipt
authority; publication alone does not release admission capacity. Public `Finish` is represented only by
`DeliverReceipt`, a later transfer from the detached operation to its caller. Export, resolution, and
caller receipt release require delivery. Operation finalization instead uses `DiscardCollected` for an
undelivered collected result. Final close and caller-driven resolution wait for all admitted operations
to be collected; neither close nor worker successor draining depends on public receipt delivery.
The returned-authority crash lane requires every admitted result to have been publicly delivered.

Only the publication front may run `ValidateFront` against the exact installed predecessor and token.
Success enters `HeadReady`, owns one mutable installation projection, and records successful validation
history that outlives that projection. `StartHead` requires the same installed predecessor and token.
A failed validation enters definite `PreHeadFailed` and abandons the front and its suffix with no HEAD
attempt or unknown receipt authority. A failed later cohort preparation records `prepareFailed` without
halting successful predecessors; `FailPreparedFront` halts and drains it only when it reaches the front.
Successor cleanup may release its own resources but cannot clear another cohort's projection.
Canonical successor preparation and immutable PUT may overlap front validation and publication; local
installation remains front-only, and publication join or retirement releases the projection.
Normal close drains compatible work only behind a conclusive predecessor;
an unknown front instead joins and abandons every queued or not-yet-HEAD successor before front
resolution or close. Successful resolution does not restart the halted episode, and no successor is
rebased, resequenced, or replayed. Finite deadlines remain unsupported in this private profile.
Focused progress and lifecycle lanes distinguish responsive joins from a permanently stalled provider.
The changed safety proof source covers dynamic membership and exclusive reservation ownership; FIFO
selection, conflict predicates, sequence arithmetic, encoding sizes, tokens, and fallible installation
remain explicit concrete-model or implementation correspondence obligations. The changed sources are
not yet qualified: fresh TLC graphs, named negative controls and witnesses, conditional progress,
strict clean-fingerprint TLAPS results, and later Ada trace replay must precede runtime adoption.
The exhaustive safety campaign covers the four-transaction graph with all 24 fixed admission-order
slices. Every finite admission history is a prefix of one such permutation because an identity is
admitted at most once; every snapshot choice and every non-admission transition remains available.
Each slice retains the complete operational state while erasing the diagnostic last-action field,
history-only cancellation and conflict-wait membership, and write-only evidence for preparation and
batch overlap, out-of-order completion, close-tail selection, local activation failure, close
completion, and ignored stale completions. It also canonicalizes transaction-preparation and batch-PUT
outcomes after their requests have joined, when retained fragments, failure ledgers, phase, and storage
state determine every successor. Completed-but-unjoined outcomes remain exact. Cancellation,
conflict-wait, and stale-completion observations become projected stutters; the retained transitions do
not read any erased evidence.
The full diagnostic witnesses and every lifecycle and progress lane retain the unquotiented state.
Crash, reopen, collection, delivery, receipt, and authority state are never erased. The quotient is a
finite safety-search reduction justified by this concrete dependency boundary; it is not an Ada
refinement proof or a liveness reduction.
The runner deliberately rejects qualification until reviewed geometry, action coverage, and proof
totals replace its pending markers. This foundation changes neither public API nor persisted format,
and establishes no throughput or hardware-specific policy.

## Concrete preparation ownership correspondence still required

The unqualified Ada source now constructs an arena-owned canonical mutation body before cohort
selection, while `Prepared_Transaction_View` remains a borrowed extent calculation. Native CPU workers
prepare members and seal cohorts; separate bounded native workers publish immutable batches. The
following ownership boundary still requires executable conformance, formal qualification and matched
performance evidence; source structure alone is not a safety or performance result.

Each independently admitted completion slot must remain the sole owner of its transaction arena.
Preparation borrows that arena under the exact slot generation and constructs one sequence-independent
mutation body of `payload bytes + 14 * mutation count` bytes. The 14-byte prefix is the established
batch-v1 mutation-frame format, not a scheduler parameter. The fragment preserves mutation order and
exact bytes. Arena mutation descriptors, hashes, bucket links, snapshot, point reads and normalized
scan ranges remain isolation evidence; releasing raw payload allocations does not release the arena.
Mutation-byte accessors must continue to return identical bytes from the arena-owned canonical image.

A preparing slot must not remain ordinary `Queued`: existing fence, resolution drain, pipeline abort
and worker-stop paths can immediately make queued slots terminal, and `Await_Result` then transfers
their arena for reclamation. Preparation must instead have explicit borrowed/joining states that all
those paths drain before exposing terminal collection. Installing the completed fragment, retiring raw
allocations and finishing the join form one ownership episode. If raw retirement runs outside the
protected coordinator, the slot stays nonselectable and noncollectible until retirement has joined.
Neither collection nor a reused generation may outrun that cleanup. Failed construction leaves the
original bytes intact; every exceptional/cancelled join must classify the admitted work and release
temporary storage without publishing or leaking a borrower.

Only joined ready members may enter the existing admission-ordered, conflict-compatible cohort prefix.
An older admitted member still preparing blocks selection of younger ready members; readiness does not
reorder admission.
Sequence and predecessor fields are assigned at that freeze, not by transaction preparation. Sealing
copies canonical bodies into one final aggregate, relocates runtime offsets and emits transaction and
batch headers/checksums without repeating body encoding. Batch PUT workers are separate from CPU
preparation so storage latency cannot monopolize the entire preparation pool. Authoritative front
validation, HEAD ordering, coupled publication certainty and per-member receipt identities stay intact.
The existing private profile's finite-deadline restriction is not general deadline qualification.

On exceptional publisher exit, the coordinator halts admission and wakes both worker pools. The
native-task master must join before descriptor-owned batch images are moved out of the coordinator
and released outside its protected lock. Only then may engine-stop classification expose admitted
arenas for collection. This post-join cleanup is not available to a live publisher or worker borrower.

For an implementation with one outstanding preparation/fragment per slot and one current aggregate per
pipeline position, let `Q` be configured admission depth, `M` authenticated per-transaction mutation
capacity, `I` the existing logical in-flight payload cap and `P` configured pipeline depth. Original
payloads stay charged until `Await_Result` transfers their arena out of the admission slot.
Admission-accounted pending extents are raw payload at most `I`,
canonical bodies at most `I + 14*Q*M`, and aggregate images at most
`I + 14*Q*M + 32*Q + 160*P`. The 32-byte transaction prefix and 160-byte batch header/trailer derive
from batch-v1. The aggregate extent covers only images belonging to active pipeline cohorts, including
their temporary worker or publisher ownership. These are checked derivations, not an enforced total
resident-byte admission policy. They exclude arena/lookup descriptors, read/range storage, allocator
overhead, installed-history images and all receipt custody, including internal and collected-but-undelivered
receipts. Preparation's detached raw retirement finishes before the preparation join while admission
credit remains held. Collection instead releases that credit at arena transfer, before outside-lock
arena reclamation; new admissions can therefore overlap collector-owned raw or canonical storage.
Detached collector arenas need separate ownership accounting. A stricter total resident cap requires
an explicit policy and enforcement covering those arenas and retained images, rather than
reinterpreting the logical payload cap.

The concrete conformance lane must cover preparation success/failure, out-of-order ready completion,
retirement-before-collection, fence/resolution/close while a job borrows input, stale generation joins,
ready-prefix conflict ordering, byte backpressure and genuine preparation/publication overlap. The
authority-recovery replay below does not establish those scheduler or byte-ownership properties.

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
