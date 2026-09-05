------- MODULE IndependentCommitCoalescingFiniteDeadlineProbe -------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe admits finite-deadline work into the cohort path. It must
violate FiniteDeadlinesRejectBeforeAdmission.
***************************************************************************)

UnsafeAdmitFiniteDeadline(t) ==
    /\ t \in FiniteDeadlineTxns
    /\ txnState[t] = "Idle"
    /\ txnState' = [txnState EXCEPT ![t] = "Admitted"]
    /\ lastAction' = "AdmitSingleton"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

ProbeNext == Next \/ \E t \in Txns : UnsafeAdmitFiniteDeadline(t)
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
