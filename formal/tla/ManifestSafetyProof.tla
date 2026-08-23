-------------------------- MODULE ManifestSafetyProof --------------------------
EXTENDS Naturals

CONSTANTS ManifestIds, Families, Configs, NoManifest, NoConfig

ManifestContents == [Families -> Configs \cup {NoConfig}]

ASSUME
    /\ ManifestIds # {}
    /\ Families # {}
    /\ NoManifest \notin ManifestIds
    /\ NoConfig \notin Configs

VARIABLES stored, confirmed, head, previous, registry, local

vars == <<stored, confirmed, head, previous, registry, local>>

Init ==
    /\ stored = {}
    /\ confirmed = {}
    /\ head = NoManifest
    /\ previous = [m \in ManifestIds |-> NoManifest]
    /\ registry = [m \in ManifestIds |-> [f \in Families |-> NoConfig]]
    /\ local = {}

StoreRoot(m, contents) ==
    /\ m \in ManifestIds \ stored
    /\ contents \in ManifestContents
    /\ stored' = stored \cup {m}
    /\ previous' = [previous EXCEPT ![m] = NoManifest]
    /\ registry' = [registry EXCEPT ![m] = contents]
    /\ local' = local \cup {m}
    /\ UNCHANGED <<confirmed, head>>

StoreSuccessor(m, predecessor, contents) ==
    /\ m \in ManifestIds \ stored
    /\ predecessor \in confirmed
    /\ contents \in ManifestContents
    /\ \A f \in Families :
        registry[predecessor][f] # NoConfig =>
            contents[f] = registry[predecessor][f]
    /\ stored' = stored \cup {m}
    /\ previous' = [previous EXCEPT ![m] = predecessor]
    /\ registry' = [registry EXCEPT ![m] = contents]
    /\ local' = local \cup {m}
    /\ UNCHANGED <<confirmed, head>>

Confirm(m) ==
    /\ m \in stored
    /\ confirmed' = confirmed \cup {m}
    /\ UNCHANGED <<stored, head, previous, registry, local>>

Publish(m) ==
    /\ m \in confirmed
    /\ head' = m
    /\ UNCHANGED <<stored, confirmed, previous, registry, local>>

Crash ==
    /\ local' = {}
    /\ UNCHANGED <<stored, confirmed, head, previous, registry>>

Next ==
    \/ \E m \in ManifestIds, contents \in ManifestContents :
        StoreRoot(m, contents)
    \/ \E m \in ManifestIds, predecessor \in ManifestIds,
          contents \in ManifestContents :
        StoreSuccessor(m, predecessor, contents)
    \/ \E m \in ManifestIds : Confirm(m)
    \/ \E m \in ManifestIds : Publish(m)
    \/ Crash

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ stored \subseteq ManifestIds
    /\ confirmed \subseteq ManifestIds
    /\ head \in ManifestIds \cup {NoManifest}
    /\ previous \in [ManifestIds -> ManifestIds \cup {NoManifest}]
    /\ registry \in [ManifestIds -> ManifestContents]
    /\ local \subseteq ManifestIds

ConfirmedBytesAreStored == confirmed \subseteq stored

HeadReferencesConfirmedBytes == head = NoManifest \/ head \in confirmed

PredecessorsAreStored ==
    \A m \in stored : previous[m] = NoManifest \/ previous[m] \in confirmed

RegistryIsMonotonic ==
    \A m \in stored, f \in Families :
        previous[m] # NoManifest /\ registry[previous[m]][f] # NoConfig =>
            registry[m][f] = registry[previous[m]][f]

LocalIsOnlyACache == local \subseteq stored

Safety ==
    TypeOK
        /\ ConfirmedBytesAreStored
        /\ HeadReferencesConfirmedBytes
        /\ PredecessorsAreStored
        /\ RegistryIsMonotonic
        /\ LocalIsOnlyACache

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, ConfirmedBytesAreStored,
    HeadReferencesConfirmedBytes, PredecessorsAreStored, RegistryIsMonotonic,
    LocalIsOnlyACache, ManifestContents

THEOREM StoreRootPreservesSafety ==
    \A m \in ManifestIds, contents \in ManifestContents :
        Safety /\ StoreRoot(m, contents) => Safety'
<1> QED BY DEF StoreRoot, Safety, TypeOK, ConfirmedBytesAreStored,
    HeadReferencesConfirmedBytes, PredecessorsAreStored, RegistryIsMonotonic,
    LocalIsOnlyACache, ManifestContents

THEOREM StoreSuccessorPreservesSafety ==
    \A m \in ManifestIds, predecessor \in ManifestIds,
       contents \in ManifestContents :
        Safety /\ StoreSuccessor(m, predecessor, contents) => Safety'
<1> QED BY DEF StoreSuccessor, Safety, TypeOK, ConfirmedBytesAreStored,
    HeadReferencesConfirmedBytes, PredecessorsAreStored, RegistryIsMonotonic,
    LocalIsOnlyACache, ManifestContents

THEOREM ConfirmPreservesSafety ==
    \A m \in ManifestIds : Safety /\ Confirm(m) => Safety'
<1> QED BY DEF Confirm, Safety, TypeOK, ConfirmedBytesAreStored,
    HeadReferencesConfirmedBytes, PredecessorsAreStored, RegistryIsMonotonic,
    LocalIsOnlyACache, ManifestContents

THEOREM PublishPreservesSafety ==
    \A m \in ManifestIds : Safety /\ Publish(m) => Safety'
<1> QED BY DEF Publish, Safety, TypeOK, ConfirmedBytesAreStored,
    HeadReferencesConfirmedBytes, PredecessorsAreStored, RegistryIsMonotonic,
    LocalIsOnlyACache, ManifestContents

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> QED BY DEF Crash, Safety, TypeOK, ConfirmedBytesAreStored,
    HeadReferencesConfirmedBytes, PredecessorsAreStored, RegistryIsMonotonic,
    LocalIsOnlyACache, ManifestContents

THEOREM NextPreservesSafety == Safety /\ Next => Safety'
<1> QED BY StoreRootPreservesSafety, StoreSuccessorPreservesSafety,
    ConfirmPreservesSafety, PublishPreservesSafety, CrashPreservesSafety DEF Next

=============================================================================
