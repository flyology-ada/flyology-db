------------- MODULE LiveSuffixRegistryManifestReplayProbe -------------
EXTENDS LiveSuffixRegistryPublication

(***************************************************************************
This negative probe repeats the accepted immutable manifest Put while
resolving the same receipt. It must violate ManifestResolutionDoesNotReplay.
***************************************************************************)

UnsafeResolveManifestByReplay ==
    /\ phase = "ManifestUnknown" /\ "M1" \in storedManifests
    /\ confirmedManifests' = confirmedManifests \union {"M1"}
    /\ manifestPuts' = manifestPuts + 1
    /\ phase' = "Ready" /\ result' = "None"
    /\ lastAction' = "ResolveManifestByRead"
    /\ UNCHANGED <<storedManifests, storedBatches, confirmedBatches,
        manifestPrevious, manifestRegistry, manifestReplayBoundary,
        manifestLedger, batchFirst, batchHighest, batchIds, headManifest,
        headLatestBatch, headHighest, headOrdinal, headTransition,
        checkpointIds, suffixIds, liveIds, capturedCheckpoint, capturedSuffix,
        receipt, oldWriterFenced, recoveredIds, cancelledAfterHead,
        rivalRejected, batchPuts, headPuts>>

NextProbe ==
    \/ CommitSuffixGroup \/ SnapshotPartition \/ BeginFamilyAppend
    \/ StoreAppendManifest \/ LoseAcceptedManifestResponse
    \/ UnsafeResolveManifestByReplay

SpecProbe == Init /\ [][NextProbe]_vars

=============================================================================
