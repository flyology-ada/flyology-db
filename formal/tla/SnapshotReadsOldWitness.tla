---------------------- MODULE SnapshotReadsOldWitness ---------------------
EXTENDS SnapshotReads

WitnessReached ==
    /\ phase[T1] = "Active"
    /\ snapshot[T1] = 1
    /\ latestSeq = 2
    /\ latestValue = V2
    /\ previousSeq = 1
    /\ previousValue = V1
    /\ checkpointBoundary = 0
    /\ observed[T1] = V1
    /\ lastAction = "Read"

WitnessPending == ~WitnessReached

=============================================================================
