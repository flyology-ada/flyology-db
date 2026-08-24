--------------------- MODULE L0AccumulationSafetyProof ---------------------
EXTENDS Naturals

(***************************************************************************
This unbounded kernel permits arbitrarily many additive L0 publications.
Each cycle captures exact visible/identity authority, confirms one new
immutable run and manifest, and appends the run to current authority without
rewriting earlier stored runs. Concrete tombstone merge is checked by the
finite model; formats, capacities, provider behavior, and refinement to Ada
remain outside this proof.
***************************************************************************)

CONSTANTS ManifestIds, RunIds, Transactions, Identities, InitialState,
          InitialIds, NoManifest, NoRun

ASSUME
    /\ ManifestIds # {} /\ RunIds # {}
    /\ Transactions # {} /\ Identities # {}
    /\ InitialState \subseteq Transactions /\ InitialIds \subseteq Identities
    /\ NoManifest \notin ManifestIds /\ NoRun \notin RunIds

StablePhases == {"Published", "Recovered"}
Phases == StablePhases \cup {"Preparing"}

VARIABLES storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    currentRuns, headManifest, headGeneration, expectedGeneration,
    visibleState, visibleIds, checkpointState, checkpointIds,
    laterState, laterIds, preparedState, preparedIds, preparedRun, phase,
    localState, localIds, recoveredState, recoveredIds,
    replayedState, replayedIds

vars == <<storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    currentRuns, headManifest, headGeneration, expectedGeneration,
    visibleState, visibleIds, checkpointState, checkpointIds,
    laterState, laterIds, preparedState, preparedIds, preparedRun, phase,
    localState, localIds, recoveredState, recoveredIds,
    replayedState, replayedIds>>

Init ==
    /\ InitialState \subseteq Transactions /\ InitialIds \subseteq Identities
    /\ storedRuns = {} /\ confirmedRuns = {}
    /\ storedManifests = {} /\ confirmedManifests = {}
    /\ currentRuns = {} /\ headManifest = NoManifest
    /\ headGeneration = 0 /\ expectedGeneration = 0
    /\ visibleState = InitialState /\ visibleIds = InitialIds
    /\ checkpointState = {} /\ checkpointIds = {}
    /\ laterState = InitialState /\ laterIds = InitialIds
    /\ preparedState = {} /\ preparedIds = {} /\ preparedRun = NoRun
    /\ phase = "Published"
    /\ localState = InitialState /\ localIds = InitialIds
    /\ recoveredState = {} /\ recoveredIds = {}
    /\ replayedState = {} /\ replayedIds = {}

StoreRun(r) ==
    /\ r \in RunIds \ storedRuns
    /\ storedRuns' = storedRuns \cup {r}
    /\ UNCHANGED <<confirmedRuns, storedManifests, confirmedManifests,
        currentRuns, headManifest, headGeneration, expectedGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds,
        laterState, laterIds, preparedState, preparedIds, preparedRun,
        phase, localState, localIds, recoveredState, recoveredIds,
        replayedState, replayedIds>>

ConfirmRun(r) ==
    /\ r \in storedRuns
    /\ confirmedRuns' = confirmedRuns \cup {r}
    /\ UNCHANGED <<storedRuns, storedManifests, confirmedManifests,
        currentRuns, headManifest, headGeneration, expectedGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds,
        laterState, laterIds, preparedState, preparedIds, preparedRun,
        phase, localState, localIds, recoveredState, recoveredIds,
        replayedState, replayedIds>>

StoreManifest(m) ==
    /\ m \in ManifestIds \ storedManifests
    /\ storedManifests' = storedManifests \cup {m}
    /\ UNCHANGED <<storedRuns, confirmedRuns, confirmedManifests,
        currentRuns, headManifest, headGeneration, expectedGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds,
        laterState, laterIds, preparedState, preparedIds, preparedRun,
        phase, localState, localIds, recoveredState, recoveredIds,
        replayedState, replayedIds>>

ConfirmManifest(m) ==
    /\ m \in storedManifests
    /\ confirmedManifests' = confirmedManifests \cup {m}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        currentRuns, headManifest, headGeneration, expectedGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds,
        laterState, laterIds, preparedState, preparedIds, preparedRun,
        phase, localState, localIds, recoveredState, recoveredIds,
        replayedState, replayedIds>>

