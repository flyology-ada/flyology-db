--------- MODULE PipelinedAdaptiveAggregateCommitCoalescingProbes ---------
EXTENDS PipelinedAdaptiveAggregateCommitCoalescing

(***************************************************************************
Each configuration adds exactly one unsafe transition family and names its
intended invariant. These are source-only negative controls, not Next actions
or evidence that any counterexample has yet been generated.
***************************************************************************)

UnsafeHeadOrder ==
    /\ s.pipe = <<1, 2>> /\ s.phase[2] = "Ready" /\ s.headPuts[2] = 0
    /\ 1 \notin s.published
    /\ s' = [s EXCEPT !.headPuts[2] = 1, !.lastAction = "UnsafeHeadOrder"]

UnsafeHeadWithoutValidation ==
    /\ Front # 0 /\ s.phase[Front] = "Ready" /\ Front \notin s.validated
    /\ s.headPuts[Front] = 0
    /\ s' = [s EXCEPT !.headPuts[Front] = 1, !.lastAction = "UnsafeHeadWithoutValidation"]

UnsafeSuccessorProjectionRelease ==
    /\ Front # 0 /\ s.projection = Front
    /\ \E c \in PipeSet \ {Front} : s.phase[c] = "PrepareFailed"
    /\ s' = [s EXCEPT !.projection = 0, !.lastAction = "UnsafeSuccessorProjectionRelease"]

UnsafeExportUndelivered(t) ==
    /\ t \in s.collected \ (s.delivered \cup s.dropped) /\ s.receipt[t] = "Unknown"
    /\ s' = [s EXCEPT !.exported = @ \cup {t}, !.lastAction = "UnsafeExportUndelivered"]

UnsafeVisibility ==
    /\ 2 \in s.stored /\ 2 \notin HeadChain
    /\ LET t == Head(s.image[2].members)
       IN s' = [s EXCEPT !.acknowledged = @ \cup {t}, !.receipt[t] = "Success",
                         !.lastAction = "UnsafeVisibility"]

UnsafeUnknownBarrier ==
    /\ s.pipe = <<1, 2>> /\ s.phase[1] = "Unknown" /\ s.phase[2] = "Ready"
    /\ s' = [s EXCEPT !.headPuts[2] = 1, !.lastAction = "UnsafeUnknownBarrier"]

UnsafeReplay ==
    /\ \E t \in Transactions : s.receipt[t] = "Unknown"
    /\ s' = [s EXCEPT !.resolutionWrites = @ + 1, !.lastAction = "UnsafeReplay"]

UnsafeRebase ==
    /\ 2 \in Frozen /\ s.image[2].previous = 1 /\ 2 \in s.stored
    /\ s' = [s EXCEPT !.image[2].previous = 0, !.lastAction = "UnsafeRebase"]

UnsafeReleaseBorrowed(c) ==
    /\ c \in BatchBorrowed \cup HeadBorrowed
    /\ s' = [s EXCEPT !.allocated = @ \ {c}, !.lastAction = "UnsafeReleaseBorrowed"]

UnsafeStaleCompletion ==
    /\ s.slotOwner[Slot(1)] = 3 /\ s.batchRequest[1] = "Joined"
    /\ s' = [s EXCEPT !.slotOwner[Slot(1)] = 0, !.lastAction = "UnsafeStaleCompletion"]

UnsafeValidationPrefix ==
    /\ 2 \in Frozen /\ s.image[2].previous = 1
    /\ s' = [s EXCEPT !.validationPrefix[2] = {}, !.lastAction = "UnsafeValidationPrefix"]

UnsafeForgetResolutionToken(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \notin s.dropped
    /\ MemberCohort(t) = Front /\ MemberCohort(t) \in HeadChain /\ ~s.rival
    /\ UnknownFront /\ s.resolvingMember[Front] = 0
    /\ s' = [s EXCEPT !.phase[Front] = "ResolutionReady",
          !.resolvingMember[Front] = t,
          !.lastAction = "UnsafeForgetResolutionToken"]

UnsafePrematureResolutionSuccess(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \notin s.dropped
    /\ MemberCohort(t) = Front /\ UnknownFront /\ Front \in HeadChain
    /\ s' = [s EXCEPT !.receipt[t] = "Success", !.acknowledged = @ \cup {t},
          !.lastAction = "UnsafePrematureResolutionSuccess"]

