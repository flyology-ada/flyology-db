----------------------- MODULE CommitPublicationWitness ----------------------
EXTENDS CommitPublication

WitnessPending == ~WitnessComplete

Alias == [
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
    transaction |-> [
        state |-> txnState[T1],
        batch |-> txnBatch[T1],
        receipt |-> receipt[T1],
        was_unknown |-> wasUnknown[T1],
        families |-> TxnFamilies(T1)
    ],
    remote_batches |-> remoteBatches,
    local_batches |-> localBatches,
    recovered_batches |-> recoveredBatches,
    recovered_sequence |-> recoveredSequence,
    crash_observed |-> crashObserved,
    stale_publication_observed |-> stalePublicationObserved
]

=============================================================================
