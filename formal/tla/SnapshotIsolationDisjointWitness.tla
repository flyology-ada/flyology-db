--------------- MODULE SnapshotIsolationDisjointWitness -------------------
EXTENDS SnapshotIsolation

WitnessReached ==
    /\ phase[T1] = "Committed"
    /\ phase[T2] = "Committed"
    /\ writes[T1] = {K1}
    /\ writes[T2] = {K2}
    /\ snapshot[T1] = snapshot[T2]
    /\ sequence = 2

WitnessPending == ~WitnessReached

=============================================================================
