--------------------- MODULE CommitPublicationStaleProbe --------------------
EXTENDS CommitPublication

\* Deliberately model the history effect of an illegal stale publication.
\* The ordinary PublishHead action remains guarded by CanPublish. This probe
\* must make NoStaleWriterPublication fail after a stored transaction's writer
\* epoch becomes stale, demonstrating that the history monitor is non-vacuous.
ProbeStalePublication(b) ==
    /\ batchTxns[b] # {}
    /\ \A t \in batchTxns[b] : txnState[t] = "Stored"
    /\ PublicationWasStale(b)
    /\ stalePublicationObserved' = PublicationHistoryAfter(b)
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, txnState, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, receipt,
        acknowledged, wasUnknown, visibleTxns, localBatches, recoveredBatches,
        recoveredTxns, recoveredSequence, crashObserved, lastAction
       >>

ProbeNext == Next \/ \E b \in BatchIds : ProbeStalePublication(b)

ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
