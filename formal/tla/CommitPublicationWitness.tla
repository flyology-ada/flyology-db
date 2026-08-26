----------------------- MODULE CommitPublicationWitness ----------------------
EXTENDS CommitPublication, FlyologyHarness

WitnessPending == ~WitnessComplete

WitnessState == [
    action |-> lastAction,
    head |-> [
        epoch |-> epoch,
        sequence |-> sequence,
        latest_batch |-> latestBatch,
        ordinal |-> headOrdinal,
        transition |-> headTransition,
        predecessor |-> headPredecessor,
        generation |-> generation
    ],
    batch |-> [
        id |-> B1,
        transactions |-> batchTxns[B1],
        first_sequence |-> batchFirstSequence[B1],
        last_sequence |-> batchLastSequence[B1]
    ],
    transactions |-> [t \in Txns |-> [
        state |-> txnState[t],
        batch |-> txnBatch[t],
        receipt |-> receipt[t],
        was_unknown |-> wasUnknown[t],
        families |-> TxnFamilies(t)
    ]],
    recovered_transactions |-> recoveredTxns,
    remote_batches |-> remoteBatches,
    local_batches |-> localBatches,
    recovered_batches |-> recoveredBatches,
    recovered_sequence |-> recoveredSequence,
    crash_observed |-> crashObserved,
    stale_publication_observed |-> stalePublicationObserved
]

Alias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
