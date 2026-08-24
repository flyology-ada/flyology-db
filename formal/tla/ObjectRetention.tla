--------------------------- MODULE ObjectRetention ---------------------------
EXTENDS TLC

(***************************************************************************
This finite model freezes the deletion-safety boundary for immutable database
objects. Current authority, active snapshots, lagging replicas, required
predecessors, and unresolved publication attempts independently protect exact
object identities. Listing and an explicit age decision are both required to
form a deletion candidate, but deletion also rechecks live protection. Object
identities are never reused. The exhaustive graph explores two symmetric
identities while the exact witness also uses a third orphan identity. This is
qualification geometry, not a retention horizon, age threshold, batch size,
or provider policy.
***************************************************************************)

CONSTANTS O0, O1, O2

Objects == {O0, O1, O2}
ExploredObjects == {O0, O1}

ActionNames == {
    "Init", "Store", "ListObject", "MarkOld", "AcquireSnapshot",
    "ReleaseSnapshot", "PinReplica", "ReleaseReplica", "Advance",
    "ReleasePredecessor", "BeginUnknown", "ResolveUnknown",
    "DeleteEligible", "DiscardDiscovery"
}

VARIABLES stored, current, snapshotPins, replicaPins, predecessorPins,
    unresolvedPins, listed, aged, deleted, lastAction

vars == <<stored, current, snapshotPins, replicaPins, predecessorPins,
    unresolvedPins, listed, aged, deleted, lastAction>>

ProtectedObjects ==
    current \cup snapshotPins \cup replicaPins \cup predecessorPins
        \cup unresolvedPins

Init ==
    /\ stored = {O0} /\ current = {O0}
    /\ snapshotPins = {} /\ replicaPins = {} /\ predecessorPins = {}
    /\ unresolvedPins = {} /\ listed = {} /\ aged = {} /\ deleted = {}
    /\ lastAction = "Init"

Store(o) ==
    /\ o \in Objects \ (stored \cup deleted)
    /\ stored' = stored \cup {o}
    /\ lastAction' = "Store"
    /\ UNCHANGED <<current, snapshotPins, replicaPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

ListObject(o) ==
    /\ o \in stored \ listed
    /\ listed' = listed \cup {o}
    /\ lastAction' = "ListObject"
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, unresolvedPins, aged, deleted>>

MarkOld(o) ==
    /\ o \in stored \ aged
    /\ aged' = aged \cup {o}
    /\ lastAction' = "MarkOld"
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, unresolvedPins, listed, deleted>>

AcquireSnapshot ==
    /\ current \ snapshotPins # {}
    /\ snapshotPins' = snapshotPins \cup current
    /\ lastAction' = "AcquireSnapshot"
    /\ UNCHANGED <<stored, current, replicaPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

ReleaseSnapshot(o) ==
    /\ o \in snapshotPins
    /\ snapshotPins' = snapshotPins \ {o}
    /\ lastAction' = "ReleaseSnapshot"
    /\ UNCHANGED <<stored, current, replicaPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

PinReplica ==
    /\ current \ replicaPins # {}
    /\ replicaPins' = replicaPins \cup current
    /\ lastAction' = "PinReplica"
    /\ UNCHANGED <<stored, current, snapshotPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

ReleaseReplica(o) ==
    /\ o \in replicaPins
    /\ replicaPins' = replicaPins \ {o}
    /\ lastAction' = "ReleaseReplica"
    /\ UNCHANGED <<stored, current, snapshotPins, predecessorPins,
        unresolvedPins, listed, aged, deleted>>

Advance(nextCurrent) ==
    /\ nextCurrent \in SUBSET stored /\ nextCurrent # {}
    /\ nextCurrent # current
    /\ nextCurrent \cap predecessorPins = {}
    /\ current' = nextCurrent
    /\ predecessorPins' = predecessorPins \cup current
    /\ lastAction' = "Advance"
    /\ UNCHANGED <<stored, snapshotPins, replicaPins, unresolvedPins,
        listed, aged, deleted>>

ReleasePredecessor(o) ==
    /\ o \in predecessorPins
    /\ predecessorPins' = predecessorPins \ {o}
    /\ lastAction' = "ReleasePredecessor"
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        unresolvedPins, listed, aged, deleted>>

BeginUnknown(o) ==
    /\ o \in stored \ unresolvedPins
    /\ unresolvedPins' = unresolvedPins \cup {o}
    /\ lastAction' = "BeginUnknown"
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, listed, aged, deleted>>

ResolveUnknown(o) ==
    /\ o \in unresolvedPins
    /\ unresolvedPins' = unresolvedPins \ {o}
    /\ lastAction' = "ResolveUnknown"
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, listed, aged, deleted>>

DeleteEligible(o) ==
    /\ o \in stored \cap listed \cap aged
    /\ o \notin ProtectedObjects
    /\ stored' = stored \ {o}
    /\ listed' = listed \ {o}
    /\ aged' = aged \ {o}
    /\ deleted' = deleted \cup {o}
    /\ lastAction' = "DeleteEligible"
    /\ UNCHANGED <<current, snapshotPins, replicaPins, predecessorPins,
        unresolvedPins>>

DiscardDiscovery ==
    /\ listed \cup aged # {}
    /\ listed' = {} /\ aged' = {}
    /\ lastAction' = "DiscardDiscovery"
    /\ UNCHANGED <<stored, current, snapshotPins, replicaPins,
        predecessorPins, unresolvedPins, deleted>>

Next ==
    \/ \E o \in ExploredObjects :
          Store(o) \/ ListObject(o) \/ MarkOld(o)
              \/ ReleaseSnapshot(o) \/ ReleaseReplica(o)
              \/ ReleasePredecessor(o)
              \/ BeginUnknown(o) \/ ResolveUnknown(o) \/ DeleteEligible(o)
    \/ \E nextCurrent \in SUBSET ExploredObjects : Advance(nextCurrent)
    \/ AcquireSnapshot \/ PinReplica \/ DiscardDiscovery

TypeOK ==
    /\ stored \subseteq Objects /\ current \subseteq Objects /\ current # {}
    /\ snapshotPins \subseteq Objects /\ replicaPins \subseteq Objects
    /\ predecessorPins \subseteq Objects /\ unresolvedPins \subseteq Objects
    /\ listed \subseteq Objects /\ aged \subseteq Objects
    /\ deleted \subseteq Objects /\ lastAction \in ActionNames

EveryProtectionIsStored == ProtectedObjects \subseteq stored

DiscoveryNamesStoredObjects == listed \subseteq stored /\ aged \subseteq stored

ImmutableIdentityNeverReused == stored \cap deleted = {}

DeletedObjectsAreUnprotected == deleted \cap ProtectedObjects = {}

Safety ==
    /\ TypeOK /\ EveryProtectionIsStored /\ DiscoveryNamesStoredObjects
    /\ ImmutableIdentityNeverReused /\ DeletedObjectsAreUnprotected

Spec == Init /\ [][Next]_vars

=============================================================================
