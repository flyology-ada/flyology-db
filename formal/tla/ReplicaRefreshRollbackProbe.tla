-------------------- MODULE ReplicaRefreshRollbackProbe --------------------
EXTENDS ReplicaRefresh

UnsafeRollbackInstall ==
    /\ replicaOrdinal > 0
    /\ replicaOrdinal' = 0 /\ replicaEpoch' = 0
    /\ rollbackInstalled' = TRUE
    /\ refreshPhase' = "Idle" /\ lastAction' = "InstallRefresh"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        capturedOrdinal, capturedEpoch, highOrdinal, highEpoch>>

NextWithProbe == Next \/ UnsafeRollbackInstall
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
