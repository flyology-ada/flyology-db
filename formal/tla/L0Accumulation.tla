-------------------------- MODULE L0Accumulation --------------------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
This finite model freezes additive level-zero accumulation after the first
checkpoint. R1 contains K1=V1. A later suffix deletes K1 and writes K2=V2;
R2 contains that exact delta and is appended without rewriting R1. Recovery
applies runs in increasing non-overlapping sequence order, so the newer
tombstone masks the older value. The one-versus-two run limits are finite
qualification geometry for persisted family/global backpressure, not product
defaults. No refinement to Ada is claimed.
***************************************************************************)

CONSTANTS M0, M1, M2, R1, R2, K1, K2, V1, V2, I1, I2,
          NoManifest, NoValue, Deleted

Manifests == {M0, M1, M2}
Runs == {R1, R2}
Keys == {K1, K2}
Values == {V1, V2, NoValue, Deleted}
Identities == {I1, I2}

EmptyView == [k \in Keys |-> NoValue]
FirstView == [EmptyView EXCEPT ![K1] = V1]
SecondDelta == [EmptyView EXCEPT ![K1] = Deleted, ![K2] = V2]
MergedView ==
    [k \in Keys |->
        IF SecondDelta[k] = NoValue THEN FirstView[k]
        ELSE IF SecondDelta[k] = Deleted THEN NoValue
        ELSE SecondDelta[k]]

Phases == {
    "Empty", "PrefixCommitted",
    "FirstPrepared", "FirstRunStored", "FirstRunConfirmed",
    "FirstManifestStored", "FirstReady", "FirstPublished",
    "SuffixCommitted", "SecondBackpressured",
    "SecondPrepared", "SecondRunStored", "SecondRunConfirmed",
    "SecondManifestStored", "SecondReady", "SecondUnknown",
    "SecondPublished", "Crashed", "Recovered"
}
ActionNames == {
    "Init", "CommitPrefix", "BeginFirst", "StoreFirstRun",
    "ConfirmFirstRun", "StoreFirstManifest", "ConfirmFirstManifest",
    "PublishFirst", "CommitSuffix", "RejectSecondRunCapacity",
    "BeginSecond", "StoreSecondRun", "ConfirmSecondRun",
    "StoreSecondManifest", "ConfirmSecondManifest", "PublishSecond",
    "LoseAcceptedSecondResponse", "ResolveSecond", "Crash", "Recover"
}

VARIABLES
    storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
    headManifest, headRuns, headGeneration, headBoundary,
    visibleView, visibleIds, checkpointView, checkpointIds,
    laterView, laterIds, preparedView, preparedIds,
    expectedGeneration, familyRunLimit, totalRunLimit, phase,
    localView, localIds, recoveredView, recoveredIds, lastAction

vars == <<
    storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
    headManifest, headRuns, headGeneration, headBoundary,
    visibleView, visibleIds, checkpointView, checkpointIds,
    laterView, laterIds, preparedView, preparedIds,
    expectedGeneration, familyRunLimit, totalRunLimit, phase,
    localView, localIds, recoveredView, recoveredIds, lastAction
>>

Init ==
    /\ familyRunLimit \in 1 .. 2
    /\ totalRunLimit \in 1 .. 2
    /\ storedRuns = {} /\ confirmedRuns = {}
    /\ storedManifests = {M0} /\ confirmedManifests = {M0}
    /\ manifestPrevious = [m \in Manifests |-> NoManifest]
    /\ manifestRuns = [m \in Manifests |-> {}]
    /\ manifestBoundary = [m \in Manifests |-> 0]
    /\ manifestLedger = [m \in Manifests |-> {}]
    /\ headManifest = M0 /\ headRuns = {}
    /\ headGeneration = 0 /\ headBoundary = 0
    /\ visibleView = EmptyView /\ visibleIds = {}
    /\ checkpointView = EmptyView /\ checkpointIds = {}
    /\ laterView = EmptyView /\ laterIds = {}
    /\ preparedView = EmptyView /\ preparedIds = {}
    /\ expectedGeneration = 0
    /\ phase = "Empty"
    /\ localView = EmptyView /\ localIds = {}
    /\ recoveredView = EmptyView /\ recoveredIds = {}
    /\ lastAction = "Init"

