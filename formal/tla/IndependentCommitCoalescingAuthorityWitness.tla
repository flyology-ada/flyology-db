----------- MODULE IndependentCommitCoalescingAuthorityWitness -----------
EXTENDS IndependentCommitCoalescing

AuthorityRecoveryComplete ==
    /\ lastAction = "ResolveMember"
    /\ crashObserved
    /\ ~headAttemptEntered
    /\ visible = {T1, T2}
    /\ recovered = visible
    /\ RecoveredChainIsExact
    /\ authorityState[T1] = "Resolved"
    /\ IF importedAuthority[T1] \in AuthorityValue
       THEN importedAuthority[T1].member = T1
       ELSE FALSE
    /\ txnState[T1] = "Committed"
    /\ receipt[T1] = "Committed"
    /\ txnState[T2] = "Unknown"
    /\ receipt[T2] = "Unknown"
    /\ ResolvedAuthorityValidFor(T1, importedAuthority[T1])
    /\ batchPutCalls = 2
    /\ headPutCalls = 1
    /\ resolutionPutCalls = 0

AuthorityRecoveryPending == ~AuthorityRecoveryComplete

=============================================================================
