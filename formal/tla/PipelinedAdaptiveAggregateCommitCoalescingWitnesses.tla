------- MODULE PipelinedAdaptiveAggregateCommitCoalescingWitnesses -------
EXTENDS PipelinedAdaptiveAggregateCommitCoalescing

(***************************************************************************
Five negated reachability predicates. A maintained runner must require
the intended Pending invariant violation, not merely a nonzero tool status.
No canonical trace, Ada replay, fairness, or liveness claim is added here.
***************************************************************************)

OrderedSuccessComplete ==
    /\ s.published = Cohorts /\ s.acknowledged = Transactions /\ s.pipe = <<>>
    /\ s.outOfOrderBatch /\ s.overlappedBatch /\ s.reusedSlot /\ s.staleIgnored /\ ~s.fenced
    /\ s.installed = 3 /\ s.batchPuts = [c \in Cohorts |-> 1]
    /\ s.headPuts = [c \in Cohorts |-> 1] /\ s.resolutionWrites = 0
OrderedSuccessPending == ~OrderedSuccessComplete

PredecessorFailureOrphanComplete ==
    /\ s.closed /\ ~s.online /\ s.pipe = <<>> /\ NoBorrow
    /\ s.stored = {2} /\ s.head = 0 /\ s.acknowledged = {}
    /\ s.excluded = Members(1) \cup Members(2)
    /\ s.headPuts = [c \in Cohorts |-> 0]
    /\ s.batchPuts[1] = 1 /\ s.batchPuts[2] = 1 /\ s.resolutionWrites = 0
PredecessorFailureOrphanPending == ~PredecessorFailureOrphanComplete

UnknownCloseRecoveryComplete ==
    /\ s.closed /\ s.crashed /\ s.reopened /\ s.online /\ s.pipe = <<>> /\ NoBorrow
    /\ s.head = 1 /\ s.installed = 1 /\ s.stored = {1, 2}
    /\ s.exported = {1} /\ s.imported = {1}
    /\ s.receipt[1] = "Success" /\ s.receipt[2] = "None"
    /\ s.acknowledged = {1} /\ s.excluded = Members(2)
    /\ s.headPuts[1] = 1 /\ s.headPuts[2] = 0 /\ s.resolutionWrites = 0
UnknownCloseRecoveryPending == ~UnknownCloseRecoveryComplete

CancellationLocalFailureComplete ==
    /\ s.closed /\ ~s.online /\ s.localFailure /\ s.fenced /\ NoBorrow
    /\ s.cancelRequested = {1} /\ s.head = 1 /\ s.stored = {1, 2}
    /\ s.acknowledged = Members(1) /\ s.excluded = Members(2)
    /\ s.receipt[1] = "Success" /\ s.receipt[2] = "Success"
    /\ s.headPuts[1] = 1 /\ s.headPuts[2] = 0 /\ s.resolutionWrites = 0
CancellationLocalFailurePending == ~CancellationLocalFailureComplete

ActiveUnknownResolutionComplete ==
    /\ s.pipe = <<>> /\ s.head = 2 /\ s.installed = 2 /\ s.installedToken = "B"
    /\ s.localFailure /\ s.outOfOrderBatch /\ s.overlappedBatch
    /\ ~s.fenced /\ ~s.halted /\ s.resolutionToken[1] = "A"
    /\ s.receipt[1] = "Success" /\ s.receipt[2] = "Unknown"
    /\ s.receipt[3] = "Success" /\ s.receipt[4] = "Success"
    /\ s.acknowledged = {1, 3, 4} /\ s.stored = {1, 2}
    /\ s.batchPuts = [c \in Cohorts |-> IF c \in {1, 2} THEN 1 ELSE 0]
    /\ s.headPuts = [c \in Cohorts |-> IF c \in {1, 2} THEN 1 ELSE 0]
    /\ s.resolutionWrites = 0
ActiveUnknownResolutionPending == ~ActiveUnknownResolutionComplete

OrderedSuccessNext ==
    \/ Freeze \/ StartHead \/ (\E failure \in {FALSE} : RetireSuccess(failure))
    \/ \E c \in Cohorts : StartBatch(c) \/ StoreBatch(c) \/ CompleteBatch(c, "Success")
         \/ JoinBatch(c) \/ ApplyHead(c) \/ CompleteHead(c, "Success") \/ JoinHead(c)
         \/ IgnoreStaleCompletion(c)

PredecessorFailureNext ==
    \/ Freeze \/ AbandonSuffix \/ BeginClose \/ DrainAbandoned \/ Close
    \/ \E c \in 1..2 : StartBatch(c) \/ StoreBatch(c) \/ JoinBatch(c)
    \/ CompleteBatch(1, "Absent") \/ CompleteBatch(2, "Success")

UnknownCloseRecoveryNext ==
    \/ Freeze \/ StartHead \/ BeginClose \/ DrainAbandoned \/ DetachUnknown \/ Close
    \/ CrashAfterReturn \/ Reopen \/ ExportAuthority(1) \/ ImportAuthority(1)
    \/ ResolveDetachedMember(1)
    \/ \E c \in 1..2 : StartBatch(c) \/ StoreBatch(c) \/ CompleteBatch(c, "Success")
         \/ JoinBatch(c) \/ ApplyHead(c) \/ CompleteHead(c, "Unknown") \/ JoinHead(c)

CancellationLocalFailureNext ==
    \/ Freeze \/ RequestCancellation(1) \/ StartHead \/ RetireSuccess(TRUE)
    \/ AbandonSuffix \/ BeginClose \/ DrainAbandoned \/ Close
    \/ \E c \in 1..2 : StartBatch(c) \/ StoreBatch(c) \/ CompleteBatch(c, "Success")
         \/ JoinBatch(c) \/ ApplyHead(c) \/ CompleteHead(c, "Success") \/ JoinHead(c)

ActiveUnknownResolutionNext ==
    \/ Freeze \/ StartHead \/ ObserveFrontResolution(1) \/ RetireSuccess(FALSE)
    \/ FinishFrontResolution(TRUE) \/ FinishFrontResolution(FALSE)
    \/ CompleteHead(1, "Unknown") \/ CompleteHead(2, "Success")
    \/ \E c \in {1, 2} : StartBatch(c) \/ StoreBatch(c)
         \/ CompleteBatch(c, "Success") \/ JoinBatch(c) \/ ApplyHead(c) \/ JoinHead(c)

OrderedSuccessSpec == Init /\ [][OrderedSuccessNext]_vars
PredecessorFailureSpec == Init /\ [][PredecessorFailureNext]_vars
UnknownCloseRecoverySpec == Init /\ [][UnknownCloseRecoveryNext]_vars
CancellationLocalFailureSpec == Init /\ [][CancellationLocalFailureNext]_vars
ActiveUnknownResolutionSpec == Init /\ [][ActiveUnknownResolutionNext]_vars
=============================================================================
