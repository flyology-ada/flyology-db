------------------------ MODULE CheckpointSafetyProof ------------------------
EXTENDS Naturals

(***************************************************************************
This unbounded kernel abstracts complete sorted run bytes and one immutable
manifest to confirmed identities plus their exact logical checkpoint. TLC,
not this module, checks per-family reconstruction, corruption, capacities,
reconciliation branches, and witnesses. No codec/refinement claim is made.
***************************************************************************)

CONSTANTS ManifestIds, RunIds, Families, Transactions, Identities,
          InitialState, InitialIds, NoManifest

ASSUME
    /\ ManifestIds # {}
    /\ RunIds # {}
    /\ Families # {}
    /\ Transactions # {}
    /\ Identities # {}
    /\ InitialState \subseteq Transactions
    /\ InitialIds \subseteq Identities
    /\ NoManifest \notin ManifestIds

VARIABLES storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    registry, headManifest, headRuns, headGeneration, expectedGeneration,
    visibleState, visibleIds, checkpointState, checkpointIds,
    laterState, laterIds, phase, localRuns, localManifests, localState,
    recoveryPhase, recoveredState, recoveredIds, replayedState, replayedIds

vars == <<storedRuns, confirmedRuns, storedManifests, confirmedManifests,
    registry, headManifest, headRuns, headGeneration, expectedGeneration,
    visibleState, visibleIds, checkpointState, checkpointIds,
    laterState, laterIds, phase, localRuns, localManifests, localState,
    recoveryPhase, recoveredState, recoveredIds, replayedState, replayedIds>>

Init ==
    /\ InitialState \subseteq Transactions
    /\ InitialIds \subseteq Identities
    /\ storedRuns = {} /\ confirmedRuns = {}
    /\ storedManifests = {} /\ confirmedManifests = {}
    /\ registry = Families
    /\ headManifest = NoManifest /\ headRuns = {}
    /\ headGeneration = 0 /\ expectedGeneration = 0
    /\ visibleState = InitialState /\ visibleIds = InitialIds
    /\ checkpointState = {} /\ checkpointIds = {}
    /\ laterState = InitialState /\ laterIds = InitialIds
    /\ phase = "Preparing"
    /\ localRuns = {} /\ localManifests = {}
    /\ localState = InitialState
    /\ recoveryPhase = "NotRecovered"
    /\ recoveredState = {} /\ recoveredIds = {}
    /\ replayedState = {} /\ replayedIds = {}

StoreRun(r) ==
    /\ r \in RunIds \ storedRuns
    /\ storedRuns' = storedRuns \cup {r}
    /\ localRuns' = localRuns \cup {r}
    /\ UNCHANGED <<confirmedRuns, storedManifests, confirmedManifests,
        registry, headManifest, headRuns, headGeneration, expectedGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds, laterState,
        laterIds, phase, localManifests, localState, recoveryPhase,
        recoveredState, recoveredIds, replayedState, replayedIds>>

ConfirmRun(r) ==
    /\ r \in storedRuns
    /\ confirmedRuns' = confirmedRuns \cup {r}
    /\ UNCHANGED <<storedRuns, storedManifests, confirmedManifests, registry,
        headManifest, headRuns, headGeneration, expectedGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds, laterState,
        laterIds, phase, localRuns, localManifests, localState,
        recoveryPhase, recoveredState, recoveredIds, replayedState,
        replayedIds>>

StoreManifest(m) ==
    /\ m \in ManifestIds \ storedManifests
    /\ storedManifests' = storedManifests \cup {m}
    /\ localManifests' = localManifests \cup {m}
    /\ UNCHANGED <<storedRuns, confirmedRuns, confirmedManifests, registry,
        headManifest, headRuns, headGeneration, expectedGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds, laterState,
        laterIds, phase, localRuns, localState, recoveryPhase,
        recoveredState, recoveredIds, replayedState, replayedIds>>

ConfirmManifest(m) ==
    /\ m \in storedManifests
    /\ confirmedManifests' = confirmedManifests \cup {m}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests, registry,
        headManifest, headRuns, headGeneration, expectedGeneration,
        visibleState, visibleIds, checkpointState, checkpointIds, laterState,
        laterIds, phase, localRuns, localManifests, localState,
        recoveryPhase, recoveredState, recoveredIds, replayedState,
        replayedIds>>

Publish(m, runs) ==
    /\ phase = "Preparing"
    /\ m \in confirmedManifests
    /\ runs \subseteq confirmedRuns
    /\ headGeneration = expectedGeneration
    /\ headManifest' = m /\ headRuns' = runs
    /\ headGeneration' = headGeneration + 1
    /\ checkpointState' = visibleState /\ checkpointIds' = visibleIds
    /\ laterState' = {} /\ laterIds' = {}
    /\ phase' = "Published"
    /\ recoveryPhase' = "NotRecovered"
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, registry, expectedGeneration, visibleState,
        visibleIds, localRuns, localManifests, localState>>

