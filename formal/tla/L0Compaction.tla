--------------------------- MODULE L0Compaction ---------------------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
This finite model starts from a qualified two-run L0 authority and replaces
it with either one complete compacted run or the canonical empty run set when
the captured live view is wholly absent. Every present output and the
successor manifest must be confirmed before HEAD changes. Superseded runs
remain immutable stored history; physical garbage collection is deliberately
outside this slice. Zero-versus-one output capacity is finite qualification
geometry, not a product default. No refinement to Ada is claimed.
***************************************************************************)

CONSTANTS M2, M3, R1, R2, C1, K1, K2, V2, I1, I2,
          NoManifest, NoValue

Manifests == {M2, M3}
Runs == {R1, R2, C1}
Keys == {K1, K2}
Values == {V2, NoValue}
Identities == {I1, I2}

EmptyView == [k \in Keys |-> NoValue]
CompactedView == [EmptyView EXCEPT ![K2] = V2]

Phases == {
    "Accumulated", "OutputBackpressured", "Prepared", "OutputStored",
    "OutputConfirmed", "ManifestStored", "Ready", "Unknown", "Published",
    "Crashed", "OutputMissing", "RecoveryRejected", "Recovered"
}
ActionNames == {
    "Init", "RejectOutputCapacity", "BeginCompaction", "StoreOutput",
    "ConfirmNoOutput", "ConfirmOutput", "StoreManifest", "ConfirmManifest", "Publish",
    "LoseAcceptedResponse", "ResolvePublication", "Crash", "HideOutput",
    "RejectRecovery", "Recover"
}

VARIABLES
    storedRuns, confirmedRuns, availableRuns,
    storedManifests, confirmedManifests,
    manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
    headManifest, currentRuns, headGeneration, headBoundary,
    visibleView, visibleIds, checkpointView, checkpointIds,
    laterView, laterIds, preparedView, preparedIds,
    expectedGeneration, outputCapacity, emptyReplacement, phase,
    localView, localIds, recoveredView, recoveredIds, lastAction

TargetView == IF emptyReplacement THEN EmptyView ELSE CompactedView
TargetRuns == IF emptyReplacement THEN {} ELSE {C1}

vars == <<
    storedRuns, confirmedRuns, availableRuns,
    storedManifests, confirmedManifests,
    manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
    headManifest, currentRuns, headGeneration, headBoundary,
    visibleView, visibleIds, checkpointView, checkpointIds,
    laterView, laterIds, preparedView, preparedIds,
    expectedGeneration, outputCapacity, emptyReplacement, phase,
    localView, localIds, recoveredView, recoveredIds, lastAction
>>

Init ==
    /\ outputCapacity \in 0 .. 1
    /\ emptyReplacement \in BOOLEAN
    /\ storedRuns = {R1, R2} /\ confirmedRuns = {R1, R2}
    /\ availableRuns = {R1, R2}
    /\ storedManifests = {M2} /\ confirmedManifests = {M2}
    /\ manifestPrevious = [m \in Manifests |-> NoManifest]
    /\ manifestRuns = [m \in Manifests |-> IF m = M2 THEN {R1, R2} ELSE {}]
    /\ manifestBoundary = [m \in Manifests |-> IF m = M2 THEN 2 ELSE 0]
    /\ manifestLedger = [m \in Manifests |-> IF m = M2 THEN {I1, I2} ELSE {}]
    /\ headManifest = M2 /\ currentRuns = {R1, R2}
    /\ headGeneration = 2 /\ headBoundary = 2
    /\ visibleView = TargetView /\ visibleIds = {I1, I2}
    /\ checkpointView = TargetView /\ checkpointIds = {I1, I2}
    /\ laterView = EmptyView /\ laterIds = {}
    /\ preparedView = EmptyView /\ preparedIds = {}
    /\ expectedGeneration = 0
    /\ phase = "Accumulated"
    /\ localView = TargetView /\ localIds = {I1, I2}
    /\ recoveredView = EmptyView /\ recoveredIds = {}
    /\ lastAction = "Init"

RejectOutputCapacity ==
    /\ phase = "Accumulated" /\ outputCapacity = 0 /\ ~emptyReplacement
    /\ phase' = "OutputBackpressured"
    /\ lastAction' = "RejectOutputCapacity"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement,
        localView, localIds, recoveredView, recoveredIds>>

BeginCompaction ==
    /\ phase = "Accumulated"
    /\ (emptyReplacement \/ outputCapacity = 1)
    /\ preparedView' = visibleView /\ preparedIds' = visibleIds
    /\ expectedGeneration' = headGeneration
    /\ phase' = "Prepared" /\ lastAction' = "BeginCompaction"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds, outputCapacity,
        emptyReplacement,
        localView, localIds, recoveredView, recoveredIds>>

