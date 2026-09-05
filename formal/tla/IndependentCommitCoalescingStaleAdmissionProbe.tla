------------ MODULE IndependentCommitCoalescingStaleAdmissionProbe ------------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe admits an idle transaction after the writer is fenced.
It must violate FencingStopsAdmission.
***************************************************************************)

UnsafeStaleAdmission(t) ==
    /\ fenced
    /\ txnState[t] = "Idle"
    /\ txnState' = [txnState EXCEPT ![t] = "Admitted"]
    /\ staleAdmissionObserved' = TRUE
    /\ lastAction' = "AdmitSingleton"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        crashObserved>>

ProbeNext == Next \/ \E t \in Txns : UnsafeStaleAdmission(t)
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
