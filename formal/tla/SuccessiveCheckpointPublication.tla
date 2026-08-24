------------------ MODULE SuccessiveCheckpointPublication ------------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
This finite model freezes successive whole-state checkpoint replacement. A
first checkpoint captures T1, a later commit adds T2 to the replay suffix,
and a second checkpoint replaces the current run with a complete T1/T2 run.
The old immutable run and manifest remain stored but are no longer named by
HEAD. Two versus three manifest slots are finite qualification geometry that
forces the second-checkpoint backpressure branch; product authority remains
the persisted Maximum_Manifest_History value. No refinement to Ada is claimed.
***************************************************************************)

CONSTANTS M0, M1, M2, R1, R2, T1, T2, I1, I2, NoManifest, NoRun

Manifests == {M0, M1, M2}
Runs == {R1, R2}
Transactions == {T1, T2}
Identities == {I1, I2}
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
    "PublishFirst", "CommitSuffix", "RejectSecondHistoryCapacity",
    "BeginSecond", "StoreSecondRun", "ConfirmSecondRun",
    "StoreSecondManifest", "ConfirmSecondManifest", "PublishSecond",
    "LoseAcceptedSecondResponse", "ResolveSecond", "Crash", "Recover"
}

RunContents == [r \in Runs |-> IF r = R1 THEN {T1} ELSE {T1, T2}]

VARIABLES
    storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    manifestPrevious, manifestRun, manifestBoundary, manifestLedger,
    headManifest, headRun, headGeneration, headBoundary,
    visibleState, visibleIds, checkpointState, checkpointIds,
    laterState, laterIds, preparedState, preparedIds,
    expectedGeneration, historyCapacity, phase, localState, localIds,
    recoveredState, recoveredIds, replayedState, replayedIds, lastAction

vars == <<
    storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    manifestPrevious, manifestRun, manifestBoundary, manifestLedger,
    headManifest, headRun, headGeneration, headBoundary,
    visibleState, visibleIds, checkpointState, checkpointIds,
    laterState, laterIds, preparedState, preparedIds,
    expectedGeneration, historyCapacity, phase, localState, localIds,
    recoveredState, recoveredIds, replayedState, replayedIds, lastAction
>>

Init ==
    /\ historyCapacity \in 2 .. 3
    /\ storedRuns = {} /\ confirmedRuns = {}
    /\ storedManifests = {M0} /\ confirmedManifests = {M0}
    /\ manifestPrevious = [m \in Manifests |-> NoManifest]
    /\ manifestRun = [m \in Manifests |-> NoRun]
    /\ manifestBoundary = [m \in Manifests |-> 0]
    /\ manifestLedger = [m \in Manifests |-> {}]
    /\ headManifest = M0 /\ headRun = NoRun
    /\ headGeneration = 0 /\ headBoundary = 0
    /\ visibleState = {} /\ visibleIds = {}
    /\ checkpointState = {} /\ checkpointIds = {}
    /\ laterState = {} /\ laterIds = {}
    /\ preparedState = {} /\ preparedIds = {}
    /\ expectedGeneration = 0
    /\ phase = "Empty"
    /\ localState = {} /\ localIds = {}
    /\ recoveredState = {} /\ recoveredIds = {}
    /\ replayedState = {} /\ replayedIds = {}
    /\ lastAction = "Init"

CommitPrefix ==
    /\ phase = "Empty"
    /\ visibleState' = {T1} /\ visibleIds' = {I1}
    /\ laterState' = {T1} /\ laterIds' = {I1}
    /\ localState' = {T1} /\ localIds' = {I1}
    /\ phase' = "PrefixCommitted" /\ lastAction' = "CommitPrefix"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, headManifest, headRun,
        headGeneration, headBoundary, checkpointState, checkpointIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        recoveredState, recoveredIds, replayedState, replayedIds>>

BeginFirst ==
    /\ phase = "PrefixCommitted"
    /\ preparedState' = visibleState /\ preparedIds' = visibleIds
    /\ expectedGeneration' = headGeneration
    /\ phase' = "FirstPrepared" /\ lastAction' = "BeginFirst"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, headManifest, headRun,
        headGeneration, headBoundary, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds,
        historyCapacity, localState, localIds, recoveredState,
        recoveredIds, replayedState, replayedIds>>

