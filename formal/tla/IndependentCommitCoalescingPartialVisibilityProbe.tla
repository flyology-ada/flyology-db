---------- MODULE IndependentCommitCoalescingPartialVisibilityProbe ----------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe makes only the first member of a ready cohort visible.
It must violate WholeCohortVisibility.
***************************************************************************)

UnsafePartialVisibility ==
    LET first == FirstMember(cohort)
    IN
    /\ headState = "Publishing"
    /\ CohortReady
    /\ Cardinality(cohort) > 1
    /\ visible' = visible \cup {first}
    /\ publishedCohorts' = publishedCohorts \cup {{first}}
    /\ sequence' = sequence + 1
    /\ latestBatch' = first
    /\ headState' = "Accepted"
    /\ headAttemptEntered' = TRUE
    /\ txnState' = [txnState EXCEPT ![first] = "Accepted"]
    /\ headPutCalls' = headPutCalls + 1
    /\ lastAction' = "PublishCohortHead"
    /\ UNCHANGED <<cohort, memberSequence, memberBatch, batchPrevious,
        batchState, storedBatches, receipt, durableAuthority, authorityState,
        importedAuthority, recovered, recoveryImage, batchPutCalls,
        resolutionPutCalls, fenced, staleAdmissionObserved, crashObserved>>

ProbeNext == Next \/ UnsafePartialVisibility
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
