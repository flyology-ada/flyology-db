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

UnsafeVisibility ==
    /\ 2 \in s.stored /\ 2 \notin HeadChain
    /\ s' = [s EXCEPT !.acknowledged = @ \cup {3}, !.receipt[3] = "Success",
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
    /\ s' = [s EXCEPT !.validated[2] = {}, !.lastAction = "UnsafeValidationPrefix"]

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
=============================================================================