StoreFirstRun ==
    /\ phase = "FirstPrepared"
    /\ storedRuns' = storedRuns \cup {R1}
    /\ phase' = "FirstRunStored" /\ lastAction' = "StoreFirstRun"
    /\ UNCHANGED <<confirmedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRun, manifestBoundary, manifestLedger,
        headManifest, headRun, headGeneration, headBoundary, visibleState,
        visibleIds, checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

ConfirmFirstRun ==
    /\ phase = "FirstRunStored"
    /\ confirmedRuns' = confirmedRuns \cup {R1}
    /\ phase' = "FirstRunConfirmed" /\ lastAction' = "ConfirmFirstRun"
    /\ UNCHANGED <<storedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRun, manifestBoundary, manifestLedger,
        headManifest, headRun, headGeneration, headBoundary, visibleState,
        visibleIds, checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

StoreFirstManifest ==
    /\ phase = "FirstRunConfirmed"
    /\ storedManifests' = storedManifests \cup {M1}
    /\ manifestPrevious' = [manifestPrevious EXCEPT ![M1] = M0]
    /\ manifestRun' = [manifestRun EXCEPT ![M1] = R1]
    /\ manifestBoundary' = [manifestBoundary EXCEPT ![M1] = 1]
    /\ manifestLedger' = [manifestLedger EXCEPT ![M1] = {I1}]
    /\ phase' = "FirstManifestStored"
    /\ lastAction' = "StoreFirstManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, confirmedManifests,
        headManifest, headRun, headGeneration, headBoundary, visibleState,
        visibleIds, checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

ConfirmFirstManifest ==
    /\ phase = "FirstManifestStored"
    /\ confirmedManifests' = confirmedManifests \cup {M1}
    /\ phase' = "FirstReady" /\ lastAction' = "ConfirmFirstManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        manifestPrevious, manifestRun, manifestBoundary, manifestLedger,
        headManifest, headRun, headGeneration, headBoundary, visibleState,
        visibleIds, checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

PublishFirst ==
    /\ phase = "FirstReady" /\ headGeneration = expectedGeneration
    /\ headManifest' = M1 /\ headRun' = R1
    /\ headGeneration' = headGeneration + 1 /\ headBoundary' = 1
    /\ checkpointState' = preparedState /\ checkpointIds' = preparedIds
    /\ laterState' = {} /\ laterIds' = {}
    /\ phase' = "FirstPublished" /\ lastAction' = "PublishFirst"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, visibleState, visibleIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

CommitSuffix ==
    /\ phase = "FirstPublished"
    /\ visibleState' = visibleState \cup {T2}
    /\ visibleIds' = visibleIds \cup {I2}
    /\ laterState' = laterState \cup {T2}
    /\ laterIds' = laterIds \cup {I2}
    /\ localState' = localState \cup {T2}
    /\ localIds' = localIds \cup {I2}
    /\ phase' = "SuffixCommitted" /\ lastAction' = "CommitSuffix"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, headManifest, headRun,
        headGeneration, headBoundary, checkpointState, checkpointIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        recoveredState, recoveredIds, replayedState, replayedIds>>

RejectSecondHistoryCapacity ==
    /\ phase = "SuffixCommitted" /\ historyCapacity = 2
    /\ phase' = "SecondBackpressured"
    /\ lastAction' = "RejectSecondHistoryCapacity"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, headManifest, headRun,
        headGeneration, headBoundary, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

BeginSecond ==
    /\ phase = "SuffixCommitted" /\ historyCapacity = 3
    /\ preparedState' = visibleState /\ preparedIds' = visibleIds
    /\ expectedGeneration' = headGeneration
    /\ phase' = "SecondPrepared" /\ lastAction' = "BeginSecond"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, headManifest, headRun,
        headGeneration, headBoundary, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds,
        historyCapacity, localState, localIds, recoveredState,
        recoveredIds, replayedState, replayedIds>>

StoreSecondRun ==
    /\ phase = "SecondPrepared"
    /\ storedRuns' = storedRuns \cup {R2}
    /\ phase' = "SecondRunStored" /\ lastAction' = "StoreSecondRun"
    /\ UNCHANGED <<confirmedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRun, manifestBoundary, manifestLedger,
        headManifest, headRun, headGeneration, headBoundary, visibleState,
        visibleIds, checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

