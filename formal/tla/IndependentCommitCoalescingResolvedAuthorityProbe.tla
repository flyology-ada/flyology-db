---------- MODULE IndependentCommitCoalescingResolvedAuthorityProbe ----------
EXTENDS IndependentCommitCoalescing

(***************************************************************************
This negative probe commits a structurally valid imported authority whose
final endpoint does not name the recovered maximal cohort. It must violate
ResolvedImportedAuthorityIsExact.
***************************************************************************)

UnsafeResolveStructurallyValidAuthority ==
    LET t == T1
        candidate == MalformedAuthority(t, "NarrowedFinal")
    IN
    /\ txnState[t] = "Unknown"
    /\ receipt[t] = "Unknown"
    /\ authorityState[t] = "Imported"
    /\ importedAuthority[t] = candidate
    /\ StructuralAuthorityValidFor(t, candidate)
    /\ ~ResolvedAuthorityValidFor(t, candidate)
    /\ t \in visible
    /\ txnState' = [txnState EXCEPT ![t] = "Committed"]
    /\ receipt' = [receipt EXCEPT ![t] = "Committed"]
    /\ authorityState' = [authorityState EXCEPT ![t] = "Resolved"]
    /\ lastAction' = "ResolveMember"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, headState, headAttemptEntered, durableAuthority,
        importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

ProbeNext == Next \/ UnsafeResolveStructurallyValidAuthority
ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
