----------- MODULE AdaptiveAggregateCommitCoalescingWitnesses -----------
EXTENDS AdaptiveAggregateCommitCoalescing

(***************************************************************************
Each config checks a negated reachability goal. TLC must find the named
Pending invariant false. These finite traces are witnesses, not liveness or
refinement proofs.
***************************************************************************)

TailSuccessComplete ==
    /\ s.lastAction = "ObserveSuccess" /\ s.age[T1] = MaxWait
    /\ s.images[T1].members = <<T1>> /\ s.visible = {T1}
    /\ s.txn[T1] = "Committed" /\ s.receipt[T1] = "Committed"
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1

TailSuccessPending == ~TailSuccessComplete

ByteBoundFreezeComplete ==
    /\ s.lastAction = "FreezeCohort" /\ ~s.draining
    /\ s.age[T1] = 0 /\ s.active = T1 /\ s.images[T1].members = <<T1>>
    /\ s.queue = <<T2>> /\ PayloadBytes[T1] <= MaxBytes
    /\ PayloadBytes[T1] + PayloadBytes[T2] > MaxBytes

ByteBoundFreezePending == ~ByteBoundFreezeComplete

ExactByteTargetComplete ==
    /\ s.lastAction = "FreezeCohort" /\ ~s.draining
    /\ s.age[T2] = 0 /\ s.active = T2 /\ s.queue = <<>>
    /\ s.images[T2].members = <<T2>>
    /\ Len(s.images[T2].members) < MaxWidth /\ s.images[T2].bytes = MaxBytes

ExactByteTargetPending == ~ExactByteTargetComplete

OversizedSingletonComplete ==
    /\ s.lastAction = "ObserveSuccess" /\ s.active = NoTxn
    /\ s.images[T2].members = <<T2>>
    /\ PayloadBytes[T2] > MaxBytes /\ s.images[T2].bytes = PayloadBytes[T2]
    /\ s.txn[T2] = "Committed" /\ s.receipt[T2] = "Committed"
    /\ s.visible = {T2} /\ s.batchPuts[T2] = 1 /\ s.headPuts[T2] = 1

OversizedSingletonPending == ~OversizedSingletonComplete

QueuedExpiryComplete ==
    /\ s.lastAction = "ExpireQueued" /\ s.deadlineExpired = {T1}
    /\ s.txn[T1] = "TimedOut" /\ s.receipt[T1] = "TimedOut"
    /\ s.batchPuts = [t \in Txns |-> 0] /\ s.headPuts = [t \in Txns |-> 0]

QueuedExpiryPending == ~QueuedExpiryComplete

CancellationResolutionComplete ==
    /\ s.lastAction = "ResolveMember" /\ s.cancelRequested = {T1}
    /\ s.images[T1].members = <<T1, T2>> /\ s.visible = {T1, T2}
    /\ s.txn[T1] = "Committed" /\ s.receipt[T1] = "Committed"
    /\ s.txn[T2] = "Unknown" /\ s.receipt[T2] = "Unknown"
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1 /\ s.resolutionWrites = 0

CancellationResolutionPending == ~CancellationResolutionComplete

PreconditionRejectionComplete ==
    /\ s.lastAction = "HeadPreconditionRejected" /\ s.fenced
    /\ s.images[T1].members = <<T1, T2>>
    /\ s.txn[T1] = "Failed" /\ s.txn[T2] = "Failed"
    /\ s.receipt[T1] = "Failed" /\ s.receipt[T2] = "Failed"
    /\ s.visible = {} /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1

PreconditionRejectionPending == ~PreconditionRejectionComplete

RejectedMemberResolutionComplete ==
    /\ s.lastAction = "ResolveRejected" /\ s.fenced
    /\ s.images[T1].members = <<T1, T2>> /\ s.visible = {}
    /\ s.txn[T1] = "Failed" /\ s.txn[T2] = "Failed"
    /\ s.receipt[T1] = "Failed" /\ s.receipt[T2] = "Unknown"
    /\ s.liveAuthority[T1] = NoAuthority
    /\ ExactAuthority(T2, s.liveAuthority[T2])
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1 /\ s.resolutionWrites = 0

RejectedMemberResolutionPending == ~RejectedMemberResolutionComplete

