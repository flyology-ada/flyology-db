--------------- MODULE AdaptiveAggregateCommitCoalescingProgress ---------------
EXTENDS AdaptiveAggregateCommitCoalescing

(***************************************************************************
Conditional bounded progress lane. It assumes a successful provider, no
deadline expiry, conflict, rival writer, crash, lost response, or local
installation failure. MaxWait counts abstract scheduler ticks; it is not a
wall-clock latency bound or product default. Safety remains in the failure-
inclusive parent model and its TLAPS kernel.
***************************************************************************)

ProgressNext ==
    \/ \E t \in Txns : Admit(t) \/ RequestCancellation(t)
    \/ Tick
    \/ FreezeCohort
    \/ PublishAggregate("Confirmed")
    \/ BeginHeadAttempt
    \/ HeadAccepted
    \/ ObserveSuccess

ProgressSpec ==
    /\ Init
    /\ [][ProgressNext]_vars
    /\ WF_vars(Tick)
    /\ WF_vars(FreezeCohort)
    /\ WF_vars(PublishAggregate("Confirmed"))
    /\ WF_vars(BeginHeadAttempt)
    /\ WF_vars(HeadAccepted)
    /\ WF_vars(ObserveSuccess)

AdmittedEventuallyAcknowledged ==
    \A t \in Txns : t \in s.usedTxns ~> t \in s.acknowledged

=============================================================================
