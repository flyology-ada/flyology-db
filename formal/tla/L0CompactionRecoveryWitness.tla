-------------------- MODULE L0CompactionRecoveryWitness --------------------
EXTENDS L0Compaction

(***************************************************************************
This witness selects admitted compaction, an accepted-lost HEAD response,
read-only resolution, crash, and exact recovery from only C1. Excluding the
direct publish makes that execution path part of the checked evidence.
***************************************************************************)

InitWitness == Init /\ outputCapacity = 1
ResolvedCrash == lastAction = "ResolvePublication" /\ Crash

NextWitness ==
    \/ BeginCompaction \/ StoreOutput \/ ConfirmOutput \/ StoreManifest
    \/ ConfirmManifest \/ LoseAcceptedResponse \/ ResolvePublication
    \/ ResolvedCrash \/ Recover

SpecWitness == InitWitness /\ [][NextWitness]_vars

WitnessComplete ==
    /\ lastAction = "Recover" /\ phase = "Recovered"
    /\ outputCapacity = 1
    /\ headManifest = M3 /\ currentRuns = {C1}
    /\ headBoundary = 2 /\ headGeneration = 3
    /\ storedRuns = {R1, R2, C1} /\ confirmedRuns = {R1, R2, C1}
    /\ availableRuns = {R1, R2, C1}
    /\ storedManifests = {M2, M3}
    /\ confirmedManifests = {M2, M3}
    /\ manifestPrevious[M3] = M2 /\ manifestRuns[M3] = {C1}
    /\ checkpointView = CompactedView /\ checkpointIds = {I1, I2}
    /\ recoveredView = CompactedView /\ recoveredIds = {I1, I2}
    /\ localView = CompactedView /\ localIds = {I1, I2}

WitnessPending == ~WitnessComplete

WitnessAlias ==
    [action |-> lastAction,
     phase |-> phase,
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

=============================================================================
