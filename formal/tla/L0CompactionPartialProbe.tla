---------------------- MODULE L0CompactionPartialProbe ---------------------
EXTENDS L0Compaction

(***************************************************************************
This negative probe publishes the compacted authority immediately after
planning, before its output or manifest is stored and confirmed. The normal
Next relation excludes this action; TLC must reject it through Safety.
***************************************************************************)

UnsafePublish ==
    /\ phase = "Prepared"
    /\ headManifest' = M3 /\ currentRuns' = {C1}
    /\ headGeneration' = headGeneration + 1 /\ headBoundary' = 2
    /\ checkpointView' = preparedView /\ checkpointIds' = preparedIds
    /\ laterView' = EmptyView /\ laterIds' = {}
    /\ phase' = "Published" /\ lastAction' = "Publish"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, visibleView, visibleIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        localView, localIds, recoveredView, recoveredIds>>

NextWithProbe == Next \/ UnsafePublish
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
