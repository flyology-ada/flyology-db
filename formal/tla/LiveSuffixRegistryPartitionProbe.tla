---------------- MODULE LiveSuffixRegistryPartitionProbe ----------------
EXTENDS LiveSuffixRegistryPublication

(***************************************************************************
This negative probe deliberately aliases one suffix identity into the captured
checkpoint partition. It must violate CapturedPartitionIsExact.
***************************************************************************)

UnsafeCapturePartition ==
    /\ phase = "SuffixCommitted"
    /\ capturedCheckpoint' = {"I1", "I2"}
    /\ capturedSuffix' = SuffixIds
    /\ phase' = "PartitionCaptured"
    /\ lastAction' = "SnapshotPartition"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        receipt, result, oldWriterFenced, recoveredIds, cancelledAfterHead,
        rivalRejected, batchPuts, manifestPuts, headPuts>>

NextProbe == CommitSuffixGroup \/ UnsafeCapturePartition
SpecProbe == Init /\ [][NextProbe]_vars

=============================================================================
