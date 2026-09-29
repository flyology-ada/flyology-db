------- MODULE PipelinedAdaptiveAggregateCommitCoalescingWitnesses -------
EXTENDS PipelinedAdaptiveAggregateCommitCoalescing

(***************************************************************************
Negated reachability controls: require the named Pending invariant violation,
not any nonzero status. Fixed submission order reduces witness search only;
the positive safety graph allows arbitrary independent admission order.
No witness is a fairness, liveness, performance, or Ada refinement claim.
***************************************************************************)

SubmitNext ==
    LET t == Len(s.admission) + 1
    IN t \in Transactions /\ Admit(t, 0)
PrepareSuccessNext ==
    \E w \in PrepareWork : StartPrepare(w) \/ CompletePrepare(w, "Success") \/ JoinPrepare(w)
CollectCompletions == \E t \in Transactions : CollectTerminal(t)
DeliverReceipts == \E t \in Transactions : DeliverReceipt(t)
ValidateSuccess == \E c \in Cohorts : ValidateFront(c, TRUE)
BuildNext == SubmitNext \/ Tick \/ Freeze \/ PrepareSuccessNext \/ CollectCompletions
PublishSuccessNext ==
    \/ ValidateSuccess \/ StartHead \/ RetireSuccess(FALSE)
    \/ \E c \in Cohorts : StartBatch(c) \/ StoreBatch(c) \/ CompleteBatch(c, "Success")
         \/ JoinBatch(c) \/ ApplyHead(c) \/ CompleteHead(c, "Success") \/ JoinHead(c)
DrainNext ==
    \/ AbandonPending \/ AbandonSuccessors \/ AbandonSuffix \/ BeginClose \/ DetachUnknown \/ Close
    \/ \E c \in Cohorts : FailPreparedFront(c) \/ DrainAbandoned(c)

OrderedSuccessComplete ==
    /\ s.acknowledged = Transactions /\ s.pipe = <<>> /\ s.pending = <<>>
    /\ s.outOfOrderBatch /\ s.overlappedBatch /\ s.overlappedPrepare /\ s.reusedSlot
    /\ s.staleIgnored /\ s.stalePrepareIgnored /\ ~s.fenced /\ Cardinality(s.published) >= 3
    /\ s.installed = s.head /\ s.resolutionWrites = 0
OrderedSuccessPending == ~OrderedSuccessComplete

PredecessorFailureOrphanComplete ==
    /\ s.closed /\ ~s.online /\ s.pipe = <<>> /\ NoBorrow
    /\ s.stored = {2} /\ s.head = 0 /\ s.acknowledged = {}
    /\ s.excluded = Transactions /\ s.admitted = Transactions
    /\ s.headPuts = [c \in Cohorts |-> 0]
    /\ s.batchPuts[1] = 1 /\ s.batchPuts[2] = 1 /\ s.resolutionWrites = 0
PredecessorFailureOrphanPending == ~PredecessorFailureOrphanComplete

UnknownCloseRecoveryComplete ==
    /\ s.closed /\ s.crashed /\ s.reopened /\ s.online /\ s.pipe = <<>> /\ NoBorrow
    /\ s.head = 1 /\ s.installed = 1 /\ s.stored = {1, 2}
    /\ s.exported = {1} /\ s.imported = {1} /\ s.unknownEpisode /\ s.halted
    /\ Members(1) = {1, 2} /\ Members(2) = {3, 4}
    /\ s.receipt[1] = "Success" /\ s.receipt[2] = "None"
    /\ s.acknowledged = {1} /\ s.excluded = Members(2)
    /\ s.headPuts[1] = 1 /\ s.headPuts[2] = 0 /\ s.resolutionWrites = 0
UnknownCloseRecoveryPending == ~UnknownCloseRecoveryComplete

CancellationLocalFailureComplete ==
    /\ s.closed /\ ~s.online /\ s.localFailure /\ s.fenced /\ NoBorrow
    /\ s.cancelRequested = {1} /\ s.head = 1 /\ s.stored = {1, 2}
    /\ Members(1) = {1, 2} /\ Members(2) = {3, 4}
    /\ s.acknowledged = Members(1) /\ s.excluded = Members(2)
    /\ s.receipt[1] = "Success" /\ s.receipt[2] = "Success"
    /\ s.headPuts[1] = 1 /\ s.headPuts[2] = 0 /\ s.resolutionWrites = 0
