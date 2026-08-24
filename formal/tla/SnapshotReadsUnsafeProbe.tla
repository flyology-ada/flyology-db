---------------------- MODULE SnapshotReadsUnsafeProbe --------------------
EXTENDS SnapshotReads

UnsafeReadLatest(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ ExpectedRead(t) # latestValue
    /\ observed' = [observed EXCEPT ![t] = latestValue]
    /\ badReadObserved' = TRUE
    /\ lastAction' = "Read"
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, bufferKind,
        bufferValue, latestSeq, latestValue, previousSeq, previousValue>>

UnsafeNext == Next \/ \E t \in Transactions : UnsafeReadLatest(t)

UnsafeSpec == Init /\ [][UnsafeNext]_vars

=============================================================================
