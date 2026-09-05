----------- MODULE IndependentCommitCoalescingParkedSplitWitness -----------
EXTENDS IndependentCommitCoalescing

ParkedSplitComplete ==
    /\ lastAction = "SplitFailedMember"
    /\ cohort = {T1}
    /\ storedBatches = {T1}
    /\ txnState[T1] = "Frozen"
    /\ batchState[T1] = "Confirmed"
    /\ txnState[T2] = "Failed"
    /\ receipt[T2] = "Failed"
    /\ txnState[T4] = "Parked"
    /\ receipt[T4] = "None"
    /\ memberSequence[T4] = 0
    /\ memberBatch[T4] = NoTxn
    /\ batchPrevious[T4] = NoTxn
    /\ batchState[T4] = "None"
    /\ batchPutCalls = 2
    /\ headPutCalls = 0
    /\ resolutionPutCalls = 0

ParkedSplitPending == ~ParkedSplitComplete

=============================================================================
