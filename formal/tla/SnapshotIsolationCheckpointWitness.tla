---------------- MODULE SnapshotIsolationCheckpointWitness -----------------
EXTENDS SnapshotIsolation

WitnessReached ==
    /\ checkpointBoundary > snapshot[T2]
    /\ phase[T1] = "Committed"
    /\ phase[T2] = "Conflict"
    /\ writes[T1] = {K1}
    /\ writes[T2] = {K2}
    /\ lastWrite[K2] = 0

WitnessPending == ~WitnessReached

=============================================================================
