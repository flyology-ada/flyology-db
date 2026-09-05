------- MODULE IndependentCommitCoalescingCohortFailureWitness -------
EXTENDS IndependentCommitCoalescing

CohortFailureComplete ==
    /\ lastAction = "FailFrozenCohort"
    /\ cohort = {}
    /\ headState = "Collecting"
    /\ ~headAttemptEntered
    /\ txnState[T1] = "Failed"
    /\ receipt[T1] = "Failed"
    /\ txnState[T2] = "Failed"
    /\ receipt[T2] = "Failed"
    /\ storedBatches = {T1}
    /\ visible = {}
    /\ batchPutCalls = 2
    /\ headPutCalls = 0
    /\ resolutionPutCalls = 0

CohortFailurePending == ~CohortFailureComplete

=============================================================================
