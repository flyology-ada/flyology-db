----------- MODULE AggregateCommitIdentityReservationSafetyProof -----------
EXTENDS AggregateCommitIdentityReservation

(***************************************************************************
Arbitrary encoded identities satisfy this preservation kernel subject only to
the main model's distinct transaction-identity assumption. It proves the local
reservation barrier, not byte encoding, provider behavior, or refinement.
***************************************************************************)

RecordTypeOK ==
    s \in [admitted : SUBSET Transactions,
           reserved : SUBSET (TransactionIdentities \cup {AggregateIdentity}),
           phase : Phases, result : Results, batchPuts : 0..1, headPuts : 0..1,
           fenced : BOOLEAN, lastAction : ActionNames]

AdmissionBeforePublication == s.phase = "Admitting" => s.batchPuts = 0

InductiveSafety == Safety /\ RecordTypeOK /\ AdmissionBeforePublication

THEOREM InitialSafety == Init => InductiveSafety
<1> QED BY DEF Init, InductiveSafety, RecordTypeOK, AdmissionBeforePublication,
    Safety, TypeOK, ReservationAccounting, NoAliasedFreeze,
    CollisionStopsBeforePublication, PublicationGeometry, AdmittedIdentities,
    TransactionIdentities, Phases, Results, ActionNames

THEOREM AdmitPreservesSafety ==
    \A t \in Transactions : InductiveSafety /\ Admit(t) => InductiveSafety'
<1> QED BY DEF Admit, InductiveSafety, RecordTypeOK, AdmissionBeforePublication,
    Safety, TypeOK, ReservationAccounting, NoAliasedFreeze,
    CollisionStopsBeforePublication, PublicationGeometry, AdmittedIdentities,
    TransactionIdentities, Phases, Results, ActionNames

THEOREM FreezePreservesSafety == InductiveSafety /\ Freeze => InductiveSafety'
<1> QED BY DEF Freeze, InductiveSafety, RecordTypeOK, AdmissionBeforePublication,
    Safety, TypeOK, ReservationAccounting, NoAliasedFreeze,
    CollisionStopsBeforePublication, PublicationGeometry, AdmittedIdentities,
    TransactionIdentities, Phases, Results, ActionNames

THEOREM RejectCollisionPreservesSafety ==
    InductiveSafety /\ RejectCollision => InductiveSafety'
<1> QED BY DEF RejectCollision, InductiveSafety, RecordTypeOK,
    AdmissionBeforePublication, Safety, TypeOK, ReservationAccounting, NoAliasedFreeze,
    CollisionStopsBeforePublication, PublicationGeometry, AdmittedIdentities,
    TransactionIdentities, Phases, Results, ActionNames

THEOREM PublishBatchPreservesSafety == InductiveSafety /\ PublishBatch => InductiveSafety'
<1> QED BY DEF PublishBatch, InductiveSafety, RecordTypeOK,
    AdmissionBeforePublication, Safety, TypeOK, ReservationAccounting, NoAliasedFreeze,
    CollisionStopsBeforePublication, PublicationGeometry, AdmittedIdentities,
    TransactionIdentities, Phases, Results, ActionNames

THEOREM PublishHeadPreservesSafety == InductiveSafety /\ PublishHead => InductiveSafety'
<1> QED BY DEF PublishHead, InductiveSafety, RecordTypeOK,
    AdmissionBeforePublication, Safety, TypeOK, ReservationAccounting, NoAliasedFreeze,
    CollisionStopsBeforePublication, PublicationGeometry, AdmittedIdentities,
    TransactionIdentities, Phases, Results, ActionNames

THEOREM NextPreservesSafety == InductiveSafety /\ Next => InductiveSafety'
<1> QED BY AdmitPreservesSafety, FreezePreservesSafety,
    RejectCollisionPreservesSafety, PublishBatchPreservesSafety,
    PublishHeadPreservesSafety DEF Next

=============================================================================