CancellationLocalFailurePending == ~CancellationLocalFailureComplete

ActiveUnknownResolutionComplete ==
    /\ s.pipe = <<>> /\ s.pending = <<>> /\ NoBorrow /\ s.head = 1 /\ s.installed = 1
    /\ s.localFailure /\ s.halted /\ s.unknownEpisode /\ s.resolutionToken[1] = "A"
    /\ Members(1) = {1, 2} /\ Members(2) = {3, 4} /\ s.abandonedSuccessors = {2}
    /\ s.receipt[1] = "Success" /\ s.receipt[2] = "Unknown"
    /\ s.receipt[3] = "Failed" /\ s.receipt[4] = "Failed"
    /\ s.acknowledged = {1} /\ s.stored = {1, 2}
    /\ s.headPuts[1] = 1 /\ s.headPuts[2] = 0 /\ s.resolutionWrites = 0
ActiveUnknownResolutionPending == ~ActiveUnknownResolutionComplete

PreparationOverlapComplete ==
    /\ s.overlappedPrepare /\ s.overlappedBatch /\ 2 \in Sealed
    /\ s.batchPuts[1] = 1 /\ s.batchPuts[2] = 1 /\ s.headPuts[2] = 0
PreparationOverlapPending == ~PreparationOverlapComplete
ReadyOutOfOrderComplete == s.ready = <<2, 1>>
ReadyOutOfOrderPending == ~ReadyOutOfOrderComplete
CloseTailComplete ==
    /\ s.closed /\ s.closeTail /\ s.waitTail /\ s.acknowledged = Transactions
    /\ s.excluded = {} /\ NoBorrow
CloseTailPending == ~CloseTailComplete
CloseOverlapComplete ==
    /\ s.closed /\ ~s.online /\ s.closeTail /\ NoBorrow
    /\ Members(1) = {1, 2} /\ Members(2) = {3, 4}
    /\ s.stored = {1, 2} /\ s.head = 2 /\ s.installed = 2
    /\ s.acknowledged = Transactions /\ s.excluded = {}
    /\ s.batchPuts[1] = 1 /\ s.batchPuts[2] = 1
    /\ s.headPuts[1] = 1 /\ s.headPuts[2] = 1
CloseOverlapPending == ~CloseOverlapComplete
ConflictWaitComplete ==
    /\ 3 \in s.conflictWaited \cap s.conflictRejected /\ MemberCohort(3) = 0
    /\ s.receipt[3] = "Failed" /\ s.conflictBasis[3] = 1 /\ 1 \in InstalledChain
ConflictWaitPending == ~ConflictWaitComplete
BoundedBackpressureComplete == s.backpressured /\ s.admitted # Transactions
BoundedBackpressurePending == ~BoundedBackpressureComplete
TerminalSlotsHeldComplete ==
    /\ s.backpressured /\ Cardinality(LiveTransactions) = Depth /\ s.collected = {}
    /\ s.pipe = <<>> /\ s.acknowledged = s.admitted /\ s.admitted # {}
TerminalSlotsHeldPending == ~TerminalSlotsHeldComplete
OversizedSingletonComplete ==
    /\ s.oversizedTail /\ \E c \in Frozen : s.image[c].members = <<2>>
OversizedSingletonPending == ~OversizedSingletonComplete
ByteTailComplete == s.byteTail /\ \E c \in Frozen : Len(s.image[c].members) < MaxWidth
ByteTailPending == ~ByteTailComplete
PrepareFailureComplete ==
    /\ s.closed /\ s.admitted # {} /\ s.excluded = s.admitted /\ NoBorrow
    /\ s.published = {} /\ s.batchPuts = [c \in Cohorts |-> 0]
PrepareFailurePending == ~PrepareFailureComplete
UnknownPreparingTailComplete ==
    /\ UnknownFront /\ SuccessorsDrained /\ s.abandonedSuccessors = {2}
    /\ s.prepareRequest[BatchWork(2)] = "Joined" /\ s.batchPuts[2] = 0
    /\ Members(2) \subseteq s.excluded /\ s.ready = <<>>
