------------------ MODULE SerializableSnapshotWitness ------------------
EXTENDS SerializableValidation

WitnessReached ==
    /\ phase[T1] = "Committed"
    /\ phase[T2] = "Committed"
    /\ mode[T1] = "Snapshot"
    /\ snapshot[T1] = 0
    /\ writes[T1] = {}
    /\ writes[T2] = {K1}
    /\ pointReads[T1] = {}
    /\ lastWrite[K1] = 1
    /\ result[T1] = "Success"
    /\ lastAction = "Commit"

WitnessPending == ~WitnessReached

WitnessNext ==
    \/ /\ phase[T1] = "Idle"
       /\ Begin(T1, "Snapshot")
    \/ /\ phase[T1] = "Active"
       /\ phase[T2] = "Idle"
       /\ result[T1] = "None"
       /\ RecordPoint(T1, K1)
    \/ /\ phase[T2] = "Idle"
       /\ lastAction = "RecordPoint"
       /\ Begin(T2, "Snapshot")
    \/ /\ phase[T2] = "Active"
       /\ writes[T2] = {}
       /\ BufferWrite(T2, K1)
    \/ /\ phase[T2] = "Active"
       /\ writes[T2] = {K1}
       /\ Commit(T2)
    \/ /\ phase[T2] = "Committed"
       /\ phase[T1] = "Active"
       /\ Commit(T1)

WitnessSpec == Init /\ [][WitnessNext]_vars

=============================================================================
