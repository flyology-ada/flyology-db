------------------ MODULE AggregateCommitCoalescingWitnesses ------------------
EXTENDS AggregateCommitCoalescing

(***************************************************************************
Each witness config intentionally checks a negated reachability goal. TLC must
find the named Pending invariant false; this supplies a finite execution for
later implementation replay, not a liveness theorem.
***************************************************************************)

AuthorityRecoveryComplete ==
    /\ s.lastAction = "ResolveMember" /\ s.crashed /\ s.reopened
    /\ s.visible = {T1, T2} /\ s.recovered = {T1, T2}
    /\ s.receipt[T1] = "Committed" /\ s.receipt[T2] = "Unknown"
    /\ s.memberBatch[T1] = B1 /\ s.memberBatch[T2] = B1
    /\ ExactAuthority(T1, s.durableAuthority[T1])
    /\ ExactAuthority(T2, s.durableAuthority[T2])
    /\ ExactAuthority(T2, s.liveAuthority[T2])
    /\ s.durableAuthority[T1].image = s.durableAuthority[T2].image
    /\ AsSet(s.durableAuthority[T1].image.members) = {T1, T2}
    /\ s.batchPuts = [b \in BatchIDs |-> IF b = B1 THEN 1 ELSE 0]
    /\ s.headPuts = [b \in BatchIDs |-> IF b = B1 THEN 1 ELSE 0]
    /\ s.resolutionWrites = 0

AuthorityRecoveryPending == ~AuthorityRecoveryComplete

ConfirmedOrphanComplete ==
    /\ s.lastAction = "ProbeConfirmedOrphanCollision" /\ s.crashed /\ s.reopened
    /\ s.stored = {B1} /\ s.published = {} /\ s.headBatch = NoBatch
    /\ s.visible = {} /\ s.recovered = {} /\ s.highest = 0
    /\ s.orphanProbed = {B1} /\ s.orphanRejected = {B1} /\ s.fenced
    /\ s.batchPuts = [b \in BatchIDs |-> IF b = B1 THEN 1 ELSE 0]
    /\ s.headPuts = [b \in BatchIDs |-> 0] /\ s.resolutionWrites = 0

ConfirmedOrphanPending == ~ConfirmedOrphanComplete

MissingIdentityComplete ==
    /\ s.lastAction = "ObserveMissingIdentityBoundary" /\ s.crashed /\ s.reopened
    /\ s.usedBatches = {B1} /\ s.stored = {} /\ s.localBatchIDs = {}
    /\ s.headBatch = NoBatch /\ s.visible = {} /\ s.recovered = {}
    /\ s.missingBoundary = {B1}
    /\ s.batchPuts = [b \in BatchIDs |-> IF b = B1 THEN 1 ELSE 0]
    /\ s.headPuts = [b \in BatchIDs |-> 0] /\ s.resolutionWrites = 0

MissingIdentityPending == ~MissingIdentityComplete

=============================================================================
