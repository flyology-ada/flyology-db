------------- MODULE LiveSuffixRegistryConfirmedHeadProbe -------------
EXTENDS LiveSuffixRegistryPublication

(***************************************************************************
This negative probe publishes the exact confirmed successor HEAD without
fencing the obsolete writer in the same transition. It must violate
ConfirmedHeadImpliesFenced.
***************************************************************************)

UnsafePublishWithoutFence ==
    /\ phase = "Ready" /\ "M1" \in confirmedManifests
    /\ headManifest' = "M1" /\ headLatestBatch' = "B1"
    /\ headHighest' = 3
    /\ headOrdinal' = headOrdinal + 1 /\ headTransition' = receipt
    /\ headPuts' = headPuts + 1
    /\ phase' = "HeadConfirmed" /\ result' = "Committed"
    /\ lastAction' = "PublishAppendHead"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, oldWriterFenced,
        recoveredIds, cancelledAfterHead, rivalRejected, batchPuts,
        manifestPuts>>

NextProbe ==
    \/ CommitSuffixGroup \/ SnapshotPartition \/ BeginFamilyAppend
    \/ StoreAppendManifest \/ ConfirmAppendManifest
    \/ UnsafePublishWithoutFence
SpecProbe == Init /\ [][NextProbe]_vars

=============================================================================
