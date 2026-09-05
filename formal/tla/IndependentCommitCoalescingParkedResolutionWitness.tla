------- MODULE IndependentCommitCoalescingParkedResolutionWitness -------
EXTENDS IndependentCommitCoalescing

VARIABLE parkedResolutionObserved

witnessVars == <<vars, parkedResolutionObserved>>

WitnessInit == Init /\ parkedResolutionObserved = FALSE

ObserveParkedResolution ==
    /\ T1 \in cohort
    /\ txnState[T1] = "Unknown"
    /\ txnState[T4] = "Parked"
    /\ ResolveMember(T1)
    /\ parkedResolutionObserved' = TRUE

WitnessNext ==
    \/ /\ Next
       /\ UNCHANGED parkedResolutionObserved
    \/ ObserveParkedResolution

WitnessSpec == WitnessInit /\ [][WitnessNext]_witnessVars

ParkedResolutionComplete ==
    /\ parkedResolutionObserved
    /\ lastAction = "CompleteCohort"
    /\ visible = {T1, T4}
    /\ txnState[T1] = "Committed"
    /\ receipt[T1] = "Committed"
    /\ txnState[T2] = "Failed"
    /\ receipt[T2] = "Failed"
    /\ txnState[T4] = "Committed"
    /\ receipt[T4] = "Committed"
    /\ memberSequence[T4] = 2
    /\ memberBatch[T4] = T4
    /\ batchPrevious[T4] = T1
    /\ batchState[T4] = "Confirmed"
    /\ cohort = {}
    /\ headState = "Collecting"
    /\ ~headAttemptEntered
    /\ batchPutCalls = 3
    /\ headPutCalls = 2
    /\ resolutionPutCalls = 0

ParkedResolutionPending == ~ParkedResolutionComplete

=============================================================================
