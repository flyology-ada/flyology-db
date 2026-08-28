----------------- MODULE LiveSuffixRegistryReplayProbe -----------------
EXTENDS LiveSuffixRegistryPublication

(***************************************************************************
This negative probe repeats the accepted HEAD Put while resolving the same
receipt. It must violate ResolutionDoesNotReplay.
***************************************************************************)

UnsafeResolveByReplay ==
    /\ phase = "Unknown" /\ headTransition = receipt
    /\ headPuts' = headPuts + 1
    /\ phase' = "HeadConfirmed" /\ result' = "Committed"
    /\ lastAction' = "ResolveCommitted"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, oldWriterFenced,
        recoveredIds, cancelledAfterHead, rivalRejected, batchPuts,
        manifestPuts>>

NextProbe ==
    \/ CommitSuffixGroup \/ SnapshotPartition \/ BeginFamilyAppend
    \/ StoreAppendManifest \/ ConfirmAppendManifest
    \/ LoseAcceptedHeadResponse \/ UnsafeResolveByReplay
SpecProbe == Init /\ [][NextProbe]_vars

=============================================================================