CommitLater(t, identity) ==
    /\ phase = "Published"
    /\ t \in Transactions \ visibleState
    /\ identity \in Identities \ visibleIds
    /\ visibleState' = visibleState \cup {t}
    /\ visibleIds' = visibleIds \cup {identity}
    /\ laterState' = laterState \cup {t}
    /\ laterIds' = laterIds \cup {identity}
    /\ localState' = localState \cup {t}
    /\ recoveryPhase' = "NotRecovered"
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, registry, headManifest, headRuns,
        headGeneration, expectedGeneration, checkpointState, checkpointIds,
        phase, localRuns, localManifests>>

RivalTransition ==
    /\ phase = "Preparing"
    /\ headGeneration' = headGeneration + 1
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, registry, headManifest, headRuns,
        expectedGeneration, visibleState, visibleIds, checkpointState,
        checkpointIds, laterState, laterIds, phase, localRuns,
        localManifests, localState, recoveryPhase, recoveredState,
        recoveredIds, replayedState, replayedIds>>

Crash ==
    /\ localRuns' = {} /\ localManifests' = {} /\ localState' = {}
    /\ recoveryPhase' = "NotRecovered"
    /\ recoveredState' = {} /\ recoveredIds' = {}
    /\ replayedState' = {} /\ replayedIds' = {}
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, registry, headManifest, headRuns,
        headGeneration, expectedGeneration, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds, phase>>

Recover ==
    /\ headManifest \in confirmedManifests
    /\ headRuns \subseteq confirmedRuns
    /\ recoveredState' = checkpointState \cup laterState
    /\ recoveredIds' = checkpointIds \cup laterIds
    /\ replayedState' = laterState /\ replayedIds' = laterIds
    /\ localRuns' = headRuns /\ localManifests' = {headManifest}
    /\ localState' = checkpointState \cup laterState
    /\ recoveryPhase' = "Recovered"
    /\ UNCHANGED <<storedRuns, confirmedRuns, storedManifests,
        confirmedManifests, registry, headManifest, headRuns,
        headGeneration, expectedGeneration, visibleState, visibleIds,
        checkpointState, checkpointIds, laterState, laterIds, phase>>

Next ==
    \/ \E r \in RunIds : StoreRun(r)
    \/ \E r \in RunIds : ConfirmRun(r)
    \/ \E m \in ManifestIds : StoreManifest(m)
    \/ \E m \in ManifestIds : ConfirmManifest(m)
    \/ \E m \in ManifestIds, runs \in SUBSET RunIds : Publish(m, runs)
    \/ \E t \in Transactions, i \in Identities : CommitLater(t, i)
    \/ RivalTransition \/ Crash \/ Recover

Spec == Init /\ [][Next]_vars

StorageTypeOK ==
    /\ storedRuns \subseteq RunIds /\ confirmedRuns \subseteq RunIds
    /\ storedManifests \subseteq ManifestIds
    /\ confirmedManifests \subseteq ManifestIds
    /\ registry \subseteq Families
    /\ headManifest \in ManifestIds \cup {NoManifest}
    /\ headRuns \subseteq RunIds

AuthorityTypeOK ==
    /\ headGeneration \in Nat
    /\ expectedGeneration \in Nat
    /\ visibleState \subseteq Transactions /\ visibleIds \subseteq Identities
    /\ checkpointState \subseteq Transactions
    /\ checkpointIds \subseteq Identities
    /\ laterState \subseteq Transactions /\ laterIds \subseteq Identities

CacheTypeOK ==
    /\ phase \in {"Preparing", "Published"}
    /\ localRuns \subseteq RunIds /\ localManifests \subseteq ManifestIds
    /\ localState \subseteq Transactions
    /\ recoveryPhase \in {"NotRecovered", "Recovered"}
    /\ recoveredState \subseteq Transactions
    /\ recoveredIds \subseteq Identities
    /\ replayedState \subseteq Transactions
    /\ replayedIds \subseteq Identities

TypeOK == StorageTypeOK /\ AuthorityTypeOK /\ CacheTypeOK

ConfirmedBytesWereStored ==
    confirmedRuns \subseteq storedRuns /\ confirmedManifests \subseteq storedManifests
HeadNamesOnlyConfirmedBytes ==
    headManifest = NoManifest \/ (headManifest \in confirmedManifests /\ headRuns \subseteq confirmedRuns)
RegistryIsImmutable == registry = Families
AuthorityIsExactPartition ==
    /\ visibleState = checkpointState \cup laterState
    /\ checkpointState \cap laterState = {}
    /\ visibleIds = checkpointIds \cup laterIds
    /\ checkpointIds \cap laterIds = {}