BeginAccumulation(r) ==
    /\ r \in RunIds \ storedRuns /\ phase \in StablePhases
    /\ preparedState' = visibleState /\ preparedIds' = visibleIds
    /\ preparedRun' = r /\ expectedGeneration' = headGeneration
    /\ phase' = "Preparing"
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, currentRuns, headManifest, headGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds,
        laterState, laterIds, localState, localIds>>

Publish(m, r) ==
    /\ m \in confirmedManifests /\ r = preparedRun /\ r \in confirmedRuns
    /\ phase = "Preparing" /\ headGeneration = expectedGeneration
    /\ headManifest' = m /\ currentRuns' = currentRuns \cup {r}
    /\ headGeneration' = headGeneration + 1
    /\ checkpointState' = preparedState /\ checkpointIds' = preparedIds
    /\ laterState' = {} /\ laterIds' = {}
    /\ phase' = "Published"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, expectedGeneration, visibleState, visibleIds,
        preparedState, preparedIds, preparedRun, localState, localIds,
        recoveredState, recoveredIds, replayedState, replayedIds>>

CommitLater(t, i) ==
    /\ t \in Transactions \ visibleState /\ i \in Identities \ visibleIds
    /\ phase \in StablePhases
    /\ visibleState' = visibleState \cup {t}
    /\ visibleIds' = visibleIds \cup {i}
    /\ laterState' = laterState \cup {t}
    /\ laterIds' = laterIds \cup {i}
    /\ localState' = localState \cup {t}
    /\ localIds' = localIds \cup {i}
    /\ phase' = "Published"
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, currentRuns, headManifest, headGeneration,
        expectedGeneration, checkpointState, checkpointIds,
        preparedState, preparedIds, preparedRun>>

Crash ==
    /\ phase \in StablePhases
    /\ localState' = {} /\ localIds' = {}
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ phase' = "Published"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, currentRuns, headManifest, headGeneration,
        expectedGeneration, visibleState, visibleIds, checkpointState,
        checkpointIds, laterState, laterIds, preparedState, preparedIds,
        preparedRun>>

Recover ==
    /\ phase \in StablePhases
    /\ headManifest \in confirmedManifests /\ currentRuns \subseteq confirmedRuns
    /\ recoveredState' = checkpointState \cup laterState
    /\ recoveredIds' = checkpointIds \cup laterIds
    /\ replayedState' = laterState /\ replayedIds' = laterIds
    /\ localState' = checkpointState \cup laterState
    /\ localIds' = checkpointIds \cup laterIds
    /\ phase' = "Recovered"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, currentRuns, headManifest, headGeneration,
        expectedGeneration, visibleState, visibleIds, checkpointState,
        checkpointIds, laterState, laterIds, preparedState, preparedIds,
        preparedRun>>

TypeOK ==
    /\ storedRuns \subseteq RunIds /\ confirmedRuns \subseteq RunIds
    /\ storedManifests \subseteq ManifestIds
    /\ confirmedManifests \subseteq ManifestIds
    /\ currentRuns \subseteq RunIds
    /\ headManifest \in ManifestIds \cup {NoManifest}
    /\ headGeneration \in Nat /\ expectedGeneration \in Nat
    /\ visibleState \subseteq Transactions /\ checkpointState \subseteq Transactions
    /\ laterState \subseteq Transactions /\ preparedState \subseteq Transactions
    /\ visibleIds \subseteq Identities /\ checkpointIds \subseteq Identities
    /\ laterIds \subseteq Identities /\ preparedIds \subseteq Identities
    /\ preparedRun \in RunIds \cup {NoRun}
    /\ localState \subseteq Transactions /\ localIds \subseteq Identities
    /\ recoveredState \subseteq Transactions /\ recoveredIds \subseteq Identities
    /\ replayedState \subseteq Transactions /\ replayedIds \subseteq Identities
    /\ phase \in Phases

ConfirmedBytesWereStored ==
    confirmedRuns \subseteq storedRuns
        /\ confirmedManifests \subseteq storedManifests

HeadNamesConfirmedBytes ==
    /\ currentRuns \subseteq confirmedRuns
    /\ (headManifest = NoManifest \/ headManifest \in confirmedManifests)

AuthorityIsExactPartition ==
    /\ visibleState = checkpointState \cup laterState
    /\ checkpointState \cap laterState = {}
    /\ visibleIds = checkpointIds \cup laterIds
    /\ checkpointIds \cap laterIds = {}

