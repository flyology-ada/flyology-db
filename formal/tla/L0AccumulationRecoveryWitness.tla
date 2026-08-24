------------------- MODULE L0AccumulationRecoveryWitness ------------------
EXTENDS L0Accumulation

(***************************************************************************
This witness selects admitted two-run accumulation, an accepted-lost second
HEAD response, read-only resolution, crash, and exact recovery. Excluding the
direct publish makes that execution path part of the checked evidence.
***************************************************************************)

InitWitness == Init /\ familyRunLimit = 2 /\ totalRunLimit = 2
ResolvedCrash == lastAction = "ResolveSecond" /\ Crash

NextWitness ==
    \/ CommitPrefix \/ BeginFirst \/ StoreFirstRun \/ ConfirmFirstRun
    \/ StoreFirstManifest \/ ConfirmFirstManifest \/ PublishFirst
    \/ CommitSuffix \/ BeginSecond \/ StoreSecondRun \/ ConfirmSecondRun
    \/ StoreSecondManifest \/ ConfirmSecondManifest
    \/ LoseAcceptedSecondResponse \/ ResolveSecond \/ ResolvedCrash \/ Recover

SpecWitness == InitWitness /\ [][NextWitness]_vars

WitnessComplete ==
    /\ lastAction = "Recover" /\ phase = "Recovered"
    /\ familyRunLimit = 2 /\ totalRunLimit = 2
    /\ headManifest = M2 /\ headRuns = {R1, R2}
    /\ headBoundary = 2 /\ headGeneration = 2
    /\ storedRuns = {R1, R2} /\ confirmedRuns = {R1, R2}
    /\ storedManifests = {M0, M1, M2}
    /\ confirmedManifests = {M0, M1, M2}
    /\ manifestRuns[M2] = {R1, R2}
    /\ checkpointView = MergedView /\ checkpointIds = {I1, I2}
    /\ laterView = EmptyView /\ laterIds = {}
    /\ recoveredView = MergedView /\ recoveredIds = {I1, I2}
    /\ localView = MergedView /\ localIds = {I1, I2}

WitnessPending == ~WitnessComplete

WitnessAlias ==
    [action |-> lastAction,
     phase |-> phase,
     limits |-> [family_runs |-> familyRunLimit,
                  total_runs |-> totalRunLimit],
     head |-> [manifest |-> headManifest, runs |-> headRuns,
               boundary |-> headBoundary, generation |-> headGeneration],
     store |-> [runs |-> storedRuns, confirmed_runs |-> confirmedRuns,
                manifests |-> storedManifests,
                confirmed_manifests |-> confirmedManifests],
     manifest |-> [runs |-> manifestRuns[M2],
                   previous |-> manifestPrevious[M2]],
     views |-> [checkpoint |-> checkpointView, later |-> laterView,
                recovered |-> recoveredView, local |-> localView],
     identities |-> [checkpoint |-> checkpointIds, later |-> laterIds,
                      recovered |-> recoveredIds, local |-> localIds]]

=============================================================================
