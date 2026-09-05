------------- MODULE IndependentCommitCoalescingAuthorityProbe -------------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe imports one locally malformed bearer authority after crash.
It covers the database, member, range, final-member equivalence, predecessor,
and cross-version boundary. At least one locally invalid candidate must violate
ImportedAuthorityIsValid; structurally valid narrowed endpoints remain reserved
for the resolved-authority probe.
***************************************************************************)

UnsafeImportMalformedAuthority(t) ==
    \E kind \in MalformedAuthorityKinds :
    LET candidate == MalformedAuthority(t, kind)
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
