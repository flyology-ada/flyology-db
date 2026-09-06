-------------- MODULE AggregateCommitIdentityReservationProbes --------------
EXTENDS AggregateCommitIdentityReservation

(***************************************************************************
The unsafe action bypasses only the encoded-identity membership guard. It is a
negative probe and is never part of the production Next relation.
***************************************************************************)

UnsafeFreeze ==
    /\ s.phase = "Admitting" /\ s.admitted = Transactions
    /\ AggregateIdentity \in s.reserved
    /\ s' = [s EXCEPT !.reserved = @ \cup {AggregateIdentity},
          !.phase = "Frozen", !.lastAction = "UnsafeFreeze"]

ProbeSpec == Init /\ [][Next \/ UnsafeFreeze]_vars

=============================================================================