UnknownPreparingTailPending == ~UnknownPreparingTailComplete
TightBackpressureCloseComplete ==
    /\ s.backpressured /\ s.closed /\ s.admitted = {} /\ NoBorrow
    /\ ResidentBytes = 0 /\ ReservedBytes = 0
TightBackpressureClosePending == ~TightBackpressureCloseComplete
TightNoAdmission == s.admitted = {}
TightSingletonDrainComplete ==
    /\ s.closed /\ s.admitted = {1} /\ s.acknowledged = {1} /\ NoBorrow
    /\ s.receipt[1] = "Success" /\ s.batchPuts[1] = 1 /\ s.headPuts[1] = 1
TightSingletonDrainPending == ~TightSingletonDrainComplete
TightMultiMemberFreezeComplete ==
    /\ s.admitted = {1, 2} /\ 1 \in Frozen /\ Members(1) = {1, 2}
    /\ s.image[1].bytes = 4 /\ ResidentBytes = 7 /\ ReservedBytes = 7
TightMultiMemberFreezePending == ~TightMultiMemberFreezeComplete


FrontValidationFailureComplete ==
    /\ s.closed /\ s.admitted = Transactions /\ s.excluded = Transactions /\ NoBorrow
    /\ s.stored = {1, 2} /\ s.preHeadFailed = {1} /\ s.projection = 0
    /\ s.validated = {} /\ s.published = {} /\ s.acknowledged = {}
    /\ s.headPuts = [c \in Cohorts |-> 0]
    /\ \A t \in Transactions : s.receipt[t] = "Failed"
FrontValidationFailurePending == ~FrontValidationFailureComplete

LaterPrepareFailureComplete ==
    /\ s.closed /\ s.admitted = Transactions /\ s.collected = Transactions /\ NoBorrow
    /\ Members(1) = {1, 2} /\ Members(2) = {3, 4}
    /\ s.prepareFailed = {2} /\ s.published = {1} /\ s.acknowledged = Members(1)
    /\ s.excluded = Members(2) /\ s.headPuts[1] = 1 /\ s.headPuts[2] = 0
    /\ s.batchPuts[2] = 0 /\ s.projection = 0 /\ s.halted
LaterPrepareFailurePending == ~LaterPrepareFailureComplete

LaterBatchFailureComplete ==
    /\ s.closed /\ s.admitted = Transactions /\ s.collected = Transactions /\ NoBorrow
    /\ Members(1) = {1, 2} /\ Members(2) = {3, 4}
    /\ s.stored = {1} /\ s.published = {1} /\ s.acknowledged = Members(1)
    /\ s.batchRequest[2] = "Joined" /\ s.batchOutcome[2] = "Absent"
    /\ s.excluded = Members(2) /\ s.batchPuts[2] = 1 /\ s.headPuts[2] = 0
    /\ s.projection = 0 /\ s.halted
LaterBatchFailurePending == ~LaterBatchFailureComplete

CollectionBeforeDeliveryComplete ==
    /\ s.closed /\ ~s.online /\ s.admitted = Transactions /\ s.delivered = Transactions
    /\ s.collected = Transactions /\ s.acknowledged = Transactions /\ NoBorrow
CollectionBeforeDeliveryPending == ~CollectionBeforeDeliveryComplete

OrderedSuccessNext ==
    \/ BuildNext \/ PublishSuccessNext
    \/ \E c \in Cohorts : IgnoreStaleCompletion(c) \/ IgnoreStalePrepareCompletion(c)
PredecessorFailureNext ==
    \/ BuildNext \/ DrainNext
    \/ \E c \in {1, 2} : StartBatch(c) \/ StoreBatch(c) \/ JoinBatch(c)
    \/ CompleteBatch(1, "Absent") \/ CompleteBatch(2, "Success")
UnknownCloseRecoveryNext ==
    \/ BuildNext \/ ValidateSuccess \/ StartHead \/ DrainNext
    \/ DeliverReceipts \/ CrashAfterReturn \/ Reopen \/ ExportAuthority(1) \/ ImportAuthority(1)
    \/ ResolveDetachedMember(1)
    \/ \E c \in {1, 2} : StartBatch(c) \/ StoreBatch(c) \/ CompleteBatch(c, "Success")
         \/ JoinBatch(c) \/ ApplyHead(c) \/ CompleteHead(c, "Unknown") \/ JoinHead(c)
