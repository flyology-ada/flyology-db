------------------------- MODULE ManifestPublication -------------------------
EXTENDS FiniteSets, Naturals, TLC

CONSTANTS M1, M2, F1, F2, C1, C2, NoManifest, NoConfig

ManifestIds == {M1, M2}
Families == {F1, F2}
Configs == {C1, C2}
Phases == {"Idle", "PutUnknown", "Stored", "HeadAccepted", "HeadUnknown",
           "Committed", "Failed"}

EmptyRegistry == [f \in Families |-> NoConfig]
RootRegistry == [EmptyRegistry EXCEPT ![F1] = C1]
SuccessorRegistry == [RootRegistry EXCEPT ![F2] = C2]

VARIABLES
    stored,
    confirmed,
    previous,
    registry,
    latestManifest,
    headOrdinal,
    attemptedOrdinal,
    phase,
    putWasUnknown,
    headWasUnknown,
    resolvedCommitted,
    resolvedFailed,
    local,
    recoveredManifest,
    recoveredRegistry,
    crashObserved,
    lastAction

vars == <<
    stored,
    confirmed,
    previous,
    registry,
    latestManifest,
    headOrdinal,
    attemptedOrdinal,
    phase,
    putWasUnknown,
    headWasUnknown,
    resolvedCommitted,
    resolvedFailed,
    local,
    recoveredManifest,
    recoveredRegistry,
    crashObserved,
    lastAction
>>

ReachableManifests ==
    IF latestManifest = NoManifest
    THEN {}
    ELSE IF previous[latestManifest] = NoManifest
         THEN {latestManifest}
         ELSE {latestManifest, previous[latestManifest]}

Init ==
    /\ stored = {}
    /\ confirmed = {}
    /\ previous = [m \in ManifestIds |-> NoManifest]
    /\ registry = [m \in ManifestIds |-> EmptyRegistry]
    /\ latestManifest = NoManifest
    /\ headOrdinal = 0
    /\ attemptedOrdinal = [m \in ManifestIds |-> 0]
    /\ phase = [m \in ManifestIds |-> "Idle"]
    /\ putWasUnknown = {}
    /\ headWasUnknown = {}
    /\ resolvedCommitted = {}
    /\ resolvedFailed = {}
    /\ local = {}
    /\ recoveredManifest = NoManifest
    /\ recoveredRegistry = EmptyRegistry
    /\ crashObserved = FALSE
    /\ lastAction = "Init"

StoreRoot ==
    /\ M1 \notin stored
    /\ phase[M1] = "Idle"
    /\ stored' = stored \cup {M1}
    /\ confirmed' = confirmed \cup {M1}
    /\ registry' = [registry EXCEPT ![M1] = RootRegistry]
    /\ phase' = [phase EXCEPT ![M1] = "Stored"]
    /\ local' = local \cup {M1}
    /\ lastAction' = "StoreRoot"
    /\ UNCHANGED <<
        previous, latestManifest, headOrdinal, attemptedOrdinal, putWasUnknown,
        headWasUnknown, resolvedCommitted, resolvedFailed,
        recoveredManifest, recoveredRegistry, crashObserved
       >>

LoseRootPutResponseStored ==
    /\ M1 \notin stored
    /\ phase[M1] = "Idle"
    /\ stored' = stored \cup {M1}
    /\ registry' = [registry EXCEPT ![M1] = RootRegistry]
    /\ phase' = [phase EXCEPT ![M1] = "PutUnknown"]
    /\ putWasUnknown' = putWasUnknown \cup {M1}
    /\ local' = local \cup {M1}
    /\ lastAction' = "LoseRootPutResponseStored"
    /\ UNCHANGED <<
        confirmed, previous, latestManifest, headOrdinal, attemptedOrdinal,
        headWasUnknown, resolvedCommitted, resolvedFailed,
        recoveredManifest, recoveredRegistry, crashObserved
       >>

