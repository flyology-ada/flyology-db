--------------- MODULE SuccessiveCheckpointRecoveryWitness ---------------
EXTENDS SuccessiveCheckpointPublication, FlyologyHarness

(***************************************************************************
This witness selects the accepted-lost second-checkpoint path, read-only
resolution, crash, and exact recovery. Excluding the direct second publish
from NextWitness makes the retained action trace part of the checked witness.
***************************************************************************)

ResolvedCrash == lastAction = "ResolveSecond" /\ Crash

NextWitness ==
    \/ CommitPrefix \/ BeginFirst \/ StoreFirstRun \/ ConfirmFirstRun
    \/ StoreFirstManifest \/ ConfirmFirstManifest \/ PublishFirst
    \/ CommitSuffix \/ BeginSecond \/ StoreSecondRun \/ ConfirmSecondRun
    \/ StoreSecondManifest \/ ConfirmSecondManifest
    \/ LoseAcceptedSecondResponse \/ ResolveSecond \/ ResolvedCrash \/ Recover

SpecWitness == Init /\ [][NextWitness]_vars

WitnessComplete ==
    /\ lastAction = "Recover" /\ phase = "Recovered"
    /\ historyCapacity = 3
    /\ headManifest = M2 /\ headRun = R2
    /\ headBoundary = 2 /\ headGeneration = 2
    /\ storedRuns = {R1, R2} /\ confirmedRuns = {R1, R2}
    /\ storedManifests = {M0, M1, M2}
    /\ confirmedManifests = {M0, M1, M2}
    /\ checkpointState = {T1, T2} /\ checkpointIds = {I1, I2}
    /\ laterState = {} /\ laterIds = {}
    /\ recoveredState = {T1, T2} /\ recoveredIds = {I1, I2}
    /\ replayedState = {} /\ replayedIds = {}
    /\ localState = {T1, T2} /\ localIds = {I1, I2}

WitnessPending == ~WitnessComplete

WitnessState ==
    [action |-> lastAction,
     phase |-> phase,
     history_capacity |-> historyCapacity,
     head |-> [manifest |-> headManifest, run |-> headRun,
               boundary |-> headBoundary, generation |-> headGeneration],
     store |-> [runs |-> storedRuns, confirmed_runs |-> confirmedRuns,
                manifests |-> storedManifests,
                confirmed_manifests |-> confirmedManifests],
     authority |-> [checkpoint_state |-> checkpointState,
                    checkpoint_ids |-> checkpointIds,
                    later_state |-> laterState, later_ids |-> laterIds],
     recovery |-> [state |-> recoveredState, ids |-> recoveredIds,
                   replayed_state |-> replayedState,
                   replayed_ids |-> replayedIds,
                   local_state |-> localState, local_ids |-> localIds]]

WitnessAlias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