CancellationLocalFailureNext ==
    \/ BuildNext \/ RequestCancellation(1) \/ ValidateSuccess \/ StartHead \/ RetireSuccess(TRUE) \/ DrainNext
    \/ \E c \in {1, 2} : StartBatch(c) \/ StoreBatch(c) \/ CompleteBatch(c, "Success")
         \/ JoinBatch(c) \/ ApplyHead(c) \/ CompleteHead(c, "Success") \/ JoinHead(c)
ActiveUnknownResolutionNext ==
    \/ BuildNext \/ DeliverReceipts \/ ValidateSuccess \/ StartHead \/ ObserveFrontResolution(1)
    \/ FinishFrontResolution(TRUE) \/ FinishFrontResolution(FALSE)
    \/ CompleteHead(1, "Unknown") \/ AbandonPending \/ AbandonSuccessors
    \/ \E c \in {1, 2} : StartBatch(c) \/ StoreBatch(c)
         \/ CompleteBatch(c, "Success") \/ JoinBatch(c) \/ ApplyHead(c) \/ JoinHead(c)
         \/ DrainAbandoned(c)
ConflictWaitNext ==
    \/ BuildNext \/ PublishSuccessNext
    \/ WaitForPredecessor(3) \/ RejectQueuedConflict(3)
BackpressureNext == BuildNext \/ (\E t \in Transactions : ObserveBackpressure(t))
PrepareFailureNext ==
    \/ SubmitNext \/ CollectCompletions \/ BeginClose \/ Close
    \/ \E t \in Transactions :
         StartPrepare(TxnWork(t)) \/ CompletePrepare(TxnWork(t), "Failed") \/ JoinPrepare(TxnWork(t))
UnknownPreparingTailNext ==
    \/ BuildNext \/ ValidateSuccess \/ StartHead \/ CompleteHead(1, "Unknown")
    \/ AbandonPending \/ AbandonSuccessors
    \/ StartBatch(1) \/ StoreBatch(1) \/ CompleteBatch(1, "Success")
    \/ JoinBatch(1) \/ ApplyHead(1) \/ JoinHead(1) \/ DrainAbandoned(2)
TightObserveBackpressure(t) ==
    /\ s.online /\ ~s.draining
    /\ ObserveBackpressure(t)
TightBackpressureCloseNext ==
    \/ SubmitNext
    \/ BeginClose \/ Close
    \/ \E t \in Transactions : TightObserveBackpressure(t)
TightSingletonDrainNext ==
    \/ Admit(1, 0) \/ Tick \/ Freeze \/ PrepareSuccessNext \/ PublishSuccessNext
    \/ CollectTerminal(1) \/ BeginClose \/ Close
TightMultiMemberFreezeNext == SubmitNext \/ Tick \/ Freeze \/ PrepareSuccessNext


FrontValidationFailureNext ==
    \/ BuildNext \/ DrainNext
    \/ (s.stored = {1, 2} /\ ValidateFront(1, FALSE))
    \/ \E c \in {1, 2} : StartBatch(c) \/ StoreBatch(c)
         \/ CompleteBatch(c, "Success") \/ JoinBatch(c)

\* Cohort two must fail and join before cohort one's HEAD can start.
LaterPrepareFailureNext ==
    \/ SubmitNext \/ Tick \/ Freeze \/ CollectCompletions \/ DrainNext \/ ValidateSuccess
    \/ \E w \in PrepareWork : StartPrepare(w) \/ JoinPrepare(w)
    \/ \E w \in PrepareWork \ {BatchWork(2)} : CompletePrepare(w, "Success")
    \/ (s.published = {} /\ s.headPuts[1] = 0 /\ CompletePrepare(BatchWork(2), "Failed"))
    \/ (s.prepareRequest[BatchWork(2)] = "Joined" /\ 2 \in s.prepareFailed /\ StartHead)
    \/ StartBatch(1) \/ StoreBatch(1) \/ CompleteBatch(1, "Success") \/ JoinBatch(1)
    \/ ApplyHead(1) \/ CompleteHead(1, "Success") \/ JoinHead(1) \/ RetireSuccess(FALSE)