UnsafeDetachedResolutionSuccess(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \notin s.dropped
    /\ MemberCohort(t) \in HeadChain \ InstalledChain
    /\ MemberCohort(t) \notin PipeSet
    /\ s' = [s EXCEPT !.receipt[t] = "Success", !.acknowledged = @ \cup {t},
          !.resolved = @ \cup {MemberCohort(t)},
          !.lastAction = "UnsafeDetachedResolutionSuccess"]

UnsafeDropResolvingMember ==
    /\ ResolutionReadyFront
    /\ LET t == s.resolvingMember[Front]
       IN s' = [s EXCEPT !.dropped = @ \cup {t}, !.receipt[t] = "None",
                         !.lastAction = "UnsafeDropResolvingMember"]

UnsafeUnpreparedFragment(c) ==
    /\ c \in Frozen
    /\ s' = [s EXCEPT !.fragment[Head(s.image[c].members)] = 0,
                      !.lastAction = "UnsafeUnpreparedFragment"]

UnsafeUnsealedBatch(c) ==
    /\ c \in PipeSet /\ s.phase[c] = "Frozen" /\ c \notin Sealed
    /\ s' = [s EXCEPT !.batchPuts[c] = 1, !.lastAction = "UnsafeUnsealedBatch"]

UnsafeMemberReceipt(c) ==
    /\ c \in Frozen
    /\ s' = [s EXCEPT !.memberSequence[Head(s.image[c].members)] = 0,
                      !.lastAction = "UnsafeMemberReceipt"]

UnsafeAdmissionOrder ==
    /\ Len(s.pending) >= 2
    /\ s' = [s EXCEPT !.pending = <<s.pending[2], s.pending[1]>> \o
              SubSeq(s.pending, 3, Len(s.pending)), !.lastAction = "UnsafeAdmissionOrder"]

UnsafeConflictRejection(t) ==
    /\ t \in Pending /\ UnpublishedConflict(t) /\ ~CommittedConflict(t)
    /\ s' = [s EXCEPT !.conflictRejected = @ \cup {t}, !.excluded = @ \cup {t},
          !.lastAction = "UnsafeConflictRejection"]

UnsafeReleasePrepare(t) ==
    /\ t \in TxnBorrowed
    /\ s' = [s EXCEPT !.inputOwned = @ \ {t}, !.lastAction = "UnsafeReleasePrepare"]

UnsafeReadyBeforeJoin(c) ==
    /\ c \in PipeSet \ ReadySet /\ BatchWork(c) \in PrepareBorrowed
    /\ s' = [s EXCEPT !.ready = Append(@, c), !.lastAction = "UnsafeReadyBeforeJoin"]

UnsafePrepareCapacity(w) ==
    /\ Cardinality(PrepareBorrowed) = PrepareCapacity /\ w \notin PrepareBorrowed
    /\ s' = [s EXCEPT !.prepareRequest[w] = "InFlight", !.lastAction = "UnsafePrepareCapacity"]

UnsafeByteCapacity(t) ==
    /\ t \notin s.fragmentAllocated /\ ResidentBytes + TxnBytes[t] > ByteCapacity
    /\ s' = [s EXCEPT !.fragmentAllocated = @ \cup {t}, !.lastAction = "UnsafeByteCapacity"]

UnsafeResolveBeforeSuccessorDrain(t) ==
    /\ UnknownFront /\ ~SuccessorsDrained /\ t \in Members(Front) /\ Front \in HeadChain
    /\ s' = [s EXCEPT !.phase[Front] = "ResolutionReady",
          !.resolvingMember[Front] = t, !.resolutionToken[Front] = s.headToken,
          !.lastAction = "UnsafeResolveBeforeSuccessorDrain"]

UnsafeResumeUnknownEpisode ==
    /\ s.unknownEpisode /\ s.pipe = <<>> /\ s.halted
    /\ s' = [s EXCEPT !.halted = FALSE, !.lastAction = "UnsafeResumeUnknownEpisode"]

UnsafeCloseBeforePrepareJoin ==
    /\ s.draining /\ PrepareBorrowed # {}
    /\ s' = [s EXCEPT !.online = FALSE, !.lastAction = "UnsafeCloseBeforePrepareJoin"]

UnsafeEarlyCollection(t) ==
    /\ t \in Pending
    /\ s' = [s EXCEPT !.collected = @ \cup {t}, !.lastAction = "UnsafeEarlyCollection"]

