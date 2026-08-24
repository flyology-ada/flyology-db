---------------- MODULE SerializableUnsafeCommitProbe ------------------
EXTENDS SerializableValidation

UnsafeCommit(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ mode[t] = "Serializable"
    /\ SerializableConflict(t)
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ badCommitObserved' = TRUE
    /\ lastAction' = "Commit"
    /\ UNCHANGED <<sequence, mode, snapshot, writes, pointReads, rangeReads,
        lastWrite>>

UnsafeNext == Next \/ \E t \in Transactions : UnsafeCommit(t)

UnsafeSpec == Init /\ [][UnsafeNext]_vars

=============================================================================
