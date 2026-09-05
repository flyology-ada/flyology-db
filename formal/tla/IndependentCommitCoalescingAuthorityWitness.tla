----------- MODULE IndependentCommitCoalescingAuthorityWitness -----------
EXTENDS IndependentCommitCoalescing

AuthorityRecoveryComplete ==
    /\ lastAction = "RecoverCohortChain"
    /\ crashObserved
    /\ ~headAttemptEntered
    /\ visible = {T1, T2}
    /\ recovered = visible
    /\ authorityState[T1] = "Imported"
    /\ IF importedAuthority[T1] \in AuthorityValue
       THEN importedAuthority[T1].member = T1
       ELSE FALSE
    /\ txnState[T1] = "Committed"
    /\ receipt[T1] = "Committed"
    /\ txnState[T2] = "Unknown"
    /\ receipt[T2] = "Unknown"
    /\ cohort = {}
    /\ headState = "Collecting"
    /\ batchPutCalls = 2
    /\ headPutCalls = 1
    /\ resolutionPutCalls = 0

AuthorityRecoveryPending == ~AuthorityRecoveryComplete

=============================================================================
