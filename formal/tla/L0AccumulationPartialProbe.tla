--------------------- MODULE L0AccumulationPartialProbe --------------------
EXTENDS L0Accumulation

(***************************************************************************
This negative probe publishes M2 before R2 or M2 is stored and confirmed. It
must violate the normal HeadExact invariant; accepting it would expose a HEAD
whose additive run set cannot be recovered.
***************************************************************************)

PublishSecondEarly ==
    /\ phase = "SecondPrepared"
    /\ headManifest' = M2 /\ headRuns' = {R1, R2}
    /\ headGeneration' = headGeneration + 1 /\ headBoundary' = 2
    /\ checkpointView' = preparedView /\ checkpointIds' = preparedIds
    /\ laterView' = EmptyView /\ laterIds' = {}
    /\ phase' = "SecondPublished" /\ lastAction' = "PublishSecond"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, visibleView, visibleIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

NextWithProbe == Next \/ PublishSecondEarly
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