ConfirmSecondRun ==
    /\ phase = "SecondRunStored"
    /\ confirmedRuns' = confirmedRuns \cup {R2}
    /\ phase' = "SecondRunConfirmed" /\ lastAction' = "ConfirmSecondRun"
    /\ UNCHANGED <<storedRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRun, manifestBoundary, manifestLedger,
        headManifest, headRun, headGeneration, headBoundary, visibleState,
        visibleIds, checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

StoreSecondManifest ==
    /\ phase = "SecondRunConfirmed"
    /\ storedManifests' = storedManifests \cup {M2}
    /\ manifestPrevious' = [manifestPrevious EXCEPT ![M2] = M1]
    /\ manifestRun' = [manifestRun EXCEPT ![M2] = R2]
    /\ manifestBoundary' = [manifestBoundary EXCEPT ![M2] = 2]
    /\ manifestLedger' = [manifestLedger EXCEPT ![M2] = {I1, I2}]
    /\ phase' = "SecondManifestStored"
    /\ lastAction' = "StoreSecondManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, confirmedManifests,
        headManifest, headRun, headGeneration, headBoundary, visibleState,
        visibleIds, checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

ConfirmSecondManifest ==
    /\ phase = "SecondManifestStored"
    /\ confirmedManifests' = confirmedManifests \cup {M2}
    /\ phase' = "SecondReady" /\ lastAction' = "ConfirmSecondManifest"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        manifestPrevious, manifestRun, manifestBoundary, manifestLedger,
        headManifest, headRun, headGeneration, headBoundary, visibleState,
        visibleIds, checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

PublishSecondAs(NewPhase, Action) ==
    /\ phase = "SecondReady" /\ headGeneration = expectedGeneration
    /\ headManifest' = M2 /\ headRun' = R2
    /\ headGeneration' = headGeneration + 1 /\ headBoundary' = 2
    /\ checkpointState' = preparedState /\ checkpointIds' = preparedIds
    /\ laterState' = {} /\ laterIds' = {}
    /\ phase' = NewPhase /\ lastAction' = Action
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, visibleState, visibleIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

PublishSecond == PublishSecondAs("SecondPublished", "PublishSecond")
LoseAcceptedSecondResponse ==
    PublishSecondAs("SecondUnknown", "LoseAcceptedSecondResponse")

ResolveSecond ==
    /\ phase = "SecondUnknown" /\ headManifest = M2
    /\ phase' = "SecondPublished" /\ lastAction' = "ResolveSecond"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, headManifest, headRun,
        headGeneration, headBoundary, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity,
        localState, localIds, recoveredState, recoveredIds, replayedState,
        replayedIds>>

Crash ==
    /\ phase \in {"FirstPublished", "SuffixCommitted", "SecondUnknown",
                    "SecondPublished"}
    /\ localState' = {} /\ localIds' = {}
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ phase' = "Crashed" /\ lastAction' = "Crash"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, headManifest, headRun,
        headGeneration, headBoundary, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity>>

Recover ==
    /\ phase = "Crashed" /\ headManifest \in confirmedManifests
    /\ headRun \in confirmedRuns
    /\ recoveredState' = checkpointState \cup laterState
    /\ recoveredIds' = checkpointIds \cup laterIds
    /\ replayedState' = laterState /\ replayedIds' = laterIds
    /\ localState' = checkpointState \cup laterState
    /\ localIds' = checkpointIds \cup laterIds
    /\ phase' = "Recovered" /\ lastAction' = "Recover"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, manifestPrevious, manifestRun,
        manifestBoundary, manifestLedger, headManifest, headRun,
        headGeneration, headBoundary, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds,
        preparedState, preparedIds, expectedGeneration, historyCapacity>>