CommitPrefix ==
    /\ phase = "Empty"
    /\ visibleView' = FirstView /\ visibleIds' = {I1}
    /\ laterView' = FirstView /\ laterIds' = {I1}
    /\ localView' = FirstView /\ localIds' = {I1}
    /\ phase' = "PrefixCommitted" /\ lastAction' = "CommitPrefix"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, headRuns,
        headGeneration, headBoundary, checkpointView, checkpointIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, recoveredView, recoveredIds>>

BeginFirst ==
    /\ phase = "PrefixCommitted"
    /\ preparedView' = visibleView /\ preparedIds' = visibleIds
    /\ expectedGeneration' = headGeneration
    /\ phase' = "FirstPrepared" /\ lastAction' = "BeginFirst"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, headRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        familyRunLimit, totalRunLimit, localView, localIds,
        recoveredView, recoveredIds>>

StoreFirstRun ==
    /\ phase = "FirstPrepared"
    /\ storedRuns' = storedRuns \cup {R1}
    /\ phase' = "FirstRunStored" /\ lastAction' = "StoreFirstRun"
    /\ UNCHANGED <<confirmedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headRuns, headGeneration, headBoundary, visibleView,
        visibleIds, checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

ConfirmFirstRun ==
    /\ phase = "FirstRunStored"
    /\ confirmedRuns' = confirmedRuns \cup {R1}
    /\ phase' = "FirstRunConfirmed" /\ lastAction' = "ConfirmFirstRun"
    /\ UNCHANGED <<storedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headRuns, headGeneration, headBoundary, visibleView,
        visibleIds, checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

StoreFirstManifest ==
    /\ phase = "FirstRunConfirmed"
    /\ storedManifests' = storedManifests \cup {M1}
    /\ manifestPrevious' = [manifestPrevious EXCEPT ![M1] = M0]
    /\ manifestRuns' = [manifestRuns EXCEPT ![M1] = {R1}]
    /\ manifestBoundary' = [manifestBoundary EXCEPT ![M1] = 1]
    /\ manifestLedger' = [manifestLedger EXCEPT ![M1] = {I1}]
    /\ phase' = "FirstManifestStored" /\ lastAction' = "StoreFirstManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, confirmedManifests,
        headManifest, headRuns, headGeneration, headBoundary, visibleView,
        visibleIds, checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

ConfirmFirstManifest ==
    /\ phase = "FirstManifestStored"
    /\ confirmedManifests' = confirmedManifests \cup {M1}
    /\ phase' = "FirstReady" /\ lastAction' = "ConfirmFirstManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headRuns, headGeneration, headBoundary, visibleView,
        visibleIds, checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

PublishFirst ==
    /\ phase = "FirstReady" /\ headGeneration = expectedGeneration
    /\ headManifest' = M1 /\ headRuns' = {R1}
    /\ headGeneration' = headGeneration + 1 /\ headBoundary' = 1
    /\ checkpointView' = preparedView /\ checkpointIds' = preparedIds
    /\ laterView' = EmptyView /\ laterIds' = {}
    /\ phase' = "FirstPublished" /\ lastAction' = "PublishFirst"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, visibleView, visibleIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

CommitSuffix ==
    /\ phase = "FirstPublished"
    /\ visibleView' = MergedView /\ visibleIds' = {I1, I2}
    /\ laterView' = SecondDelta /\ laterIds' = {I2}
    /\ localView' = MergedView /\ localIds' = {I1, I2}
    /\ phase' = "SuffixCommitted" /\ lastAction' = "CommitSuffix"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, headRuns,
        headGeneration, headBoundary, checkpointView, checkpointIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, recoveredView, recoveredIds>>

RejectSecondRunCapacity ==
    /\ phase = "SuffixCommitted"
    /\ \/ familyRunLimit = 1
       \/ totalRunLimit = 1
    /\ phase' = "SecondBackpressured"
    /\ lastAction' = "RejectSecondRunCapacity"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, headRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

BeginSecond ==
    /\ phase = "SuffixCommitted"
    /\ familyRunLimit = 2 /\ totalRunLimit = 2
    /\ preparedView' = visibleView /\ preparedIds' = visibleIds
    /\ expectedGeneration' = headGeneration
    /\ phase' = "SecondPrepared" /\ lastAction' = "BeginSecond"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, headRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        familyRunLimit, totalRunLimit, localView, localIds,
        recoveredView, recoveredIds>>

