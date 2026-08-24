---------------------- MODULE L0CompactionSafetyProof ----------------------
EXTENDS Naturals

(***************************************************************************
This unbounded kernel permits arbitrarily many complete L0 replacements.
Each cycle captures exact visible and identity authority, confirms a nonempty
set of new immutable outputs and a successor manifest, then atomically
replaces current run authority at the captured generation. Superseded runs
remain confirmed immutable history. Concrete merge behavior, formats,
capacities, provider outcomes, physical garbage collection, and refinement to
Ada remain outside this proof.
***************************************************************************)

CONSTANTS ManifestIds, RunIds, Transactions, Identities, InitialState,
          InitialIds, NoManifest

ASSUME
    /\ ManifestIds # {} /\ RunIds # {}
    /\ Transactions # {} /\ Identities # {}
    /\ InitialState \subseteq Transactions /\ InitialIds \subseteq Identities
    /\ NoManifest \notin ManifestIds

StablePhases == {"Published", "Recovered"}
Phases == StablePhases \cup {"Preparing"}

VARIABLES storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    currentRuns, retiredRuns, headManifest, headGeneration,
    expectedGeneration, visibleState, visibleIds, checkpointState,
    checkpointIds, laterState, laterIds, preparedState, preparedIds,
    preparedRuns, phase, localState, localIds, recoveredState, recoveredIds,
    replayedState, replayedIds

vars == <<storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    currentRuns, retiredRuns, headManifest, headGeneration,
    expectedGeneration, visibleState, visibleIds, checkpointState,
    checkpointIds, laterState, laterIds, preparedState, preparedIds,
    preparedRuns, phase, localState, localIds, recoveredState, recoveredIds,
    replayedState, replayedIds>>

Init ==
    /\ InitialState \subseteq Transactions /\ InitialIds \subseteq Identities
    /\ storedRuns = {} /\ confirmedRuns = {}
    /\ storedManifests = {} /\ confirmedManifests = {}
    /\ currentRuns = {} /\ retiredRuns = {}
    /\ headManifest = NoManifest /\ headGeneration = 0
    /\ expectedGeneration = 0
    /\ visibleState = InitialState /\ visibleIds = InitialIds
    /\ checkpointState = {} /\ checkpointIds = {}
    /\ laterState = InitialState /\ laterIds = InitialIds
    /\ preparedState = {} /\ preparedIds = {} /\ preparedRuns = {}
    /\ phase = "Published"
    /\ localState = InitialState /\ localIds = InitialIds
    /\ recoveredState = {} /\ recoveredIds = {}
    /\ replayedState = {} /\ replayedIds = {}

StoreRun(r) ==
    /\ r \in RunIds \ storedRuns
    /\ storedRuns' = storedRuns \cup {r}
    /\ UNCHANGED <<confirmedRuns, storedManifests, confirmedManifests,
        currentRuns, retiredRuns, headManifest, headGeneration,
        expectedGeneration, visibleState, visibleIds, checkpointState,
        checkpointIds, laterState, laterIds, preparedState, preparedIds,
        preparedRuns, phase, localState, localIds, recoveredState,
        recoveredIds, replayedState, replayedIds>>

ConfirmRun(r) ==
    /\ r \in storedRuns
    /\ confirmedRuns' = confirmedRuns \cup {r}
    /\ UNCHANGED <<storedRuns, storedManifests, confirmedManifests,
        currentRuns, retiredRuns, headManifest, headGeneration,
        expectedGeneration, visibleState, visibleIds, checkpointState,
        checkpointIds, laterState, laterIds, preparedState, preparedIds,
        preparedRuns, phase, localState, localIds, recoveredState,
        recoveredIds, replayedState, replayedIds>>

StoreManifest(m) ==
    /\ m \in ManifestIds \ storedManifests
    /\ storedManifests' = storedManifests \cup {m}
    /\ UNCHANGED <<storedRuns, confirmedRuns, confirmedManifests,
        currentRuns, retiredRuns, headManifest, headGeneration,
        expectedGeneration, visibleState, visibleIds, checkpointState,
        checkpointIds, laterState, laterIds, preparedState, preparedIds,
        preparedRuns, phase, localState, localIds, recoveredState,
        recoveredIds, replayedState, replayedIds>>

