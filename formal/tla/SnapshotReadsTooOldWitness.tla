-------------------- MODULE SnapshotReadsTooOldWitness --------------------
EXTENDS SnapshotReads

WitnessReached ==
    /\ phase[T1] = "Active"
    /\ snapshot[T1] = 1
    /\ checkpointBoundary = 2
    /\ latestSeq = 2
    /\ observed[T1] = "TooOld"
    /\ lastAction = "Read"

WitnessPending == ~WitnessReached

=============================================================================
