------------------ MODULE SerializableOwnWriteWitness ------------------
EXTENDS SerializableValidation

WitnessReached ==
    /\ phase[T1] = "Active"
    /\ mode[T1] = "Serializable"
    /\ writes[T1] = {K2}
    /\ pointReads[T1] = {K1}
    /\ result[T1] = "Success"
    /\ lastAction = "RecordPoint"

WitnessPending == ~WitnessReached

WitnessNext ==
    \/ /\ phase[T1] = "Idle"
       /\ Begin(T1, "Serializable")
    \/ /\ phase[T1] = "Active"
       /\ pointReads[T1] = {}
       /\ RecordPoint(T1, K1)
    \/ /\ pointReads[T1] = {K1}
       /\ writes[T1] = {}
       /\ BufferWrite(T1, K2)
    \/ /\ writes[T1] = {K2}
       /\ lastAction = "BufferWrite"
       /\ RecordPoint(T1, K2)

WitnessSpec == Init /\ [][WitnessNext]_vars

=============================================================================