LoseRootPutResponseAbsent ==
    /\ M1 \notin stored
    /\ phase[M1] = "Idle"
    /\ phase' = [phase EXCEPT ![M1] = "PutUnknown"]
    /\ putWasUnknown' = putWasUnknown \cup {M1}
    /\ lastAction' = "LoseRootPutResponseAbsent"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, headWasUnknown, resolvedCommitted, resolvedFailed,
        local, recoveredManifest, recoveredRegistry, crashObserved
       >>

ConfirmRootBytes ==
    /\ M1 \in stored
    /\ registry[M1] = RootRegistry
    /\ phase[M1] = "PutUnknown"
    /\ confirmed' = confirmed \cup {M1}
    /\ phase' = [phase EXCEPT ![M1] = "Stored"]
    /\ lastAction' = "ConfirmRootBytes"
    /\ UNCHANGED <<
        stored, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, putWasUnknown, headWasUnknown, resolvedCommitted,
        resolvedFailed, local, recoveredManifest, recoveredRegistry,
        crashObserved
       >>

ResolveRootPutAbsent ==
    /\ M1 \notin stored
    /\ phase[M1] = "PutUnknown"
    /\ phase' = [phase EXCEPT ![M1] = "Failed"]
    /\ lastAction' = "ResolveRootPutAbsent"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, putWasUnknown, headWasUnknown, resolvedCommitted,
        resolvedFailed, local, recoveredManifest, recoveredRegistry,
        crashObserved
       >>

PublishRoot ==
    /\ latestManifest = NoManifest
    /\ M1 \in confirmed
    /\ phase[M1] = "Stored"
    /\ latestManifest' = M1
    /\ headOrdinal' = 1
    /\ attemptedOrdinal' = [attemptedOrdinal EXCEPT ![M1] = 1]
    /\ phase' = [phase EXCEPT ![M1] = "HeadAccepted"]
    /\ lastAction' = "PublishRoot"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, putWasUnknown, headWasUnknown,
        resolvedCommitted, resolvedFailed, local,
        recoveredManifest, recoveredRegistry, crashObserved
       >>

LoseAcceptedRootResponse ==
    /\ phase[M1] = "HeadAccepted"
    /\ phase' = [phase EXCEPT ![M1] = "HeadUnknown"]
    /\ headWasUnknown' = headWasUnknown \cup {M1}
    /\ lastAction' = "LoseAcceptedRootResponse"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, putWasUnknown, resolvedCommitted, resolvedFailed,
        local, recoveredManifest, recoveredRegistry, crashObserved
       >>

LoseUnacceptedRootResponse ==
    /\ latestManifest = NoManifest
    /\ M1 \in confirmed
    /\ phase[M1] = "Stored"
    /\ attemptedOrdinal' = [attemptedOrdinal EXCEPT ![M1] = 1]
    /\ phase' = [phase EXCEPT ![M1] = "HeadUnknown"]
    /\ headWasUnknown' = headWasUnknown \cup {M1}
    /\ lastAction' = "LoseUnacceptedRootResponse"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        putWasUnknown, resolvedCommitted, resolvedFailed, local,
        recoveredManifest, recoveredRegistry, crashObserved
       >>

ExternalStoreSuccessor ==
    /\ latestManifest = M1
    /\ phase[M1] \in {"HeadUnknown", "Committed"}
    /\ M2 \notin stored
    /\ phase[M2] = "Idle"
    /\ stored' = stored \cup {M2}
    /\ confirmed' = confirmed \cup {M2}
    /\ previous' = [previous EXCEPT ![M2] = M1]
    /\ registry' = [registry EXCEPT ![M2] = SuccessorRegistry]
    /\ phase' = [phase EXCEPT ![M2] = "Stored"]
    /\ local' = local \cup {M2}
    /\ lastAction' = "ExternalStoreSuccessor"
    /\ UNCHANGED <<
        latestManifest, headOrdinal, attemptedOrdinal, putWasUnknown,
        headWasUnknown, resolvedCommitted, resolvedFailed,
        recoveredManifest, recoveredRegistry, crashObserved
       >>

