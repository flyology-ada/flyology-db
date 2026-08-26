--------------- MODULE CommitPublicationDescendantCommittedWitness ---------------
EXTENDS CommitPublication, FlyologyHarness

AdvanceDescendant(w, q) ==
    /\ epoch < 3
    /\ AdvanceWriterEpoch(w, q)

DescendantNext ==
    Next \/ \E w \in Writers, q \in TransitionIds : AdvanceDescendant(w, q)

DescendantSpec == Init /\ [][DescendantNext]_vars

DescendantCommittedComplete ==
    /\ lastAction = "ResolveCommitted"
    /\ batchTxns[B1] = Txns
    /\ B1 \in ReachableBatches
    /\ headOrdinal >= batchPublicationOrdinal[B1] + 2
    /\ \A t \in Txns :
        /\ wasUnknown[t]
        /\ receipt[t] = "Committed"

DescendantCommittedPending == ~DescendantCommittedComplete

WitnessState == [
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

Alias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
