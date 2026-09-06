---------------- MODULE AggregateCommitIdentityReservation ----------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
Focused encoded-identity reservation boundary for one two-member aggregate.
Transaction roles and their encoded identifiers are deliberately distinct
concepts: AggregateIdentity may equal either member identity in collision
configurations. This model selects no public width, scheduler, or persisted
ledger. It checks the runtime's local pre-publication reservation guard.
***************************************************************************)

CONSTANTS T1, T2, Txn1Identity, Txn2Identity, AggregateIdentity

Transactions == {T1, T2}
TxnIdentity(t) == IF t = T1 THEN Txn1Identity ELSE Txn2Identity
TransactionIdentities == {TxnIdentity(t) : t \in Transactions}

ASSUME /\ Cardinality(Transactions) = 2
       /\ Txn1Identity # Txn2Identity

Phases == {"Admitting", "Frozen", "Ready", "Committed", "Fenced"}
Results == {"None", "Success", "Stale_Writer"}
ActionNames == {"Init", "Admit", "Freeze", "RejectCollision",
                "PublishBatch", "PublishHead", "UnsafeFreeze"}

VARIABLE s
vars == <<s>>

AdmittedIdentities == {TxnIdentity(t) : t \in s.admitted}

Init ==
    s = [admitted |-> {}, reserved |-> {}, phase |-> "Admitting",
         result |-> "None", batchPuts |-> 0, headPuts |-> 0,
         fenced |-> FALSE, lastAction |-> "Init"]

Admit(t) ==
    /\ s.phase = "Admitting" /\ ~s.fenced
    /\ t \in Transactions \ s.admitted
    /\ TxnIdentity(t) \notin s.reserved
    /\ s' = [s EXCEPT !.admitted = @ \cup {t},
          !.reserved = @ \cup {TxnIdentity(t)}, !.lastAction = "Admit"]

Freeze ==
    /\ s.phase = "Admitting" /\ s.admitted = Transactions
    /\ AggregateIdentity \notin s.reserved
    /\ s' = [s EXCEPT !.reserved = @ \cup {AggregateIdentity},
          !.phase = "Frozen", !.lastAction = "Freeze"]

RejectCollision ==
    /\ s.phase = "Admitting" /\ s.admitted = Transactions
    /\ AggregateIdentity \in s.reserved
    /\ s' = [s EXCEPT !.phase = "Fenced", !.result = "Stale_Writer",
          !.fenced = TRUE, !.lastAction = "RejectCollision"]

PublishBatch ==
    /\ s.phase = "Frozen" /\ s.batchPuts = 0
    /\ s' = [s EXCEPT !.phase = "Ready", !.batchPuts = 1,
          !.lastAction = "PublishBatch"]

PublishHead ==
    /\ s.phase = "Ready" /\ s.batchPuts = 1 /\ s.headPuts = 0
    /\ s' = [s EXCEPT !.phase = "Committed", !.result = "Success",
          !.headPuts = 1, !.lastAction = "PublishHead"]

Next ==
    \/ \E t \in Transactions : Admit(t)
    \/ Freeze \/ RejectCollision \/ PublishBatch \/ PublishHead

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ s.admitted \subseteq Transactions
    /\ s.reserved \subseteq TransactionIdentities \cup {AggregateIdentity}
    /\ s.phase \in Phases /\ s.result \in Results
    /\ s.batchPuts \in 0..1 /\ s.headPuts \in 0..1
    /\ s.fenced \in BOOLEAN /\ s.lastAction \in ActionNames

ReservationAccounting ==
    /\ AdmittedIdentities \subseteq s.reserved
    /\ s.phase \in {"Frozen", "Ready", "Committed"} =>
           s.reserved = AdmittedIdentities \cup {AggregateIdentity}
    /\ s.phase \in {"Admitting", "Fenced"} => s.reserved = AdmittedIdentities

NoAliasedFreeze ==
    s.phase \in {"Frozen", "Ready", "Committed"} =>
        AggregateIdentity \notin AdmittedIdentities

CollisionStopsBeforePublication ==
    s.phase = "Fenced" =>
        /\ s.result = "Stale_Writer" /\ s.fenced
        /\ s.batchPuts = 0 /\ s.headPuts = 0

PublicationGeometry ==
    /\ s.headPuts <= s.batchPuts
    /\ s.phase = "Ready" => s.batchPuts = 1 /\ s.headPuts = 0
    /\ s.phase = "Committed" =>
           s.result = "Success" /\ s.batchPuts = 1 /\ s.headPuts = 1

Safety ==
    TypeOK /\ ReservationAccounting /\ NoAliasedFreeze
    /\ CollisionStopsBeforePublication /\ PublicationGeometry

Trace == [action |-> s.lastAction, phase |-> s.phase,
          admitted |-> s.admitted, reserved |-> s.reserved,
          result |-> s.result, batchPuts |-> s.batchPuts,
          headPuts |-> s.headPuts, fenced |-> s.fenced]

=============================================================================
