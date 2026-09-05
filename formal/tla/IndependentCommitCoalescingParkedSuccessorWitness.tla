-------- MODULE IndependentCommitCoalescingParkedSuccessorWitness --------
EXTENDS IndependentCommitCoalescing

ParkedSuccessorComplete ==
    /\ lastAction = "ObserveConclusiveSuccessor"
    /\ fenced
    /\ cohort = {}
    /\ visible = {}
    /\ txnState[T1] = "Failed"
    /\ receipt[T1] = "Failed"
    /\ txnState[T2] = "Failed"
    /\ receipt[T2] = "Failed"
    /\ txnState[T4] = "Failed"
    /\ receipt[T4] = "Failed"
    /\ batchPutCalls = 2
    /\ headPutCalls = 1
    /\ resolutionPutCalls = 0

ParkedSuccessorPending == ~ParkedSuccessorComplete

=============================================================================
