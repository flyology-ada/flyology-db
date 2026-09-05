----------- MODULE IndependentCommitCoalescingParkedLeakProbe -----------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe admits a parked suffix batch to durable storage before
the confirmed prefix HEAD releases and resequences it. It must violate
ParkedSuffixWaitsForPrefix.
***************************************************************************)

UnsafeStoreParked(t) ==
    /\ txnState[t] = "Parked"
    /\ storedBatches' = storedBatches \cup {t}
    /\ batchPutCalls' = batchPutCalls + 1
    /\ lastAction' = "PublishMemberBatch"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        headPutCalls, resolutionPutCalls, fenced, staleAdmissionObserved,
        crashObserved>>

ProbeNext == Next \/ \E t \in Txns : UnsafeStoreParked(t)
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