ExternalPublishSuccessor ==
    /\ latestManifest = M1
    /\ M2 \in confirmed
    /\ previous[M2] = M1
    /\ phase[M2] = "Stored"
    /\ latestManifest' = M2
    /\ headOrdinal' = headOrdinal + 1
    /\ attemptedOrdinal' = [attemptedOrdinal EXCEPT ![M2] = headOrdinal + 1]
    /\ phase' = [phase EXCEPT ![M2] = "Committed"]
    /\ lastAction' = "ExternalPublishSuccessor"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, putWasUnknown, headWasUnknown,
        resolvedCommitted, resolvedFailed, local,
        recoveredManifest, recoveredRegistry, crashObserved
       >>

StoreCompetingRoot ==
    /\ latestManifest = NoManifest
    /\ phase[M1] = "HeadUnknown"
    /\ M2 \notin stored
    /\ phase[M2] = "Idle"
    /\ stored' = stored \cup {M2}
    /\ confirmed' = confirmed \cup {M2}
    /\ registry' = [registry EXCEPT ![M2] = RootRegistry]
    /\ phase' = [phase EXCEPT ![M2] = "Stored"]
    /\ local' = local \cup {M2}
    /\ lastAction' = "StoreCompetingRoot"
    /\ UNCHANGED <<
        previous, latestManifest, headOrdinal, attemptedOrdinal, putWasUnknown,
        headWasUnknown, resolvedCommitted, resolvedFailed,
        recoveredManifest, recoveredRegistry, crashObserved
       >>

PublishCompetingRoot ==
    /\ latestManifest = NoManifest
    /\ M2 \in confirmed
    /\ phase[M2] = "Stored"
    /\ latestManifest' = M2
    /\ headOrdinal' = 1
    /\ attemptedOrdinal' = [attemptedOrdinal EXCEPT ![M2] = 1]
    /\ phase' = [phase EXCEPT ![M2] = "Committed"]
    /\ lastAction' = "PublishCompetingRoot"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, putWasUnknown, headWasUnknown,
        resolvedCommitted, resolvedFailed, local,
        recoveredManifest, recoveredRegistry, crashObserved
       >>

ObserveSuccess(m) ==
    /\ m \in ManifestIds
    /\ phase[m] = "HeadAccepted"
    /\ phase' = [phase EXCEPT ![m] = "Committed"]
    /\ lastAction' = "ObserveSuccess"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, putWasUnknown, headWasUnknown, resolvedCommitted,
        resolvedFailed, local, recoveredManifest, recoveredRegistry,
        crashObserved
       >>

ResolveCommitted(m) ==
    /\ m \in ReachableManifests
    /\ phase[m] = "HeadUnknown"
    /\ phase' = [phase EXCEPT ![m] = "Committed"]
    /\ resolvedCommitted' = resolvedCommitted \cup {m}
    /\ lastAction' = "ResolveCommitted"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, putWasUnknown, headWasUnknown, resolvedFailed,
        local, recoveredManifest, recoveredRegistry, crashObserved
       >>

ResolveFailed(m) ==
    /\ m \in ManifestIds \ ReachableManifests
    /\ phase[m] = "HeadUnknown"
    /\ headOrdinal >= attemptedOrdinal[m]
    /\ phase' = [phase EXCEPT ![m] = "Failed"]
    /\ resolvedFailed' = resolvedFailed \cup {m}
    /\ lastAction' = "ResolveFailed"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, putWasUnknown, headWasUnknown, resolvedCommitted,
        local, recoveredManifest, recoveredRegistry, crashObserved
       >>