UnsafeTerminalSlotReuse(t) ==
    /\ Cardinality(LiveTransactions) = Depth /\ t \in Transactions \ s.admitted
    /\ \E other \in LiveTransactions : s.receipt[other] \in {"Success", "Failed", "Unknown"}
    /\ s' = [s EXCEPT !.admitted = @ \cup {t}, !.lastAction = "UnsafeTerminalSlotReuse"]

HeadOrderProbeSpec == Init /\ [][Next \/ UnsafeHeadOrder]_vars
VisibilityProbeSpec == Init /\ [][Next \/ UnsafeVisibility]_vars
UnknownBarrierProbeSpec == Init /\ [][Next \/ UnsafeUnknownBarrier]_vars
ReplayProbeSpec == Init /\ [][Next \/ UnsafeReplay]_vars
RebaseProbeSpec == Init /\ [][Next \/ UnsafeRebase]_vars
OwnershipProbeSpec ==
    Init /\ [][Next \/ (\E c \in Cohorts : UnsafeReleaseBorrowed(c))]_vars
StaleCompletionProbeSpec == Init /\ [][Next \/ UnsafeStaleCompletion]_vars
ValidationProbeSpec == Init /\ [][Next \/ UnsafeValidationPrefix]_vars
ResolutionTokenProbeSpec ==
    Init /\ [][Next \/ (\E t \in Transactions : UnsafeForgetResolutionToken(t))]_vars
ResolutionOrderProbeSpec ==
    Init /\ [][Next \/ (\E t \in Transactions : UnsafePrematureResolutionSuccess(t))]_vars
DetachedResolutionProbeSpec ==
    Init /\ [][Next \/ (\E t \in Transactions : UnsafeDetachedResolutionSuccess(t))]_vars
ResolutionOwnershipProbeSpec == Init /\ [][Next \/ UnsafeDropResolvingMember]_vars
FragmentProbeSpec ==
    Init /\ [][Next \/ (\E c \in Cohorts : UnsafeUnpreparedFragment(c))]_vars
SealProbeSpec == Init /\ [][Next \/ (\E c \in Cohorts : UnsafeUnsealedBatch(c))]_vars
MemberReceiptProbeSpec == Init /\ [][Next \/ (\E c \in Cohorts : UnsafeMemberReceipt(c))]_vars
AdmissionOrderProbeSpec == Init /\ [][Next \/ UnsafeAdmissionOrder]_vars
ConflictProbeSpec == Init /\ [][Next \/ (\E t \in Transactions : UnsafeConflictRejection(t))]_vars
PrepareOwnershipProbeSpec ==
    Init /\ [][Next \/ (\E t \in Transactions : UnsafeReleasePrepare(t))]_vars
ReadyQueueProbeSpec == Init /\ [][Next \/ (\E c \in Cohorts : UnsafeReadyBeforeJoin(c))]_vars
PrepareBoundProbeSpec ==
    Init /\ [][Next \/ (\E w \in PrepareWork : UnsafePrepareCapacity(w))]_vars
ByteBoundProbeSpec == Init /\ [][Next \/ (\E t \in Transactions : UnsafeByteCapacity(t))]_vars
SuccessorDrainProbeSpec ==
    Init /\ [][Next \/ (\E t \in Transactions : UnsafeResolveBeforeSuccessorDrain(t))]_vars
EpisodeProbeSpec == Init /\ [][Next \/ UnsafeResumeUnknownEpisode]_vars
PrepareCloseProbeSpec == Init /\ [][Next \/ UnsafeCloseBeforePrepareJoin]_vars
CompletionOwnershipProbeSpec ==
    Init /\ [][Next \/ (\E t \in Transactions : UnsafeEarlyCollection(t))]_vars
CompletionBoundProbeSpec ==
    Init /\ [][Next \/ (\E t \in Transactions : UnsafeTerminalSlotReuse(t))]_vars
HeadValidationProbeSpec == Init /\ [][Next \/ UnsafeHeadWithoutValidation]_vars
ProjectionOwnershipProbeSpec == Init /\ [][Next \/ UnsafeSuccessorProjectionRelease]_vars
ReceiptDeliveryProbeSpec ==
    Init /\ [][Next \/ (\E t \in Transactions : UnsafeExportUndelivered(t))]_vars
=============================================================================
