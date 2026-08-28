------------------ MODULE LiveSuffixRegistryRivalProbe ------------------
EXTENDS LiveSuffixRegistryPublication

(***************************************************************************
This negative probe concludes the submitted receipt committed after a rival
transition won HEAD. It must violate RivalCannotResolveCommitted.
***************************************************************************)

UnsafeResolveRivalAsCommitted ==
    /\ phase = "UnknownRival" /\ headTransition # receipt
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
        manifestPuts, headPuts>>

NextProbe ==
    \/ CommitSuffixGroup \/ SnapshotPartition \/ BeginFamilyAppend
    \/ StoreAppendManifest \/ ConfirmAppendManifest
    \/ ExternalPublishRival \/ UnsafeResolveRivalAsCommitted
SpecProbe == Init /\ [][NextProbe]_vars

=============================================================================
