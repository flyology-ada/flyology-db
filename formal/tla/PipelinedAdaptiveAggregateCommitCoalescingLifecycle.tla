------- MODULE PipelinedAdaptiveAggregateCommitCoalescingLifecycle -------
EXTENDS PipelinedAdaptiveAggregateCommitCoalescingWitnesses

(***************************************************************************
Focused exhaustive authority lifecycle lane. Two independent members share
one cohort; admission, preparation, publication and a fallible active-front
resolution remain concrete. Collection, public delivery, undelivered discard,
and export/import/drop may interleave with close and returned-authority
crash/reopen. This is not arbitrary process-kill coverage. Full concurrent
admission is covered separately by SafetySpec.
***************************************************************************)

LifecycleSubmit ==
    LET t == Len(s.admission) + 1
    IN t \in {1, 2} /\ Admit(t, 0)
LifecycleNext ==
    \/ LifecycleSubmit \/ Tick \/ Freeze \/ PrepareSuccessNext
    \/ StartHead \/ RivalHead \/ BeginClose \/ AbandonSuffix \/ AbandonPending
    \/ AbandonSuccessors \/ DetachUnknown \/ Close \/ CrashAfterReturn \/ Reopen
    \/ \E failure \in BOOLEAN : RetireSuccess(failure) \/ FinishFrontResolution(failure)
    \/ \E c \in Cohorts : StartBatch(c) \/ StoreBatch(c) \/ JoinBatch(c)
         \/ ObserveBatch(c) \/ ApplyHead(c) \/ JoinHead(c) \/ DrainAbandoned(c) \/ CollectImage(c)
         \/ FailPreparedFront(c)
    \/ \E c \in Cohorts, success \in BOOLEAN : ValidateFront(c, success)
    \/ \E c \in Cohorts, outcome \in {"Success", "Absent", "Unknown"} : CompleteBatch(c, outcome)
    \/ \E c \in Cohorts, outcome \in {"Success", "Rejected", "Unknown"} : CompleteHead(c, outcome)
    \/ \E t \in {1, 2} : RequestCancellation(t) \/ CollectTerminal(t) \/ ObserveFrontResolution(t)
         \/ ResolveDetachedMember(t) \/ ResolveRejected(t)
         \/ DeliverReceipt(t) \/ DiscardCollected(t)
         \/ ExportAuthority(t) \/ ImportAuthority(t) \/ DropReceipt(t)
LifecycleSpec == Init /\ [][LifecycleNext]_vars
=============================================================================
