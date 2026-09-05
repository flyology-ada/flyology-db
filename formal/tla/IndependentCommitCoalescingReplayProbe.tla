--------------- MODULE IndependentCommitCoalescingReplayProbe ---------------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe resolves an unknown member by replaying publication.
It must violate ResolutionDoesNotReplay.
***************************************************************************)

UnsafeReplayResolution(t) ==
    /\ t \in cohort
    /\ txnState[t] = "Unknown"
    /\ receipt[t] = "Unknown"
    /\ t \in visible
    /\ txnState' = [txnState EXCEPT ![t] = "Committed"]
    /\ receipt' = [receipt EXCEPT ![t] = "Committed"]
    /\ resolutionPutCalls' = resolutionPutCalls + 1
    /\ lastAction' = "ResolveMember"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, headState, headAttemptEntered, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, fenced, staleAdmissionObserved,
        crashObserved>>

ProbeNext == Next \/ \E t \in Txns : UnsafeReplayResolution(t)
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