AuthorityRecoveryComplete ==
    /\ s.lastAction = "ResolveMember" /\ s.crashed /\ s.reopened
    /\ s.images[T1].members = <<T1, T2>> /\ s.visible = {T1, T2}
    /\ s.recovered = {T1, T2}
    /\ s.receipt[T1] = "Committed" /\ s.receipt[T2] = "Unknown"
    /\ ExactAuthority(T1, s.durableAuthority[T1])
    /\ ExactAuthority(T2, s.durableAuthority[T2])
    /\ ExactAuthority(T2, s.liveAuthority[T2])
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1 /\ s.resolutionWrites = 0

AuthorityRecoveryPending == ~AuthorityRecoveryComplete

PreAdmissionCancellationComplete ==
    /\ s.lastAction = "CancelBeforeAdmission" /\ s.txn[T1] = "Idle"
    /\ T1 \notin s.usedTxns /\ s.queue = <<>>
    /\ s.batchPuts = [t \in Txns |-> 0] /\ s.headPuts = [t \in Txns |-> 0]

PreAdmissionCancellationPending == ~PreAdmissionCancellationComplete

CrashBeforeHeadEntryRecoveryComplete ==
    /\ s.lastAction = "ReopenFromHead" /\ s.crashed /\ s.reopened
    /\ s.images[T1].members = <<T1, T2>> /\ T1 \in s.stored
    /\ s.visible = {} /\ s.recovered = {} /\ s.headBatch = NoTxn
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1

CrashBeforeHeadEntryRecoveryPending == ~CrashBeforeHeadEntryRecoveryComplete

CrashAfterHeadEntryRecoveryComplete ==
    /\ s.lastAction = "ReopenFromHead" /\ s.crashed /\ s.reopened
    /\ s.images[T1].members = <<T1, T2>> /\ s.headBatch = T1
    /\ s.visible = {T1, T2} /\ s.recovered = {T1, T2}
    /\ s.memberBatch[T1] = T1 /\ s.memberBatch[T2] = T1
    /\ s.memberSequence[T1] = 1 /\ s.memberSequence[T2] = 2
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1

CrashAfterHeadEntryRecoveryPending == ~CrashAfterHeadEntryRecoveryComplete

LocalInstallFailureComplete ==
    /\ s.lastAction = "ObserveLocalInstallFailure" /\ s.fenced
    /\ s.images[T1].members = <<T1, T2>>
    /\ s.visible = {T1, T2} /\ s.acknowledged = {T1, T2}
    /\ s.txn[T1] = "Committed" /\ s.txn[T2] = "Committed"
    /\ s.txn[T3] = "Failed" /\ s.receipt[T3] = "Failed"
    /\ s.excluded = {T3} /\ s.queue = <<>> /\ s.active = NoTxn
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1

LocalInstallFailurePending == ~LocalInstallFailureComplete

UnknownCloseRecoveryComplete ==
    /\ s.lastAction = "ResolveMember" /\ ~s.draining /\ s.reopened
    /\ s.closedHead = T1 /\ s.closedUnknown = T1
    /\ s.closedPending = {T3}
    /\ s.images[T1].members = <<T1, T2>> /\ s.visible = {T1, T2}
    /\ s.txn[T1] = "Committed" /\ s.receipt[T1] = "Committed"
    /\ s.txn[T2] = "Unknown" /\ s.receipt[T2] = "Unknown"
    /\ s.txn[T3] = "Failed" /\ s.receipt[T3] = "Failed"
    /\ s.excluded = {T3} /\ s.queue = <<>> /\ s.active = NoTxn
    /\ ExactAuthority(T2, s.liveAuthority[T2])
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1 /\ s.resolutionWrites = 0

UnknownCloseRecoveryPending == ~UnknownCloseRecoveryComplete

ReopenAdmissionComplete ==
    /\ s.lastAction = "ObserveSuccess" /\ ~s.draining /\ s.reopened
    /\ s.closedHead = T1 /\ s.closedUnknown = NoTxn
    /\ s.images[T1].members = <<T1>> /\ s.images[T2].members = <<T2>>
    /\ s.headBatch = T2 /\ s.visible = {T1, T2}
    /\ s.txn[T1] = "Committed" /\ s.txn[T2] = "Committed"
    /\ s.batchPuts[T1] = 1 /\ s.headPuts[T1] = 1
    /\ s.batchPuts[T2] = 1 /\ s.headPuts[T2] = 1

ReopenAdmissionPending == ~ReopenAdmissionComplete

=============================================================================
