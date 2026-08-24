---------------- MODULE SnapshotIsolationUnsafeCommitProbe -----------------
EXTENDS SnapshotIsolation

UnsafeCommit(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ writes[t] # {}
    /\ ~CanCommit(t)
    /\ sequence' = sequence + 1
    /\ lastWrite' =
        [k \in Keys |-> IF k \in writes[t] THEN sequence + 1 ELSE lastWrite[k]]
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ invalidCommitObserved' = TRUE
    /\ lastAction' = "Commit"
    /\ UNCHANGED <<checkpointBoundary, snapshot, writes>>

ProbeNext == Next \/ \E t \in Transactions : UnsafeCommit(t)

ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