StoreSecondRun ==
    /\ phase = "SecondPrepared"
    /\ storedRuns' = storedRuns \cup {R2}
    /\ phase' = "SecondRunStored" /\ lastAction' = "StoreSecondRun"
    /\ UNCHANGED <<confirmedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headRuns, headGeneration, headBoundary, visibleView,
        visibleIds, checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

ConfirmSecondRun ==
    /\ phase = "SecondRunStored"
    /\ confirmedRuns' = confirmedRuns \cup {R2}
    /\ phase' = "SecondRunConfirmed" /\ lastAction' = "ConfirmSecondRun"
    /\ UNCHANGED <<storedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headRuns, headGeneration, headBoundary, visibleView,
        visibleIds, checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

StoreSecondManifest ==
    /\ phase = "SecondRunConfirmed"
    /\ storedManifests' = storedManifests \cup {M2}
    /\ manifestPrevious' = [manifestPrevious EXCEPT ![M2] = M1]
    /\ manifestRuns' = [manifestRuns EXCEPT ![M2] = {R1, R2}]
    /\ manifestBoundary' = [manifestBoundary EXCEPT ![M2] = 2]
    /\ manifestLedger' = [manifestLedger EXCEPT ![M2] = {I1, I2}]
    /\ phase' = "SecondManifestStored" /\ lastAction' = "StoreSecondManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, confirmedManifests,
        headManifest, headRuns, headGeneration, headBoundary, visibleView,
        visibleIds, checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

ConfirmSecondManifest ==
    /\ phase = "SecondManifestStored"
    /\ confirmedManifests' = confirmedManifests \cup {M2}
    /\ phase' = "SecondReady" /\ lastAction' = "ConfirmSecondManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        manifestPrevious, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headRuns, headGeneration, headBoundary, visibleView,
        visibleIds, checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

PublishSecondAs(NewPhase, Action) ==
    /\ phase = "SecondReady" /\ headGeneration = expectedGeneration
    /\ headManifest' = M2 /\ headRuns' = {R1, R2}
    /\ headGeneration' = headGeneration + 1 /\ headBoundary' = 2
    /\ checkpointView' = preparedView /\ checkpointIds' = preparedIds
    /\ laterView' = EmptyView /\ laterIds' = {}
    /\ phase' = NewPhase /\ lastAction' = Action
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, visibleView, visibleIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

PublishSecond == PublishSecondAs("SecondPublished", "PublishSecond")
LoseAcceptedSecondResponse ==
    PublishSecondAs("SecondUnknown", "LoseAcceptedSecondResponse")

ResolveSecond ==
    /\ phase = "SecondUnknown" /\ headManifest = M2
    /\ phase' = "SecondPublished" /\ lastAction' = "ResolveSecond"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, headRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, localView, localIds, recoveredView, recoveredIds>>

Crash ==
    /\ phase = "SecondPublished"
    /\ localView' = EmptyView /\ localIds' = {}
    /\ phase' = "Crashed" /\ lastAction' = "Crash"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, headRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit, recoveredView, recoveredIds>>

Recover ==
    /\ phase = "Crashed"
    /\ recoveredView' = checkpointView /\ recoveredIds' = checkpointIds
    /\ localView' = checkpointView /\ localIds' = checkpointIds
    /\ phase' = "Recovered" /\ lastAction' = "Recover"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRuns,
        manifestBoundary, manifestLedger, headManifest, headRuns,
        headGeneration, headBoundary, visibleView, visibleIds,
        checkpointView, checkpointIds, laterView, laterIds,
        preparedView, preparedIds, expectedGeneration, familyRunLimit,
        totalRunLimit>>

Next ==
    \/ CommitPrefix \/ BeginFirst \/ StoreFirstRun \/ ConfirmFirstRun
    \/ StoreFirstManifest \/ ConfirmFirstManifest \/ PublishFirst
    \/ CommitSuffix \/ RejectSecondRunCapacity \/ BeginSecond
    \/ StoreSecondRun \/ ConfirmSecondRun \/ StoreSecondManifest
    \/ ConfirmSecondManifest \/ PublishSecond
    \/ LoseAcceptedSecondResponse \/ ResolveSecond \/ Crash \/ Recover