StoreOutput ==
    /\ phase = "Prepared" /\ ~emptyReplacement
    /\ storedRuns' = storedRuns \cup {C1}
    /\ availableRuns' = availableRuns \cup {C1}
    /\ phase' = "OutputStored" /\ lastAction' = "StoreOutput"
    /\ UNCHANGED <<confirmedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, currentRuns, headGeneration, headBoundary,
        visibleView, visibleIds, checkpointView, checkpointIds,
        laterView, laterIds, preparedView, preparedIds, expectedGeneration,
        outputCapacity, emptyReplacement, localView, localIds,
        recoveredView, recoveredIds>>

ConfirmNoOutput ==
    /\ phase = "Prepared" /\ emptyReplacement
    /\ phase' = "OutputConfirmed" /\ lastAction' = "ConfirmNoOutput"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement, localView, localIds, recoveredView, recoveredIds>>

ConfirmOutput ==
    /\ phase = "OutputStored" /\ ~emptyReplacement
    /\ confirmedRuns' = confirmedRuns \cup {C1}
    /\ phase' = "OutputConfirmed" /\ lastAction' = "ConfirmOutput"
    /\ UNCHANGED <<storedRuns, availableRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement, localView, localIds, recoveredView, recoveredIds>>

StoreManifest ==
    /\ phase = "OutputConfirmed"
    /\ storedManifests' = storedManifests \cup {M3}
    /\ manifestPrevious' = [manifestPrevious EXCEPT ![M3] = M2]
    /\ manifestRuns' = [manifestRuns EXCEPT ![M3] = TargetRuns]
    /\ manifestBoundary' = [manifestBoundary EXCEPT ![M3] = 2]
    /\ manifestLedger' = [manifestLedger EXCEPT ![M3] = {I1, I2}]
    /\ phase' = "ManifestStored" /\ lastAction' = "StoreManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        confirmedManifests, headManifest, currentRuns, headGeneration,
        headBoundary, visibleView, visibleIds, checkpointView, checkpointIds,
        laterView, laterIds, preparedView, preparedIds, expectedGeneration,
        outputCapacity, emptyReplacement, localView, localIds,
        recoveredView, recoveredIds>>

ConfirmManifest ==
    /\ phase = "ManifestStored"
    /\ confirmedManifests' = confirmedManifests \cup {M3}
    /\ phase' = "Ready" /\ lastAction' = "ConfirmManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, manifestPrevious, manifestRuns, manifestBoundary,
        manifestLedger, headManifest, currentRuns, headGeneration,
        headBoundary, visibleView, visibleIds, checkpointView, checkpointIds,
        laterView, laterIds, preparedView, preparedIds, expectedGeneration,
        outputCapacity, emptyReplacement, localView, localIds,
        recoveredView, recoveredIds>>

PublishAs(NewPhase, Action) ==
    /\ phase = "Ready" /\ headGeneration = expectedGeneration
    /\ headManifest' = M3 /\ currentRuns' = TargetRuns
    /\ headGeneration' = headGeneration + 1 /\ headBoundary' = 2
    /\ checkpointView' = preparedView /\ checkpointIds' = preparedIds
    /\ laterView' = EmptyView /\ laterIds' = {}
    /\ phase' = NewPhase /\ lastAction' = Action
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, visibleView, visibleIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement, localView, localIds, recoveredView, recoveredIds>>

Publish == PublishAs("Published", "Publish")
LoseAcceptedResponse == PublishAs("Unknown", "LoseAcceptedResponse")

ResolvePublication ==
    /\ phase = "Unknown" /\ headManifest = M3
    /\ phase' = "Published" /\ lastAction' = "ResolvePublication"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement, localView, localIds, recoveredView, recoveredIds>>

Crash ==
    /\ phase = "Published"
    /\ localView' = EmptyView /\ localIds' = {}
    /\ phase' = "Crashed" /\ lastAction' = "Crash"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement, recoveredView, recoveredIds>>

HideOutput ==
    /\ phase = "Crashed" /\ ~emptyReplacement
    /\ availableRuns' = availableRuns \ {C1}
    /\ phase' = "OutputMissing" /\ lastAction' = "HideOutput"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement, localView, localIds, recoveredView, recoveredIds>>

RejectRecovery ==
    /\ phase = "OutputMissing" /\ C1 \notin availableRuns
    /\ phase' = "RecoveryRejected" /\ lastAction' = "RejectRecovery"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement, localView, localIds, recoveredView, recoveredIds>>

Recover ==
    /\ phase = "Crashed" /\ TargetRuns \subseteq availableRuns
    /\ recoveredView' = checkpointView /\ recoveredIds' = checkpointIds
    /\ localView' = checkpointView /\ localIds' = checkpointIds
    /\ phase' = "Recovered" /\ lastAction' = "Recover"
    /\ UNCHANGED <<storedRuns, confirmedRuns, availableRuns,
        storedManifests, confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, currentRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, outputCapacity,
        emptyReplacement>>

