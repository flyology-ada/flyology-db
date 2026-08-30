----------------- MODULE CommitResolutionAuthoritySwapProbe -----------------
EXTENDS CommitPublication

AcceptSwappedAuthority(t, b) ==
    /\ txnState[t] = "Unknown"
    /\ receipt[t] = "None"
    /\ txnBatch[t] \in BatchIds
    /\ batchTxns[txnBatch[t]] = {t}
    /\ b \in BatchIds
    /\ (b # txnBatch[t] \/ t \notin batchTxns[b])
    /\ durableAuthority' = [durableAuthority EXCEPT ![t] = b]
    /\ invalidImportAccepted' = TRUE
    /\ lastAction' = "RejectMalformedAuthority"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, txnState, txnWriter,
        txnBatch, expectedGeneration, expectedEpoch, expectedOrdinal,
        expectedTransition, publicationOrdinal, publicationTransition,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, receipt,
        authorityLifecycle,
        acknowledged, wasUnknown, visibleTxns, localBatches,
        recoveredBatches, recoveredTxns, recoveredSequence, crashObserved,
        stalePublicationObserved
       >>

ProbeNext ==
    Next \/ \E t \in Txns, b \in BatchIds : AcceptSwappedAuthority(t, b)

ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
