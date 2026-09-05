------------- MODULE IndependentCommitCoalescingSplitWitness -------------
EXTENDS IndependentCommitCoalescing

VARIABLE parkedSplitObserved

witnessVars == <<vars, parkedSplitObserved>>

WitnessInit == Init /\ parkedSplitObserved = FALSE

ObserveParkedSplit ==
    /\ T1 \in cohort
    /\ T2 \in cohort
    /\ T4 \in cohort
    /\ SplitFailedMember(T2)
    /\ parkedSplitObserved' = TRUE

WitnessNext ==
    \/ /\ Next
       /\ UNCHANGED parkedSplitObserved
    \/ ObserveParkedSplit

WitnessSpec == WitnessInit /\ [][WitnessNext]_witnessVars

SplitComplete ==
    /\ parkedSplitObserved
    /\ lastAction = "CompleteCohort"
    /\ txnState[T1] = "Committed"
    /\ receipt[T1] = "Committed"
    /\ txnState[T2] = "Failed"
    /\ receipt[T2] = "Failed"
    /\ txnState[T4] = "Committed"
    /\ receipt[T4] = "Committed"
    /\ visible = {T1, T4}
    /\ memberSequence[T1] = 1
    /\ memberSequence[T4] = 2
    /\ batchPrevious[T4] = T1
    /\ sequence = 2
    /\ batchPutCalls = 3
    /\ headPutCalls = 2
    /\ resolutionPutCalls = 0

SplitPending == ~SplitComplete

=============================================================================
