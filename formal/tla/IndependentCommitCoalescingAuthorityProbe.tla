------------- MODULE IndependentCommitCoalescingAuthorityProbe -------------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe imports a wrong-database bearer authority after crash.
It must violate ImportedAuthorityIsValid.
***************************************************************************)

UnsafeImportMalformedAuthority(t) ==
    LET candidate == MalformedAuthority(t, "WrongDatabase")
    IN
    /\ txnState[t] = "Unknown"
    /\ receipt[t] = "None"
    /\ authorityState[t] = "Lost"
    /\ receipt' = [receipt EXCEPT ![t] = "Unknown"]
    /\ authorityState' = [authorityState EXCEPT ![t] = "Imported"]
    /\ importedAuthority' = [importedAuthority EXCEPT ![t] = candidate]
    /\ lastAction' = "ImportMemberAuthority"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, headState, headAttemptEntered, durableAuthority,
        recovered, recoveryImage, batchPutCalls, headPutCalls,
        resolutionPutCalls, fenced, staleAdmissionObserved, crashObserved>>

ProbeNext == Next \/ \E t \in Txns : UnsafeImportMalformedAuthority(t)
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
