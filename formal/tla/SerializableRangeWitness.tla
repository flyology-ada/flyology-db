------------------- MODULE SerializableRangeWitness --------------------
EXTENDS SerializableValidation

WitnessReached ==
    /\ phase[T1] = "Rejected"
    /\ mode[T1] = "Serializable"
    /\ snapshot[T1] = 0
    /\ rangeReads[T1] = {R1}
    /\ lastWrite[K1] = 1
    /\ result[T1] = "SerializationFailure"
    /\ lastAction = "RejectConflict"

WitnessPending == ~WitnessReached

=============================================================================
