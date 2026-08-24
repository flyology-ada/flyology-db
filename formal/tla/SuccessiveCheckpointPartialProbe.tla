---------------- MODULE SuccessiveCheckpointPartialProbe ----------------
EXTENDS SuccessiveCheckpointPublication

(***************************************************************************
This negative probe deliberately publishes the second HEAD immediately after
planning, before its run or manifest bytes are stored and confirmed. The
normal Next relation excludes this action; TLC must reject it through Safety.
***************************************************************************)

UnsafePublishSecond ==
    /\ phase = "SecondPrepared"
    /\ headManifest' = M2 /\ headRun' = R2
    /\ headGeneration' = headGeneration + 1 /\ headBoundary' = 2
    /\ checkpointState' = preparedState /\ checkpointIds' = preparedIds
    /\ laterState' = {} /\ laterIds' = {}
    /\ phase' = "SecondPublished" /\ lastAction' = "PublishSecond"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, visibleState, visibleIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

NextWithProbe == Next \/ UnsafePublishSecond
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
