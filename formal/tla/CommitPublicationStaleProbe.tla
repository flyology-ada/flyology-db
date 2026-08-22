--------------------- MODULE CommitPublicationStaleProbe --------------------
EXTENDS CommitPublication

\* Deliberately model the history effect of an illegal stale publication.
\* The ordinary PublishHead action remains guarded by CanPublish. This probe
\* must make NoStaleWriterPublication fail after a stored transaction's writer
\* epoch becomes stale, demonstrating that the history monitor is non-vacuous.
ProbeStalePublication(t) ==
    /\ txnState[t] = "Stored"
    /\ PublicationWasStale(t)
    /\ stalePublicationObserved' = PublicationHistoryAfter(t)
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, txnState, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, receipt,
        acknowledged, wasUnknown, localBatches, recoveredBatches,
        recoveredSequence, crashObserved, lastAction
       >>

ProbeNext == Next \/ \E t \in Txns : ProbeStalePublication(t)

ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
