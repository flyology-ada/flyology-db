--------------------- MODULE SnapshotIsolationWitness ----------------------
EXTENDS SnapshotIsolation

WitnessReached ==
    /\ phase[T1] = "Committed"
    /\ phase[T2] = "Conflict"
    /\ writes[T1] = {K1}
    /\ writes[T2] = {K1}
    /\ snapshot[T1] = snapshot[T2]
    /\ lastWrite[K1] > snapshot[T2]

WitnessPending == ~WitnessReached

=============================================================================