Next ==
    \/ CommitPrefix \/ BeginFirst \/ StoreFirstRun \/ ConfirmFirstRun
    \/ StoreFirstManifest \/ ConfirmFirstManifest \/ PublishFirst
    \/ CommitSuffix \/ RejectSecondHistoryCapacity \/ BeginSecond
    \/ StoreSecondRun \/ ConfirmSecondRun \/ StoreSecondManifest
    \/ ConfirmSecondManifest \/ PublishSecond \/ LoseAcceptedSecondResponse
    \/ ResolveSecond \/ Crash \/ Recover

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ storedRuns \subseteq Runs /\ confirmedRuns \subseteq Runs
    /\ storedManifests \subseteq Manifests
    /\ confirmedManifests \subseteq Manifests
    /\ manifestPrevious \in [Manifests -> Manifests \cup {NoManifest}]
    /\ manifestRun \in [Manifests -> Runs \cup {NoRun}]
    /\ manifestBoundary \in [Manifests -> 0 .. 2]
    /\ manifestLedger \in [Manifests -> SUBSET Identities]
    /\ headManifest \in Manifests /\ headRun \in Runs \cup {NoRun}
    /\ headGeneration \in Nat /\ expectedGeneration \in Nat
    /\ headBoundary \in 0 .. 2 /\ historyCapacity \in 2 .. 3
    /\ visibleState \subseteq Transactions /\ checkpointState \subseteq Transactions
    /\ laterState \subseteq Transactions /\ preparedState \subseteq Transactions
    /\ visibleIds \subseteq Identities /\ checkpointIds \subseteq Identities
    /\ laterIds \subseteq Identities /\ preparedIds \subseteq Identities
    /\ localState \subseteq Transactions /\ localIds \subseteq Identities
    /\ recoveredState \subseteq Transactions /\ recoveredIds \subseteq Identities
    /\ replayedState \subseteq Transactions /\ replayedIds \subseteq Identities
    /\ phase \in Phases /\ lastAction \in ActionNames

ConfirmedBytesWereStored ==
    confirmedRuns \subseteq storedRuns
        /\ confirmedManifests \subseteq storedManifests

HeadNamesConfirmedCheckpoint ==
    \/ /\ headManifest = M0 /\ headRun = NoRun /\ headBoundary = 0
    \/ /\ headManifest \in confirmedManifests \ {M0}
       /\ headRun = manifestRun[headManifest]
       /\ headRun \in confirmedRuns
       /\ headBoundary = manifestBoundary[headManifest]

ManifestChainIsExact ==
    /\ (M1 \in storedManifests => manifestPrevious[M1] = M0)
    /\ (M2 \in storedManifests =>
        manifestPrevious[M2] = M1 /\ M1 \in confirmedManifests)

ManifestContentsAreExact ==
    /\ (M1 \in confirmedManifests =>
        manifestRun[M1] = R1 /\ manifestBoundary[M1] = 1
            /\ manifestLedger[M1] = {I1} /\ RunContents[R1] = {T1})
    /\ (M2 \in confirmedManifests =>
        manifestRun[M2] = R2 /\ manifestBoundary[M2] = 2
            /\ manifestLedger[M2] = {I1, I2}
            /\ RunContents[R2] = {T1, T2})

VisibleAuthorityIsPartitioned ==
    /\ visibleState = checkpointState \cup laterState
    /\ checkpointState \cap laterState = {}
    /\ visibleIds = checkpointIds \cup laterIds
    /\ checkpointIds \cap laterIds = {}

HeadCheckpointIsExact ==
    /\ (headManifest = M0 => checkpointState = {} /\ checkpointIds = {})
    /\ (headManifest = M1 => checkpointState = {T1} /\ checkpointIds = {I1})
    /\ (headManifest = M2 =>
        checkpointState = {T1, T2} /\ checkpointIds = {I1, I2})

RecoveryIsExact == phase # "Recovered" \/
    /\ recoveredState = visibleState /\ recoveredIds = visibleIds
    /\ replayedState = laterState /\ replayedIds = laterIds
    /\ localState = visibleState /\ localIds = visibleIds

BackpressureHasNoEffects == phase # "SecondBackpressured" \/
    /\ M2 \notin storedManifests /\ R2 \notin storedRuns
    /\ headManifest = M1 /\ laterState = {T2} /\ laterIds = {I2}

LocalStateIsDisposable == localState \subseteq visibleState /\ localIds \subseteq visibleIds

Safety ==
    /\ TypeOK /\ ConfirmedBytesWereStored /\ HeadNamesConfirmedCheckpoint
    /\ ManifestChainIsExact /\ ManifestContentsAreExact
    /\ VisibleAuthorityIsPartitioned /\ HeadCheckpointIsExact
    /\ RecoveryIsExact /\ BackpressureHasNoEffects /\ LocalStateIsDisposable

=============================================================================
