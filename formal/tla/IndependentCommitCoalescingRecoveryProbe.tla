-------------- MODULE IndependentCommitCoalescingRecoveryProbe --------------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe installs a duplicate-identity recovery image. It is only
enabled once at least two visible members make that mutation nontrivial, and
must violate RecoveryIsExact.
***************************************************************************)

UnsafeInstallDuplicateIdentity ==
    LET image == MalformedRecovery("DuplicateIdentity")
    IN
    /\ crashObserved
    /\ Cardinality(visible) > 1
    /\ ~RecoveryImageValid(image)
    /\ recovered' = image.members
    /\ recoveryImage' = image
    /\ lastAction' = "RecoverCohortChain"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, headState, headAttemptEntered, receipt,
        durableAuthority, authorityState, importedAuthority, batchPutCalls,
        headPutCalls, resolutionPutCalls, fenced, staleAdmissionObserved,
        crashObserved>>

ProbeNext == Next \/ UnsafeInstallDuplicateIdentity
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
