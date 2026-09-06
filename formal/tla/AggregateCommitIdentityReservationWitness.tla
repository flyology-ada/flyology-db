------------- MODULE AggregateCommitIdentityReservationWitness -------------
EXTENDS AggregateCommitIdentityReservation

CollisionComplete ==
    /\ s.admitted = Transactions
    /\ AggregateIdentity \in AdmittedIdentities
    /\ s.phase = "Fenced" /\ s.result = "Stale_Writer" /\ s.fenced
    /\ s.batchPuts = 0 /\ s.headPuts = 0

CollisionPending == ~CollisionComplete

=============================================================================
