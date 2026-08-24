------------------ MODULE ReplicaRefreshStaleWriterProbe ------------------
EXTENDS ReplicaRefresh

UnsafeStalePublish ==
    /\ writerPhase = "Ready"
    /\ writerCapturedEpoch # headEpoch
    /\ headOrdinal < MaximumOrdinal /\ headOrdinal + 1 \in confirmed
    /\ headOrdinal' = headOrdinal + 1
    /\ writerPhase' = "Idle" /\ stalePublished' = TRUE
    /\ lastAction' = "Publish"
    /\ UNCHANGED <<confirmed, headEpoch, writerExpectedOrdinal,
        writerCapturedEpoch, replicaOrdinal, replicaEpoch, capturedOrdinal,
        capturedEpoch, refreshPhase, highOrdinal, highEpoch,
        rollbackInstalled>>

NextWithProbe == Next \/ UnsafeStalePublish
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
