------------ MODULE AdaptiveAggregateCommitCoalescingProbes ------------
EXTENDS AdaptiveAggregateCommitCoalescing

(***************************************************************************
Each configuration enables one deliberately unsafe action and checks only its
named invariant. These are negative tests, never production Next actions.
***************************************************************************)

UnsafePartialVisibility(member) ==
    /\ s.online /\ s.phase = "Ready"
    /\ Cardinality(ActiveMembers) > 1 /\ member \in ActiveMembers
    /\ s' = [s EXCEPT !.visible = @ \cup {member},
                !.lastAction = "UnsafePartialVisibility"]

UnsafeReplay(member) ==
    /\ s.online /\ s.receipt[member] = "Unknown"
    /\ ExactAuthority(member, s.liveAuthority[member])
    /\ s' = [s EXCEPT !.resolutionWrites = @ + 1,
                !.lastAction = "UnsafeReplay"]

UnsafeCancelFrozen(member) ==
    /\ s.online /\ s.phase \in {"Frozen", "Ready", "HeadAttempted", "Unknown"}
    /\ member \in ActiveMembers
    /\ s' = [s EXCEPT !.txn[member] = "TimedOut", !.receipt[member] = "TimedOut",
          !.deadlineExpired = @ \cup {member}, !.excluded = @ \cup {member},
          !.lastAction = "UnsafeCancelFrozen"]

UnsafeSplitOutcome(member) ==
    /\ s.online /\ s.phase = "HeadAttempted"
    /\ Cardinality(ActiveMembers) > 1 /\ member \in ActiveMembers
    /\ s' = [s EXCEPT !.txn[member] = "Failed", !.receipt[member] = "Failed",
                !.lastAction = "UnsafeSplitOutcome"]

UnsafeAliasNonOldest ==
    /\ s.online /\ s.phase = "Frozen" /\ Len(s.images[s.active].members) > 1
    /\ LET members == s.images[s.active].members
       IN s' = [s EXCEPT
          !.images[s.active].members =
              [index \in 1..Len(members) |->
                  IF index = 1 THEN members[2]
                  ELSE IF index = 2 THEN members[1]
                  ELSE members[index]],
          !.lastAction = "UnsafeAliasNonOldest"]

UnsafeMemberOnlyResolve(member) ==
    /\ s.online /\ s.receipt[member] = "Unknown"
    /\ ExactAuthority(member, s.liveAuthority[member])
    /\ Len(s.liveAuthority[member].image.members) > 1
    /\ LET authority == s.liveAuthority[member]
       IN s' = [s EXCEPT
          !.txn[member] = "Committed", !.receipt[member] = "Committed",
          !.acknowledged = @ \cup {member},
          !.liveAuthority[member].image.members = <<member>>,
          !.lastAction = "UnsafeMemberOnlyResolve"]

UnsafeDropUnknownAuthority(member) ==
    /\ s.online /\ s.receipt[member] = "Unknown"
    /\ ExactAuthority(member, s.liveAuthority[member])
    /\ s' = [s EXCEPT !.liveAuthority[member] = NoAuthority,
                !.lastAction = "UnsafeDropUnknownAuthority"]

UnsafeConsumeCancelledIdentity(member) ==
    /\ s.online /\ s.txn[member] = "Idle" /\ member \notin s.usedTxns
    /\ s' = [s EXCEPT !.usedTxns = @ \cup {member},
                !.lastAction = "UnsafeConsumeCancelledIdentity"]

UnsafeSequenceGap(member) ==
    /\ s.online /\ s.phase = "Frozen" /\ member \in ActiveMembers
    /\ s' = [s EXCEPT !.memberSequence[member] = 0,
                !.lastAction = "UnsafeSequenceGap"]

UnsafeTimeoutWithoutDeadline(member) ==
    /\ s.online /\ member \in Pending /\ member \notin s.deadlineReached
    /\ s' = [s EXCEPT !.txn[member] = "TimedOut",
          !.receipt[member] = "TimedOut", !.queue = Without(@, member),
          !.deadlineExpired = @ \cup {member}, !.excluded = @ \cup {member},
          !.lastAction = "UnsafeTimeoutWithoutDeadline"]

VisibilityProbeSpec ==
    Init /\ [][Next \/ (\E member \in Txns : UnsafePartialVisibility(member))]_vars
ReplayProbeSpec ==
    Init /\ [][Next \/ (\E member \in Txns : UnsafeReplay(member))]_vars
CancellationProbeSpec ==
    Init /\ [][Next \/ (\E member \in Txns : UnsafeCancelFrozen(member))]_vars
SplitOutcomeProbeSpec ==
    Init /\ [][Next \/ (\E member \in Txns : UnsafeSplitOutcome(member))]_vars
AliasProbeSpec == Init /\ [][Next \/ UnsafeAliasNonOldest]_vars
AuthorityProbeSpec ==
    Init /\ [][Next \/ (\E member \in Txns : UnsafeMemberOnlyResolve(member))]_vars
UnknownAuthorityProbeSpec ==
    Init /\ [][Next \/ (\E member \in Txns : UnsafeDropUnknownAuthority(member))]_vars
CancelledIdentityProbeSpec ==
    Init /\ [][Next \/
        (\E member \in Txns : UnsafeConsumeCancelledIdentity(member))]_vars
SequenceProbeSpec ==
    Init /\ [][Next \/ (\E member \in Txns : UnsafeSequenceGap(member))]_vars
DeadlineProbeSpec ==
    Init /\ [][Next \/
        (\E member \in Txns : UnsafeTimeoutWithoutDeadline(member))]_vars

=============================================================================
