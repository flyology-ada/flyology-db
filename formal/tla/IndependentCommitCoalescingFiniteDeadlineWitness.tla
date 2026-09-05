------- MODULE IndependentCommitCoalescingFiniteDeadlineWitness -------
EXTENDS IndependentCommitCoalescing

FiniteDeadlineComplete ==
    /\ lastAction = "RejectFiniteDeadline"
    /\ txnState[T3] = "Unsupported"
    /\ T3 \notin cohort
    /\ memberBatch[T3] = NoTxn
    /\ batchState[T3] = "None"
    /\ batchPutCalls = 0
    /\ headPutCalls = 0
    /\ resolutionPutCalls = 0

FiniteDeadlinePending == ~FiniteDeadlineComplete

=============================================================================