Next ==
    \/ RejectOutputCapacity \/ BeginCompaction \/ StoreOutput
    \/ ConfirmNoOutput \/ ConfirmOutput \/ StoreManifest \/ ConfirmManifest
    \/ Publish
    \/ LoseAcceptedResponse \/ ResolvePublication \/ Crash \/ HideOutput
    \/ RejectRecovery \/ Recover

TypeOK ==
    /\ storedRuns \subseteq Runs /\ confirmedRuns \subseteq Runs
    /\ availableRuns \subseteq Runs
    /\ storedManifests \subseteq Manifests
    /\ confirmedManifests \subseteq Manifests
    /\ manifestPrevious \in [Manifests -> Manifests \cup {NoManifest}]
    /\ manifestRuns \in [Manifests -> SUBSET Runs]
    /\ manifestBoundary \in [Manifests -> 0 .. 2]
    /\ manifestLedger \in [Manifests -> SUBSET Identities]
    /\ headManifest \in Manifests /\ currentRuns \subseteq Runs
    /\ headGeneration \in 2 .. 3 /\ headBoundary \in 0 .. 2
    /\ visibleView \in [Keys -> Values]
    /\ checkpointView \in [Keys -> Values]
    /\ laterView \in [Keys -> Values]
    /\ preparedView \in [Keys -> Values]
    /\ localView \in [Keys -> Values]
    /\ recoveredView \in [Keys -> Values]
    /\ visibleIds \subseteq Identities /\ checkpointIds \subseteq Identities
    /\ laterIds \subseteq Identities /\ preparedIds \subseteq Identities
    /\ localIds \subseteq Identities /\ recoveredIds \subseteq Identities
    /\ expectedGeneration \in 0 .. 2 /\ outputCapacity \in 0 .. 1
    /\ emptyReplacement \in BOOLEAN
    /\ phase \in Phases /\ lastAction \in ActionNames

ConfirmedStored ==
    /\ confirmedRuns \subseteq storedRuns
    /\ confirmedManifests \subseteq storedManifests

ExactManifests ==
    /\ manifestRuns[M2] = {R1, R2}
    /\ manifestBoundary[M2] = 2
    /\ manifestLedger[M2] = {I1, I2}
    /\ (M3 \in storedManifests =>
          /\ manifestPrevious[M3] = M2
          /\ manifestRuns[M3] = TargetRuns
          /\ manifestBoundary[M3] = 2
          /\ manifestLedger[M3] = {I1, I2})

HeadExact ==
    /\ headManifest \in confirmedManifests
    /\ currentRuns \subseteq confirmedRuns
    /\ currentRuns = manifestRuns[headManifest]
    /\ headBoundary = manifestBoundary[headManifest]
    /\ IF headManifest = M2
          THEN currentRuns = {R1, R2}
          ELSE /\ headManifest = M3 /\ currentRuns = TargetRuns

AuthorityExact ==
    /\ visibleView = TargetView /\ visibleIds = {I1, I2}
    /\ checkpointView = TargetView /\ checkpointIds = {I1, I2}
    /\ laterView = EmptyView /\ laterIds = {}
    /\ (phase \in {"Prepared", "OutputStored", "OutputConfirmed",
                    "ManifestStored", "Ready"} =>
          preparedView = TargetView /\ preparedIds = {I1, I2})

BackpressureNoEffects ==
    phase = "OutputBackpressured" =>
      /\ ~emptyReplacement
      /\ storedRuns = {R1, R2} /\ confirmedRuns = {R1, R2}
      /\ storedManifests = {M2} /\ confirmedManifests = {M2}
      /\ headManifest = M2 /\ currentRuns = {R1, R2}

RetiredRunsAreHistory ==
    headManifest = M3 =>
      /\ R1 \in storedRuns /\ R2 \in storedRuns
      /\ R1 \notin currentRuns /\ R2 \notin currentRuns

RecoveryExact ==
    phase = "Recovered" =>
      /\ recoveredView = TargetView /\ recoveredIds = {I1, I2}
      /\ localView = TargetView /\ localIds = {I1, I2}
      /\ currentRuns = TargetRuns /\ TargetRuns \subseteq availableRuns

MissingOutputFailsClosed ==
    phase = "RecoveryRejected" =>
      /\ recoveredView = EmptyView /\ recoveredIds = {}
      /\ localView = EmptyView /\ localIds = {}

LocalDisposable ==
    /\ (phase \in {"Crashed", "OutputMissing", "RecoveryRejected"} =>
          localView = EmptyView /\ localIds = {})
    /\ (phase = "Recovered" =>
          localView = checkpointView /\ localIds = checkpointIds)

Safety ==
    TypeOK /\ ConfirmedStored /\ ExactManifests /\ HeadExact
    /\ AuthorityExact /\ BackpressureNoEffects /\ RetiredRunsAreHistory
    /\ RecoveryExact /\ MissingOutputFailsClosed /\ LocalDisposable

Spec == Init /\ [][Next]_vars

=============================================================================