TypeOK ==
    /\ storedRuns \subseteq Runs /\ confirmedRuns \subseteq Runs
    /\ storedManifests \subseteq Manifests
    /\ confirmedManifests \subseteq Manifests
    /\ manifestPrevious \in [Manifests -> Manifests \cup {NoManifest}]
    /\ manifestRuns \in [Manifests -> SUBSET Runs]
    /\ manifestBoundary \in [Manifests -> 0 .. 2]
    /\ manifestLedger \in [Manifests -> SUBSET Identities]
    /\ headManifest \in Manifests /\ headRuns \subseteq Runs
    /\ headGeneration \in 0 .. 2 /\ headBoundary \in 0 .. 2
    /\ visibleView \in [Keys -> Values]
    /\ checkpointView \in [Keys -> Values]
    /\ laterView \in [Keys -> Values]
    /\ preparedView \in [Keys -> Values]
    /\ localView \in [Keys -> Values]
    /\ recoveredView \in [Keys -> Values]
    /\ visibleIds \subseteq Identities /\ checkpointIds \subseteq Identities
    /\ laterIds \subseteq Identities /\ preparedIds \subseteq Identities
    /\ localIds \subseteq Identities /\ recoveredIds \subseteq Identities
    /\ expectedGeneration \in 0 .. 2
    /\ familyRunLimit \in 1 .. 2 /\ totalRunLimit \in 1 .. 2
    /\ phase \in Phases /\ lastAction \in ActionNames

ConfirmedStored ==
    /\ confirmedRuns \subseteq storedRuns
    /\ confirmedManifests \subseteq storedManifests

ExactManifests ==
    /\ (M1 \in storedManifests =>
          /\ manifestPrevious[M1] = M0
          /\ manifestRuns[M1] = {R1}
          /\ manifestBoundary[M1] = 1
          /\ manifestLedger[M1] = {I1})
    /\ (M2 \in storedManifests =>
          /\ manifestPrevious[M2] = M1
          /\ manifestRuns[M2] = {R1, R2}
          /\ manifestBoundary[M2] = 2
          /\ manifestLedger[M2] = {I1, I2})

HeadExact ==
    /\ headManifest \in confirmedManifests
    /\ headRuns \subseteq confirmedRuns
    /\ headRuns = manifestRuns[headManifest]
    /\ headBoundary = manifestBoundary[headManifest]
    /\ IF headManifest = M0
          THEN headRuns = {} /\ checkpointView = EmptyView /\ checkpointIds = {}
          ELSE IF headManifest = M1
            THEN headRuns = {R1} /\ checkpointView = FirstView /\ checkpointIds = {I1}
            ELSE /\ headManifest = M2
                 /\ headRuns = {R1, R2}
                 /\ checkpointView = MergedView
                 /\ checkpointView[K1] = NoValue
                 /\ checkpointView[K2] = V2
                 /\ checkpointIds = {I1, I2}

BackpressureNoEffects ==
    phase = "SecondBackpressured" =>
      /\ storedRuns = {R1} /\ confirmedRuns = {R1}
      /\ storedManifests = {M0, M1} /\ confirmedManifests = {M0, M1}
      /\ headManifest = M1 /\ headRuns = {R1} /\ headBoundary = 1
      /\ checkpointView = FirstView /\ visibleView = MergedView

RecoveryExact ==
    phase = "Recovered" =>
      /\ recoveredView = MergedView /\ recoveredIds = {I1, I2}
      /\ localView = MergedView /\ localIds = {I1, I2}
      /\ headRuns = {R1, R2} /\ R1 \in storedRuns /\ R2 \in storedRuns

LocalDisposable ==
    /\ (phase = "Crashed" => localView = EmptyView /\ localIds = {})
    /\ (phase = "Recovered" => localView = checkpointView /\ localIds = checkpointIds)

Safety ==
    TypeOK /\ ConfirmedStored /\ ExactManifests /\ HeadExact
    /\ BackpressureNoEffects /\ RecoveryExact /\ LocalDisposable

Spec == Init /\ [][Next]_vars

=============================================================================
