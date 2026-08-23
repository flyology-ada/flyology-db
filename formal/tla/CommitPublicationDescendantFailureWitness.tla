---------------- MODULE CommitPublicationDescendantFailureWitness ----------------
EXTENDS CommitPublication

AdvanceDescendant(w, q) ==
    /\ epoch < 3
    /\ AdvanceWriterEpoch(w, q)

DescendantNext ==
    Next \/ \E w \in Writers, q \in TransitionIds : AdvanceDescendant(w, q)

DescendantSpec == Init /\ [][DescendantNext]_vars

DescendantFailureComplete ==
    /\ lastAction = "ResolvePreconditionFailure"
    /\ batchTxns[B1] = Txns
    /\ B1 \notin ReachableBatches
    /\ headOrdinal >= batchPublicationOrdinal[B1] + 1
    /\ \A t \in Txns :
        /\ wasUnknown[t]
        /\ receipt[t] = "PreconditionFailed"

DescendantFailurePending == ~DescendantFailureComplete

Alias == [
    action |-> lastAction,
    head |-> [
        ordinal |-> headOrdinal,
        latest_batch |-> latestBatch,
        transition |-> headTransition
    ],
    attempted_batch |-> [
        id |-> B1,
        reachable |-> B1 \in ReachableBatches,
        publication_ordinal |-> batchPublicationOrdinal[B1],
        transactions |-> batchTxns[B1]
    ],
    transactions |-> [t \in Txns |-> [
        state |-> txnState[t],
        receipt |-> receipt[t],
        was_unknown |-> wasUnknown[t]
    ]]
]

=============================================================================