NoCheckpointReplay ==
    /\ replayedState \subseteq laterState
    /\ replayedState \cap checkpointState = {}
    /\ replayedIds \subseteq laterIds
    /\ replayedIds \cap checkpointIds = {}
RecoveryIsExact == recoveryPhase # "Recovered" \/
    (recoveredState = checkpointState \cup laterState /\
     recoveredIds = checkpointIds \cup laterIds /\
     replayedState = laterState /\ replayedIds = laterIds)
LocalIsOnlyACache ==
    /\ localRuns \subseteq storedRuns
    /\ localManifests \subseteq storedManifests
    /\ localState \subseteq visibleState
Safety == TypeOK /\ ConfirmedBytesWereStored /\ HeadNamesOnlyConfirmedBytes /\
    RegistryIsImmutable /\ AuthorityIsExactPartition /\ NoCheckpointReplay /\
    RecoveryIsExact /\ LocalIsOnlyACache

THEOREM PublishUsesExactExpectedGeneration ==
    \A m \in ManifestIds, runs \in SUBSET RunIds :
        Safety /\ Publish(m, runs) =>
            headGeneration = expectedGeneration /\ headGeneration' = headGeneration + 1
<1> QED BY DEF Publish

THEOREM InitialSafety == Init => Safety
<1>1. Init => TypeOK
<2>1. Init => StorageTypeOK
<3> QED BY DEF Init, StorageTypeOK
<2>2. Init => AuthorityTypeOK
<3> QED BY DEF Init, AuthorityTypeOK
<2>3. Init => CacheTypeOK
<3> QED BY DEF Init, CacheTypeOK
<2> QED BY <2>1, <2>2, <2>3 DEF TypeOK
<1>2. Init => ConfirmedBytesWereStored
<2> QED BY DEF Init, ConfirmedBytesWereStored
<1>3. Init => HeadNamesOnlyConfirmedBytes
<2> QED BY DEF Init, HeadNamesOnlyConfirmedBytes
<1>4. Init => RegistryIsImmutable
<2> QED BY DEF Init, RegistryIsImmutable
<1>5. Init => AuthorityIsExactPartition
<2> QED BY DEF Init, AuthorityIsExactPartition
<1>6. Init => NoCheckpointReplay
<2> QED BY DEF Init, NoCheckpointReplay
<1>7. Init => RecoveryIsExact
<2> QED BY DEF Init, RecoveryIsExact
<1>8. Init => LocalIsOnlyACache
<2> QED BY DEF Init, LocalIsOnlyACache
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8
    DEF Safety

THEOREM StoreRunPreservesSafety ==
    \A r \in RunIds : Safety /\ StoreRun(r) => Safety'
<1> QED BY DEF StoreRun, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM ConfirmRunPreservesSafety ==
    \A r \in RunIds : Safety /\ ConfirmRun(r) => Safety'
<1> QED BY DEF ConfirmRun, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM StoreManifestPreservesSafety ==
    \A m \in ManifestIds : Safety /\ StoreManifest(m) => Safety'
<1> QED BY DEF StoreManifest, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM ConfirmManifestPreservesSafety ==
    \A m \in ManifestIds : Safety /\ ConfirmManifest(m) => Safety'
<1> QED BY DEF ConfirmManifest, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM PublishPreservesSafety ==
    \A m \in ManifestIds, runs \in SUBSET RunIds :
        Safety /\ Publish(m, runs) => Safety'
<1> QED BY DEF Publish, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM CommitLaterPreservesSafety ==
    \A t \in Transactions, i \in Identities :
        Safety /\ CommitLater(t, i) => Safety'
<1> QED BY DEF CommitLater, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM RivalPreservesSafety == Safety /\ RivalTransition => Safety'
<1> QED BY DEF RivalTransition, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> QED BY DEF Crash, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM RecoverPreservesSafety == Safety /\ Recover => Safety'
<1> QED BY DEF Recover, Safety, TypeOK, ConfirmedBytesWereStored,
    StorageTypeOK, AuthorityTypeOK, CacheTypeOK,
    HeadNamesOnlyConfirmedBytes, RegistryIsImmutable, AuthorityIsExactPartition,
    NoCheckpointReplay, RecoveryIsExact, LocalIsOnlyACache

THEOREM NextPreservesSafety == Safety /\ Next => Safety'
<1> QED BY StoreRunPreservesSafety, ConfirmRunPreservesSafety,
    StoreManifestPreservesSafety, ConfirmManifestPreservesSafety,
    PublishPreservesSafety, CommitLaterPreservesSafety, RivalPreservesSafety,
    CrashPreservesSafety, RecoverPreservesSafety DEF Next

=============================================================================
