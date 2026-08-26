----------------- MODULE L0CompactionEmptyRecoveryWitness -----------------
EXTENDS L0Compaction, FlyologyHarness

(***************************************************************************
This witness selects an all-tombstoned captured view, consumes no output
capacity and creates no SST, publishes the canonical empty run set through an
accepted-lost HEAD response, resolves read-only, crashes, and recovers the
exact empty view. Excluding direct publication makes the path checked
evidence rather than an unconstrained reachability claim.
***************************************************************************)

InitWitness == Init /\ outputCapacity = 0 /\ emptyReplacement
ResolvedCrash == lastAction = "ResolvePublication" /\ Crash

NextWitness ==
    \/ BeginCompaction \/ ConfirmNoOutput \/ StoreManifest
    \/ ConfirmManifest \/ LoseAcceptedResponse \/ ResolvePublication
    \/ ResolvedCrash \/ Recover

SpecWitness == InitWitness /\ [][NextWitness]_vars

WitnessComplete ==
    /\ lastAction = "Recover" /\ phase = "Recovered"
    /\ outputCapacity = 0 /\ emptyReplacement
    /\ headManifest = M3 /\ currentRuns = {}
    /\ headBoundary = 2 /\ headGeneration = 3
    /\ storedRuns = {R1, R2} /\ confirmedRuns = {R1, R2}
    /\ availableRuns = {R1, R2}
    /\ storedManifests = {M2, M3}
    /\ confirmedManifests = {M2, M3}
    /\ manifestPrevious[M3] = M2 /\ manifestRuns[M3] = {}
    /\ checkpointView = EmptyView /\ checkpointIds = {I1, I2}
    /\ recoveredView = EmptyView /\ recoveredIds = {I1, I2}
    /\ localView = EmptyView /\ localIds = {I1, I2}

WitnessPending == ~WitnessComplete

WitnessState ==
    [action |-> lastAction,
     phase |-> phase,
     empty_output |-> emptyReplacement,
     output_capacity |-> outputCapacity,
     head |-> [manifest |-> headManifest, runs |-> currentRuns,
               boundary |-> headBoundary, generation |-> headGeneration],
     store |-> [runs |-> storedRuns, confirmed_runs |-> confirmedRuns,
                available_runs |-> availableRuns,
                manifests |-> storedManifests,
                confirmed_manifests |-> confirmedManifests],
     manifest |-> [runs |-> manifestRuns[M3],
                   previous |-> manifestPrevious[M3]],
     views |-> [checkpoint |-> checkpointView,
                recovered |-> recoveredView, local |-> localView],
     identities |-> [checkpoint |-> checkpointIds,
                      recovered |-> recoveredIds, local |-> localIds]]

WitnessAlias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
