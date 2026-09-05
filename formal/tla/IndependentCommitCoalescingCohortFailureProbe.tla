------- MODULE IndependentCommitCoalescingCohortFailureProbe -------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe loses one sibling receipt while failing every member of a
frozen cohort. It must violate WholeFrozenCohortFailure because the
implementation contract completes every member together before any HEAD
publication, including members whose immutable batch Put was never attempted.
***************************************************************************)

UnsafeLoseSiblingReceipt(t) ==
    /\ headState = "Publishing"
    /\ t \in cohort
    /\ Cardinality(cohort) > 1
    /\ cohort' = {}
    /\ txnState' = [u \in Txns |-> IF u \in cohort THEN "Failed" ELSE txnState[u]]
    /\ receipt' = [receipt EXCEPT ![t] = "Failed"]
    /\ headState' = "Collecting"
    /\ headAttemptEntered' = FALSE
    /\ lastAction' = "FailFrozenCohort"
    /\ UNCHANGED <<sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        durableAuthority, authorityState, importedAuthority, recovered,
        recoveryImage, batchPutCalls, headPutCalls, resolutionPutCalls,
        fenced, staleAdmissionObserved, crashObserved>>

ProbeNext == Next \/ \E t \in Txns : UnsafeLoseSiblingReceipt(t)
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
