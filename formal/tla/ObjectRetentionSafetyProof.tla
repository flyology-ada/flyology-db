--------------------- MODULE ObjectRetentionSafetyProof ---------------------
EXTENDS Naturals

(***************************************************************************
This unbounded kernel treats immutable object identities as an arbitrary set.
Current authority, snapshots, replicas, predecessors, and unresolved attempts
are independent protection sources. A deletion requires explicit discovery,
an external age decision, and a live protection recheck. Deleted identities
cannot be stored again. Concrete graph traversal, clocks, age thresholds,
provider delete certainty, batching, progress, and refinement are excluded.
***************************************************************************)

CONSTANTS Objects, InitialObject

ASSUME /\ Objects # {} /\ InitialObject \in Objects

VARIABLES stored, current, snapshotPins, replicaPins, predecessorPins,
    unresolvedPins, listed, aged, deleted

vars == <<stored, current, snapshotPins, replicaPins, predecessorPins,
    unresolvedPins, listed, aged, deleted>>

Protected ==
    current \cup snapshotPins \cup replicaPins \cup predecessorPins
        \cup unresolvedPins

Init ==
    /\ InitialObject \in Objects
    /\ stored = {InitialObject} /\ current = {InitialObject}
    /\ snapshotPins = {} /\ replicaPins = {} /\ predecessorPins = {}
    /\ unresolvedPins = {} /\ listed = {} /\ aged = {} /\ deleted = {}

Store(o) ==
    /\ o \in Objects \ (stored \cup deleted)
    /\ stored' = stored \cup {o}
    /\ UNCHANGED <<current, snapshotPins, replicaPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

ListObject(o) ==
    /\ o \in stored
    /\ listed' = listed \cup {o}
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, unresolvedPins, aged, deleted>>

MarkOld(o) ==
    /\ o \in stored
    /\ aged' = aged \cup {o}
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, unresolvedPins, listed, deleted>>

AcquireSnapshot ==
    /\ snapshotPins' = snapshotPins \cup current
    /\ UNCHANGED <<stored, current, replicaPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

ReleaseSnapshot(o) ==
    /\ o \in snapshotPins
    /\ snapshotPins' = snapshotPins \ {o}
    /\ UNCHANGED <<stored, current, replicaPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

PinReplica ==
    /\ replicaPins' = replicaPins \cup current
    /\ UNCHANGED <<stored, current, snapshotPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

ReleaseReplica(o) ==
    /\ o \in replicaPins
    /\ replicaPins' = replicaPins \ {o}
    /\ UNCHANGED <<stored, current, snapshotPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

Advance(nextCurrent) ==
    /\ nextCurrent \in SUBSET stored /\ nextCurrent # {}
    /\ nextCurrent # current
    /\ nextCurrent \cap predecessorPins = {}
    /\ current' = nextCurrent
    /\ predecessorPins' = predecessorPins \cup current
    /\ UNCHANGED <<stored, snapshotPins, replicaPins, unresolvedPins,
        listed, aged, deleted>>

ReleasePredecessor(o) ==
    /\ o \in predecessorPins
    /\ predecessorPins' = predecessorPins \ {o}
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        unresolvedPins, listed, aged, deleted>>

BeginUnknown(o) ==
    /\ o \in stored
    /\ unresolvedPins' = unresolvedPins \cup {o}
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, listed, aged, deleted>>

ResolveUnknown(o) ==
    /\ o \in unresolvedPins
    /\ unresolvedPins' = unresolvedPins \ {o}
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, listed, aged, deleted>>

DeleteEligible(o) ==
    /\ o \in stored \cap listed \cap aged
    /\ o \notin Protected
    /\ stored' = stored \ {o}
    /\ listed' = listed \ {o}
    /\ aged' = aged \ {o}
    /\ deleted' = deleted \cup {o}
    /\ UNCHANGED <<current, snapshotPins, replicaPins, predecessorPins,
        unresolvedPins>>

DiscardDiscovery ==
    /\ listed' = {} /\ aged' = {}
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, unresolvedPins, deleted>>

TypeOK ==
    /\ stored \subseteq Objects /\ current \subseteq Objects /\ current # {}
    /\ snapshotPins \subseteq Objects /\ replicaPins \subseteq Objects
    /\ predecessorPins \subseteq Objects /\ unresolvedPins \subseteq Objects
    /\ listed \subseteq Objects /\ aged \subseteq Objects
    /\ deleted \subseteq Objects

EveryProtectionIsStored == Protected \subseteq stored

DiscoveryNamesStoredObjects == listed \subseteq stored /\ aged \subseteq stored

ImmutableIdentityNeverReused == stored \cap deleted = {}

DeletedObjectsAreUnprotected == deleted \cap Protected = {}

Safety ==
    /\ TypeOK /\ EveryProtectionIsStored /\ DiscoveryNamesStoredObjects
    /\ ImmutableIdentityNeverReused /\ DeletedObjectsAreUnprotected

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM StorePreservesSafety ==
    \A o \in Objects : Safety /\ Store(o) => Safety'
<1> QED BY DEF Store, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM ListPreservesSafety ==
    \A o \in Objects : Safety /\ ListObject(o) => Safety'
<1> QED BY DEF ListObject, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM MarkOldPreservesSafety ==
    \A o \in Objects : Safety /\ MarkOld(o) => Safety'
<1> QED BY DEF MarkOld, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM AcquireSnapshotPreservesSafety ==
    Safety /\ AcquireSnapshot => Safety'
<1> QED BY DEF AcquireSnapshot, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM ReleaseSnapshotPreservesSafety ==
    \A o \in Objects : Safety /\ ReleaseSnapshot(o) => Safety'
<1> QED BY DEF ReleaseSnapshot, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM PinReplicaPreservesSafety == Safety /\ PinReplica => Safety'
<1> QED BY DEF PinReplica, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM ReleaseReplicaPreservesSafety ==
    \A o \in Objects : Safety /\ ReleaseReplica(o) => Safety'
<1> QED BY DEF ReleaseReplica, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM AdvancePreservesSafety ==
    \A nextCurrent \in SUBSET Objects :
        Safety /\ Advance(nextCurrent) => Safety'
<1> QED BY DEF Advance, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM ReleasePredecessorPreservesSafety ==
    \A o \in Objects : Safety /\ ReleasePredecessor(o) => Safety'
<1> QED BY DEF ReleasePredecessor, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM BeginUnknownPreservesSafety ==
    \A o \in Objects : Safety /\ BeginUnknown(o) => Safety'
<1> QED BY DEF BeginUnknown, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM ResolveUnknownPreservesSafety ==
    \A o \in Objects : Safety /\ ResolveUnknown(o) => Safety'
<1> QED BY DEF ResolveUnknown, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM DeleteEligiblePreservesSafety ==
    \A o \in Objects : Safety /\ DeleteEligible(o) => Safety'
<1> QED BY DEF DeleteEligible, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM DiscardDiscoveryPreservesSafety ==
    Safety /\ DiscardDiscovery => Safety'
<1> QED BY DEF DiscardDiscovery, Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected

THEOREM QuiescencePreservesSafety ==
    Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, EveryProtectionIsStored,
    DiscoveryNamesStoredObjects, ImmutableIdentityNeverReused,
    DeletedObjectsAreUnprotected, Protected, vars

=============================================================================
