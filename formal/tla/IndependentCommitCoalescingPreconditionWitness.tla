------- MODULE IndependentCommitCoalescingPreconditionWitness -------
EXTENDS IndependentCommitCoalescing

PreconditionComplete ==
    /\ lastAction = "ObserveHeadPreconditionFailure"
    /\ fenced
    /\ cohort = {}
    /\ visible = {}
    /\ txnState[T1] = "Failed"
    /\ receipt[T1] = "Failed"
    /\ txnState[T2] = "Failed"
    /\ receipt[T2] = "Failed"
    /\ batchPutCalls = 2
    /\ headPutCalls = 1
    /\ resolutionPutCalls = 0

PreconditionPending == ~PreconditionComplete

=============================================================================
