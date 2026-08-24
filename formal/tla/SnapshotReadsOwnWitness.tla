---------------------- MODULE SnapshotReadsOwnWitness ---------------------
EXTENDS SnapshotReads

WitnessReached ==
    /\ phase[T1] = "Active"
    /\ snapshot[T1] = 1
    /\ bufferKind[T1] = "Put"
    /\ bufferValue[T1] = V1
    /\ latestSeq = 2
    /\ latestValue = V2
    /\ observed[T1] = V1
    /\ lastAction = "Read"

WitnessPending == ~WitnessReached

=============================================================================