Crash ==
    /\ local' = {}
    /\ recoveredManifest' = NoManifest
    /\ recoveredRegistry' = EmptyRegistry
    /\ crashObserved' = TRUE
    /\ lastAction' = "Crash"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, phase, putWasUnknown, headWasUnknown,
        resolvedCommitted, resolvedFailed
       >>

Recover ==
    /\ crashObserved
    /\ latestManifest # NoManifest
    /\ recoveredManifest' = latestManifest
    /\ recoveredRegistry' = registry[latestManifest]
    /\ lastAction' = "Recover"
    /\ UNCHANGED <<
        stored, confirmed, previous, registry, latestManifest, headOrdinal,
        attemptedOrdinal, phase, putWasUnknown, headWasUnknown,
        resolvedCommitted, resolvedFailed, local, crashObserved
       >>

Next ==
    \/ StoreRoot
    \/ LoseRootPutResponseStored
    \/ LoseRootPutResponseAbsent
    \/ ConfirmRootBytes
    \/ ResolveRootPutAbsent
    \/ PublishRoot
    \/ LoseAcceptedRootResponse
    \/ LoseUnacceptedRootResponse
    \/ ExternalStoreSuccessor
    \/ ExternalPublishSuccessor
    \/ StoreCompetingRoot
    \/ PublishCompetingRoot
    \/ \E m \in ManifestIds : ObserveSuccess(m)
    \/ \E m \in ManifestIds : ResolveCommitted(m)
    \/ \E m \in ManifestIds : ResolveFailed(m)
    \/ Crash
    \/ Recover

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ stored \subseteq ManifestIds
    /\ confirmed \subseteq ManifestIds
    /\ previous \in [ManifestIds -> ManifestIds \cup {NoManifest}]
    /\ registry \in [ManifestIds -> [Families -> Configs \cup {NoConfig}]]
    /\ latestManifest \in ManifestIds \cup {NoManifest}
    /\ headOrdinal \in Nat
    /\ attemptedOrdinal \in [ManifestIds -> Nat]
    /\ phase \in [ManifestIds -> Phases]
    /\ putWasUnknown \subseteq ManifestIds
    /\ headWasUnknown \subseteq ManifestIds
    /\ resolvedCommitted \subseteq ManifestIds
    /\ resolvedFailed \subseteq ManifestIds
    /\ local \subseteq ManifestIds
    /\ recoveredManifest \in ManifestIds \cup {NoManifest}
    /\ recoveredRegistry \in [Families -> Configs \cup {NoConfig}]
    /\ crashObserved \in BOOLEAN

ConfirmedBytesAreStored == confirmed \subseteq stored

HeadReferencesConfirmedBytes ==
    latestManifest = NoManifest \/ latestManifest \in confirmed

PredecessorsAreStored ==
    \A m \in stored : previous[m] = NoManifest \/ previous[m] \in confirmed

RegistryIsMonotonic ==
    \A m \in stored, f \in Families :
        previous[m] # NoManifest /\ registry[previous[m]][f] # NoConfig
            => registry[m][f] = registry[previous[m]][f]

UnknownResolutionIsSound ==
    /\ \A m \in resolvedCommitted : m \in ReachableManifests
    /\ \A m \in resolvedFailed :
        m \notin ReachableManifests /\ headOrdinal >= attemptedOrdinal[m]

LocalIsOnlyACache == local \subseteq stored

RecoveryIsCacheless ==
    recoveredManifest = NoManifest
        \/ (recoveredManifest \in confirmed
            /\ recoveredRegistry = registry[recoveredManifest])

Safety ==
    TypeOK
        /\ ConfirmedBytesAreStored
        /\ HeadReferencesConfirmedBytes
        /\ PredecessorsAreStored
        /\ RegistryIsMonotonic
        /\ UnknownResolutionIsSound
        /\ LocalIsOnlyACache
        /\ RecoveryIsCacheless

=============================================================================
