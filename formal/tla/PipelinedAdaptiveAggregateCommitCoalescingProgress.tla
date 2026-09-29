-------- MODULE PipelinedAdaptiveAggregateCommitCoalescingProgress --------
EXTENDS PipelinedAdaptiveAggregateCommitCoalescingWitnesses

(***************************************************************************
Conditional finite progress only. Fairness does not become runtime policy.
The successful lane assumes successful responsive providers, successful local
installation, no rival, and enough byte geometry for all retained authority.
Its completion properties concern terminal results, not public receipt delivery.
The close lane permits failure/unknown and assumes responsive joins, fair
coordinator collection; it detaches front authority after draining successors,
without requiring public Finish (DeliverReceipt) or caller resolution.
A permanently stalled provider deliberately refutes progress despite fair preparation/coordinator
actions. No finite timeout or automatic retry/unknown-resolution is invented.
***************************************************************************)

CapacityGeometry == ByteCapacity >= 3 * SumBytes(Transactions) + Cardinality(Cohorts)
ProgressGeometry == ConflictPairs = {} /\ CapacityGeometry
SuccessfulNext == BuildNext \/ PublishSuccessNext
PrepareFairness ==
    \A w \in PrepareWork :
      /\ WF_vars(StartPrepare(w)) /\ WF_vars(CompletePrepare(w, "Success"))
      /\ WF_vars(JoinPrepare(w))
CoordinatorFairness ==
    /\ WF_vars(SubmitNext) /\ WF_vars(Tick) /\ WF_vars(Freeze)
    /\ WF_vars(ValidateSuccess) /\ WF_vars(StartHead) /\ WF_vars(RetireSuccess(FALSE))
    /\ \A t \in Transactions : WF_vars(CollectTerminal(t))
ProviderFairness ==
    \A c \in Cohorts :
      /\ WF_vars(StartBatch(c)) /\ WF_vars(StoreBatch(c))
      /\ WF_vars(CompleteBatch(c, "Success")) /\ WF_vars(JoinBatch(c))
      /\ WF_vars(ApplyHead(c)) /\ WF_vars(CompleteHead(c, "Success")) /\ WF_vars(JoinHead(c))
ProgressSpec ==
    Init /\ ProgressGeometry /\ [][SuccessfulNext]_vars /\
      PrepareFairness /\ CoordinatorFairness /\ ProviderFairness
EverySubmissionCompletes ==
    \A t \in Transactions : (t \in s.admitted) ~> (s.receipt[t] = "Success")
AllSubmissionsComplete == <>(s.acknowledged = Transactions)

RespondValidation(c) == \E success \in BOOLEAN : ValidateFront(c, success)
RespondPrepare(w) == \E outcome \in {"Success", "Failed"} : CompletePrepare(w, outcome)
RespondBatch(c) == \E outcome \in {"Success", "Absent", "Unknown"} : CompleteBatch(c, outcome)
RespondHead(c) == \E outcome \in {"Success", "Rejected", "Unknown"} : CompleteHead(c, outcome)
CloseRetire == \E failure \in BOOLEAN : RetireSuccess(failure)
CloseNext ==
    \/ SubmitNext \/ Tick \/ Freeze \/ StartHead \/ CloseRetire \/ RivalHead
    \/ AbandonPending \/ AbandonSuccessors \/ AbandonSuffix \/ BeginClose \/ DetachUnknown \/ Close
    \/ \E w \in PrepareWork : StartPrepare(w) \/ RespondPrepare(w) \/ JoinPrepare(w)
    \/ \E c \in Cohorts : StartBatch(c) \/ StoreBatch(c) \/ RespondBatch(c)
         \/ JoinBatch(c) \/ ObserveBatch(c) \/ ApplyHead(c) \/ RespondHead(c)
         \/ JoinHead(c) \/ DrainAbandoned(c) \/ RespondValidation(c) \/ FailPreparedFront(c)
    \/ \E t \in Transactions : RejectQueuedConflict(t) \/ RequestCancellation(t) \/ CollectTerminal(t)
CloseFairness ==
    /\ WF_vars(Tick) /\ WF_vars(Freeze) /\ WF_vars(StartHead) /\ WF_vars(CloseRetire)
    /\ WF_vars(BeginClose) /\ WF_vars(AbandonPending) /\ WF_vars(AbandonSuccessors)
    /\ WF_vars(AbandonSuffix) /\ WF_vars(DetachUnknown) /\ WF_vars(Close)
    /\ \A w \in PrepareWork :
         /\ WF_vars(StartPrepare(w)) /\ WF_vars(RespondPrepare(w)) /\ WF_vars(JoinPrepare(w))
    /\ \A c \in Cohorts :
         /\ WF_vars(StartBatch(c)) /\ WF_vars(StoreBatch(c)) /\ WF_vars(RespondBatch(c))
         /\ WF_vars(JoinBatch(c)) /\ WF_vars(ObserveBatch(c)) /\ WF_vars(ApplyHead(c))
         /\ WF_vars(RespondHead(c)) /\ WF_vars(JoinHead(c)) /\ WF_vars(DrainAbandoned(c))
         /\ WF_vars(RespondValidation(c)) /\ WF_vars(FailPreparedFront(c))
    /\ \A t \in Transactions : WF_vars(RejectQueuedConflict(t))
    /\ \A t \in Transactions : WF_vars(CollectTerminal(t))
CloseProgressSpec == Init /\ [][CloseNext]_vars /\ CloseFairness
CloseTerminates == <>s.closed
EveryAdmittedClassified ==
    \A t \in Transactions :
      (t \in s.admitted) ~> (s.receipt[t] \in {"Success", "Failed", "Unknown"})
UnknownSuccessorsDrain ==
    s.unknownEpisode ~> (s.pipe = <<>> \/ SuccessorsDrained)

StalledNext ==
    \/ BuildNext
    \/ \E c \in Cohorts : StartBatch(c) \/ StoreBatch(c)
StalledProviderSpec ==
    /\ Init /\ ProgressGeometry /\ [][StalledNext]_vars
    /\ PrepareFairness /\ WF_vars(SubmitNext) /\ WF_vars(Tick) /\ WF_vars(Freeze)
    /\ \A c \in Cohorts : WF_vars(StartBatch(c)) /\ WF_vars(StoreBatch(c))
=============================================================================