ConfirmManifest(m) ==
    /\ m \in storedManifests
    /\ confirmedManifests' = confirmedManifests \cup {m}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        currentRuns, retiredRuns, headManifest, headGeneration,
        expectedGeneration, visibleState, visibleIds, checkpointState,
        checkpointIds, laterState, laterIds, preparedState, preparedIds,
        preparedRuns, phase, localState, localIds, recoveredState,
        recoveredIds, replayedState, replayedIds>>

BeginCompaction(outputs) ==
    /\ outputs \in SUBSET (RunIds \ storedRuns) /\ outputs # {}
    /\ phase \in StablePhases
    /\ preparedState' = visibleState /\ preparedIds' = visibleIds
    /\ preparedRuns' = outputs /\ expectedGeneration' = headGeneration
    /\ phase' = "Preparing"
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, currentRuns, retiredRuns, headManifest,
        headGeneration, visibleState, visibleIds, checkpointState,
        checkpointIds, laterState, laterIds, localState, localIds>>

Publish(m) ==
    /\ m \in confirmedManifests /\ preparedRuns \subseteq confirmedRuns
    /\ preparedRuns # {} /\ phase = "Preparing"
    /\ headGeneration = expectedGeneration
    /\ headManifest' = m /\ currentRuns' = preparedRuns
    /\ retiredRuns' = retiredRuns \cup currentRuns
    /\ headGeneration' = headGeneration + 1
    /\ checkpointState' = preparedState /\ checkpointIds' = preparedIds
    /\ laterState' = {} /\ laterIds' = {}
    /\ phase' = "Published"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, expectedGeneration, visibleState, visibleIds,
        preparedState, preparedIds, preparedRuns, localState, localIds,
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
        confirmedManifests, currentRuns, retiredRuns, headManifest,
        headGeneration, expectedGeneration, checkpointState, checkpointIds,
        preparedState, preparedIds, preparedRuns>>

Crash ==
    /\ phase \in StablePhases
    /\ localState' = {} /\ localIds' = {}
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ phase' = "Published"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, currentRuns, retiredRuns, headManifest,
        headGeneration, expectedGeneration, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds, preparedState,
        preparedIds, preparedRuns>>

Recover ==
    /\ phase \in StablePhases
    /\ (headManifest = NoManifest \/ headManifest \in confirmedManifests)
    /\ currentRuns \subseteq confirmedRuns
    /\ recoveredState' = checkpointState \cup laterState
    /\ recoveredIds' = checkpointIds \cup laterIds
    /\ replayedState' = laterState /\ replayedIds' = laterIds
    /\ localState' = checkpointState \cup laterState
    /\ localIds' = checkpointIds \cup laterIds
    /\ phase' = "Recovered"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, currentRuns, retiredRuns, headManifest,
        headGeneration, expectedGeneration, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds, preparedState,
        preparedIds, preparedRuns>>

TypeOK ==
    /\ storedRuns \subseteq RunIds /\ confirmedRuns \subseteq RunIds
    /\ storedManifests \subseteq ManifestIds
    /\ confirmedManifests \subseteq ManifestIds
    /\ currentRuns \subseteq RunIds /\ retiredRuns \subseteq RunIds
    /\ headManifest \in ManifestIds \cup {NoManifest}
    /\ headGeneration \in Nat /\ expectedGeneration \in Nat
    /\ visibleState \subseteq Transactions
    /\ checkpointState \subseteq Transactions
    /\ laterState \subseteq Transactions /\ preparedState \subseteq Transactions
    /\ visibleIds \subseteq Identities /\ checkpointIds \subseteq Identities
    /\ laterIds \subseteq Identities /\ preparedIds \subseteq Identities
    /\ preparedRuns \subseteq RunIds
    /\ localState \subseteq Transactions /\ localIds \subseteq Identities
    /\ recoveredState \subseteq Transactions /\ recoveredIds \subseteq Identities
    /\ replayedState \subseteq Transactions /\ replayedIds \subseteq Identities
    /\ phase \in Phases

ConfirmedBytesWereStored ==
    /\ confirmedRuns \subseteq storedRuns
    /\ confirmedManifests \subseteq storedManifests

HeadNamesConfirmedBytes ==
    /\ currentRuns \subseteq confirmedRuns
    /\ (headManifest = NoManifest \/ headManifest \in confirmedManifests)

RetiredRunsAreConfirmedHistory ==
    /\ retiredRuns \subseteq confirmedRuns
    /\ retiredRuns \subseteq storedRuns
    /\ retiredRuns \cap currentRuns = {}

AuthorityIsExactPartition ==
    /\ visibleState = checkpointState \cup laterState
    /\ checkpointState \cap laterState = {}
    /\ visibleIds = checkpointIds \cup laterIds
    /\ checkpointIds \cap laterIds = {}