PreparationIsExact == phase # "Preparing" \/
    (preparedState = visibleState /\ preparedIds = visibleIds
        /\ preparedRun \in RunIds)

RecoveryIsExact == phase # "Recovered" \/
    /\ recoveredState = visibleState /\ recoveredIds = visibleIds
    /\ replayedState = laterState /\ replayedIds = laterIds
    /\ localState = visibleState /\ localIds = visibleIds

LocalStateIsDisposable == localState \subseteq visibleState /\ localIds \subseteq visibleIds

Safety ==
    /\ TypeOK /\ ConfirmedBytesWereStored /\ HeadNamesConfirmedBytes
    /\ AuthorityIsExactPartition /\ PreparationIsExact
    /\ RecoveryIsExact /\ LocalStateIsDisposable

THEOREM InitialSafety == Init => Safety
<1>1. Init => TypeOK
<2> QED BY DEF Init, TypeOK, Phases, StablePhases
<1>2. Init => ConfirmedBytesWereStored
<2> QED BY DEF Init, ConfirmedBytesWereStored
<1>3. Init => HeadNamesConfirmedBytes
<2> QED BY DEF Init, HeadNamesConfirmedBytes
<1>4. Init => AuthorityIsExactPartition
<2> QED BY DEF Init, AuthorityIsExactPartition
<1>5. Init => PreparationIsExact
<2> QED BY DEF Init, PreparationIsExact
<1>6. Init => RecoveryIsExact
<2> QED BY DEF Init, RecoveryIsExact
<1>7. Init => LocalStateIsDisposable
<2> QED BY DEF Init, LocalStateIsDisposable
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM StoreRunPreservesSafety ==
    \A r \in RunIds : Safety /\ StoreRun(r) => Safety'
<1> QED BY DEF StoreRun, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, AuthorityIsExactPartition, PreparationIsExact,
    RecoveryIsExact, LocalStateIsDisposable, Phases, StablePhases

THEOREM ConfirmRunPreservesSafety ==
    \A r \in RunIds : Safety /\ ConfirmRun(r) => Safety'
<1> QED BY DEF ConfirmRun, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, AuthorityIsExactPartition, PreparationIsExact,
    RecoveryIsExact, LocalStateIsDisposable, Phases, StablePhases

THEOREM StoreManifestPreservesSafety ==
    \A m \in ManifestIds : Safety /\ StoreManifest(m) => Safety'
<1> QED BY DEF StoreManifest, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, AuthorityIsExactPartition, PreparationIsExact,
    RecoveryIsExact, LocalStateIsDisposable, Phases, StablePhases

THEOREM ConfirmManifestPreservesSafety ==
    \A m \in ManifestIds : Safety /\ ConfirmManifest(m) => Safety'
<1> QED BY DEF ConfirmManifest, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, AuthorityIsExactPartition, PreparationIsExact,
    RecoveryIsExact, LocalStateIsDisposable, Phases, StablePhases

THEOREM BeginAccumulationPreservesSafety ==
    \A r \in RunIds : Safety /\ BeginAccumulation(r) => Safety'
<1> QED BY DEF BeginAccumulation, Safety, TypeOK,
    ConfirmedBytesWereStored, HeadNamesConfirmedBytes,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

THEOREM PublishPreservesSafety ==
    \A m \in ManifestIds, r \in RunIds : Safety /\ Publish(m, r) => Safety'
<1> QED BY DEF Publish, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, AuthorityIsExactPartition, PreparationIsExact,
    RecoveryIsExact, LocalStateIsDisposable, Phases, StablePhases

THEOREM CommitLaterPreservesSafety ==
    \A t \in Transactions, i \in Identities :
        Safety /\ CommitLater(t, i) => Safety'
<1> QED BY DEF CommitLater, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, AuthorityIsExactPartition, PreparationIsExact,
    RecoveryIsExact, LocalStateIsDisposable, Phases, StablePhases

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> QED BY DEF Crash, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, AuthorityIsExactPartition, PreparationIsExact,
    RecoveryIsExact, LocalStateIsDisposable, Phases, StablePhases

THEOREM RecoverPreservesSafety == Safety /\ Recover => Safety'
<1> QED BY DEF Recover, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, AuthorityIsExactPartition, PreparationIsExact,
    RecoveryIsExact, LocalStateIsDisposable, Phases, StablePhases

=============================================================================