\* Cohort two's failed batch PUT waits behind cohort one's validated HEAD.
LaterBatchFailureNext ==
    \/ BuildNext \/ DrainNext \/ ValidateFront(1, TRUE)
    \/ \E c \in {1, 2} : StartBatch(c)
    \/ StoreBatch(1) \/ CompleteBatch(1, "Success") \/ JoinBatch(1)
    \/ (s.projection = 1 /\ s.phase[1] = "HeadReady" /\
        s.headPuts[1] = 0 /\ CompleteBatch(2, "Absent"))
    \/ (s.projection = 1 /\ s.phase[1] = "HeadReady" /\
        s.batchOutcome[2] = "Absent" /\ JoinBatch(2))
    \/ (s.batchRequest[2] = "Joined" /\ s.batchOutcome[2] = "Absent" /\ StartHead)
    \/ ApplyHead(1) \/ CompleteHead(1, "Success") \/ JoinHead(1) \/ RetireSuccess(FALSE)

LaterBatchFailureFrontPreserved ==
    (s.batchRequest[2] = "Joined" /\ 1 \notin s.published) =>
      /\ Front = 1 /\ s.projection = 1 /\ ~s.halted
      /\ s.phase[1] \in {"HeadReady", "HeadPending"}

\* Public Finish is deliberately delayed until the database has closed.
CollectionBeforeDeliveryNext ==
    \/ BuildNext \/ PublishSuccessNext \/ BeginClose \/ Close
    \/ (s.closed /\ DeliverReceipts)

OrderedSuccessSpec == Init /\ [][OrderedSuccessNext]_vars
PredecessorFailureSpec == Init /\ [][PredecessorFailureNext]_vars
UnknownCloseRecoverySpec == Init /\ [][UnknownCloseRecoveryNext]_vars
CancellationLocalFailureSpec == Init /\ [][CancellationLocalFailureNext]_vars
ActiveUnknownResolutionSpec == Init /\ [][ActiveUnknownResolutionNext]_vars
PreparationOverlapSpec == Init /\ [][BuildNext \/ PublishSuccessNext]_vars
ReadyOutOfOrderSpec == Init /\ [][BuildNext]_vars
CloseTailSpec == Init /\ [][BuildNext \/ PublishSuccessNext \/ BeginClose \/ Close]_vars
CloseOverlapNext ==
    \/ SubmitNext \/ Tick \/ CollectCompletions \/ BeginClose \/ Close
    \/ (s.draining /\ Freeze)
    \/ PrepareSuccessNext
    \/ \E c \in Cohorts : StartBatch(c) \/ StoreBatch(c)
         \/ CompleteBatch(c, "Success") \/ JoinBatch(c)
         \/ ApplyHead(c) \/ CompleteHead(c, "Success") \/ JoinHead(c)
    \/ (s.stored = {1, 2} /\ ValidateSuccess)
    \/ (s.stored = {1, 2} /\ StartHead)
    \/ RetireSuccess(FALSE)
CloseOverlapSpec == Init /\ [][CloseOverlapNext]_vars
ConflictWaitSpec == Init /\ [][ConflictWaitNext]_vars
BoundedBackpressureSpec == Init /\ [][BackpressureNext]_vars
TerminalSlotsHeldSpec == Init /\ [][BackpressureNext \/ PublishSuccessNext]_vars
OversizedSingletonSpec == Init /\ [][BuildNext]_vars
ByteTailSpec == Init /\ [][BuildNext]_vars
PrepareFailureSpec == Init /\ [][PrepareFailureNext]_vars
UnknownPreparingTailSpec == Init /\ [][UnknownPreparingTailNext]_vars
TightBackpressureCloseSpec == Init /\ [][TightBackpressureCloseNext]_vars
TightSingletonDrainSpec == Init /\ [][TightSingletonDrainNext]_vars
TightMultiMemberFreezeSpec == Init /\ [][TightMultiMemberFreezeNext]_vars
LaterBatchFailureSpec == Init /\ [][LaterBatchFailureNext]_vars
FrontValidationFailureSpec == Init /\ [][FrontValidationFailureNext]_vars
LaterPrepareFailureSpec == Init /\ [][LaterPrepareFailureNext]_vars
CollectionBeforeDeliverySpec == Init /\ [][CollectionBeforeDeliveryNext]_vars
=============================================================================