PreparationIsExact == phase # "Preparing" \/
    (preparedState = visibleState /\ preparedIds = visibleIds
        /\ preparedRuns # {}
        /\ preparedRuns \cap (currentRuns \cup retiredRuns) = {})

RecoveryIsExact == phase # "Recovered" \/
    /\ recoveredState = visibleState /\ recoveredIds = visibleIds
    /\ replayedState = laterState /\ replayedIds = laterIds
    /\ localState = visibleState /\ localIds = visibleIds

LocalStateIsDisposable ==
    localState \subseteq visibleState /\ localIds \subseteq visibleIds

Safety ==
    /\ TypeOK /\ ConfirmedBytesWereStored /\ HeadNamesConfirmedBytes
    /\ RetiredRunsAreConfirmedHistory /\ AuthorityIsExactPartition
    /\ PreparationIsExact /\ RecoveryIsExact /\ LocalStateIsDisposable

THEOREM InitialSafety == Init => Safety
<1>1. Init => TypeOK
<2> QED BY DEF Init, TypeOK, Phases, StablePhases
<1>2. Init => ConfirmedBytesWereStored
<2> QED BY DEF Init, ConfirmedBytesWereStored
<1>3. Init => HeadNamesConfirmedBytes
<2> QED BY DEF Init, HeadNamesConfirmedBytes
<1>4. Init => RetiredRunsAreConfirmedHistory
<2> QED BY DEF Init, RetiredRunsAreConfirmedHistory
<1>5. Init => AuthorityIsExactPartition
<2> QED BY DEF Init, AuthorityIsExactPartition
<1>6. Init => PreparationIsExact
<2> QED BY DEF Init, PreparationIsExact
<1>7. Init => RecoveryIsExact
<2> QED BY DEF Init, RecoveryIsExact
<1>8. Init => LocalStateIsDisposable
<2> QED BY DEF Init, LocalStateIsDisposable
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8 DEF Safety

THEOREM StoreRunPreservesSafety ==
    \A r \in RunIds : Safety /\ StoreRun(r) => Safety'
<1> QED BY DEF StoreRun, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, RetiredRunsAreConfirmedHistory,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

THEOREM ConfirmRunPreservesSafety ==
    \A r \in RunIds : Safety /\ ConfirmRun(r) => Safety'
<1> QED BY DEF ConfirmRun, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, RetiredRunsAreConfirmedHistory,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

THEOREM StoreManifestPreservesSafety ==
    \A m \in ManifestIds : Safety /\ StoreManifest(m) => Safety'
<1> QED BY DEF StoreManifest, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, RetiredRunsAreConfirmedHistory,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

THEOREM ConfirmManifestPreservesSafety ==
    \A m \in ManifestIds : Safety /\ ConfirmManifest(m) => Safety'
<1> QED BY DEF ConfirmManifest, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, RetiredRunsAreConfirmedHistory,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

THEOREM BeginCompactionPreservesSafety ==
    \A outputs \in SUBSET RunIds : Safety /\ BeginCompaction(outputs) => Safety'
<1> QED BY DEF BeginCompaction, Safety, TypeOK,
    ConfirmedBytesWereStored, HeadNamesConfirmedBytes,
    RetiredRunsAreConfirmedHistory, AuthorityIsExactPartition,
    PreparationIsExact, RecoveryIsExact, LocalStateIsDisposable,
    Phases, StablePhases

THEOREM PublishPreservesSafety ==
    \A m \in ManifestIds : Safety /\ Publish(m) => Safety'
<1> QED BY DEF Publish, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, RetiredRunsAreConfirmedHistory,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

THEOREM CommitLaterPreservesSafety ==
    \A t \in Transactions, i \in Identities :
        Safety /\ CommitLater(t, i) => Safety'
<1> QED BY DEF CommitLater, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, RetiredRunsAreConfirmedHistory,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> QED BY DEF Crash, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, RetiredRunsAreConfirmedHistory,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

THEOREM RecoverPreservesSafety == Safety /\ Recover => Safety'
<1> QED BY DEF Recover, Safety, TypeOK, ConfirmedBytesWereStored,
    HeadNamesConfirmedBytes, RetiredRunsAreConfirmedHistory,
    AuthorityIsExactPartition, PreparationIsExact, RecoveryIsExact,
    LocalStateIsDisposable, Phases, StablePhases

=============================================================================
