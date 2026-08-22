------------------------ MODULE PublicationSafetyProof -----------------------
EXTENDS Naturals

CONSTANTS BatchIds, Txns, NoBatch

ASSUME
    /\ BatchIds # {}
    /\ Txns # {}
    /\ NoBatch \notin BatchIds

Phases == {"Idle", "Active", "Stored", "Accepted", "Unknown", "Committed", "Failed"}

VARIABLES
    remote,
    visible,
    visibleTxns,
    txnBatch,
    phase,
    acknowledged,
    everUnknown,
    epoch,
    publicationEpoch,
    local

vars == <<
    remote,
    visible,
    visibleTxns,
    txnBatch,
    phase,
    acknowledged,
    everUnknown,
    epoch,
    publicationEpoch,
    local
>>

Init ==
    /\ remote = {}
    /\ visible = {}
    /\ visibleTxns = {}
    /\ txnBatch = [t \in Txns |-> NoBatch]
    /\ phase = [t \in Txns |-> "Idle"]
    /\ acknowledged = {}
    /\ everUnknown = {}
    /\ epoch = 1
    /\ publicationEpoch = [b \in BatchIds |-> 0]
    /\ local = {}

Prepare(t) ==
    /\ t \in Txns
    /\ phase[t] = "Idle"
    /\ phase' = [phase EXCEPT ![t] = "Active"]
    /\ UNCHANGED <<
        remote, visible, visibleTxns, txnBatch, acknowledged, everUnknown,
        epoch, publicationEpoch, local
       >>

Store(t, b) ==
    /\ t \in Txns
    /\ b \in BatchIds \ remote
    /\ phase[t] = "Active"
    /\ remote' = remote \cup {b}
    /\ txnBatch' = [txnBatch EXCEPT ![t] = b]
    /\ phase' = [phase EXCEPT ![t] = "Stored"]
    /\ local' = local \cup {b}
    /\ UNCHANGED <<
        visible, visibleTxns, acknowledged, everUnknown, epoch,
        publicationEpoch
       >>

Publish(t) ==
    LET b == txnBatch[t]
    IN
    /\ t \in Txns
    /\ phase[t] = "Stored"
    /\ b \in remote
    /\ visible' = visible \cup {b}
    /\ visibleTxns' = visibleTxns \cup {t}
    /\ phase' = [phase EXCEPT ![t] = "Accepted"]
    /\ publicationEpoch' = [publicationEpoch EXCEPT ![b] = epoch]
    /\ UNCHANGED <<
        remote, txnBatch, acknowledged, everUnknown, epoch, local
       >>

ObserveSuccess(t) ==
    /\ t \in Txns
    /\ phase[t] = "Accepted"
    /\ t \in visibleTxns
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ acknowledged' = acknowledged \cup {t}
    /\ UNCHANGED <<
        remote, visible, visibleTxns, txnBatch, everUnknown, epoch,
        publicationEpoch, local
       >>

LoseResponse(t) ==
    /\ t \in Txns
    /\ phase[t] \in {"Stored", "Accepted"}
    /\ phase' = [phase EXCEPT ![t] = "Unknown"]
    /\ everUnknown' = everUnknown \cup {t}
    /\ UNCHANGED <<
        remote, visible, visibleTxns, txnBatch, acknowledged, epoch,
        publicationEpoch, local
       >>

ResolveCommitted(t) ==
    /\ t \in Txns
    /\ phase[t] = "Unknown"
    /\ t \in visibleTxns
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ acknowledged' = acknowledged \cup {t}
    /\ UNCHANGED <<
        remote, visible, visibleTxns, txnBatch, everUnknown, epoch,
        publicationEpoch, local
       >>

ResolveFailed(t) ==
    /\ t \in Txns
    /\ phase[t] = "Unknown"
    /\ t \notin visibleTxns
    /\ phase' = [phase EXCEPT ![t] = "Failed"]
    /\ UNCHANGED <<
        remote, visible, visibleTxns, txnBatch, acknowledged, everUnknown,
        epoch, publicationEpoch, local
       >>

AcquireWriter ==
    /\ epoch' = epoch + 1
    /\ UNCHANGED <<
        remote, visible, visibleTxns, txnBatch, phase, acknowledged,
        everUnknown, publicationEpoch, local
       >>

Crash ==
    /\ local' = {}
    /\ UNCHANGED <<
        remote, visible, visibleTxns, txnBatch, phase, acknowledged,
        everUnknown, epoch, publicationEpoch
       >>

Next ==
    \/ \E t \in Txns : Prepare(t)
    \/ \E t \in Txns, b \in BatchIds : Store(t, b)
    \/ \E t \in Txns : Publish(t)
    \/ \E t \in Txns : ObserveSuccess(t)
    \/ \E t \in Txns : LoseResponse(t)
    \/ \E t \in Txns : ResolveCommitted(t)
    \/ \E t \in Txns : ResolveFailed(t)
    \/ AcquireWriter
    \/ Crash

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ remote \subseteq BatchIds
    /\ visible \subseteq BatchIds
    /\ visibleTxns \subseteq Txns
    /\ txnBatch \in [Txns -> BatchIds \cup {NoBatch}]
    /\ phase \in [Txns -> Phases]
    /\ acknowledged \subseteq Txns
    /\ everUnknown \subseteq Txns
    /\ epoch \in Nat \ {0}
    /\ publicationEpoch \in [BatchIds -> Nat]
    /\ local \subseteq BatchIds

VisibilityIsRemote == visible \subseteq remote

AcknowledgementIsVisible == acknowledged \subseteq visibleTxns

PublicationEpochIsMonotonic == \A b \in visible : publicationEpoch[b] <= epoch

UnknownCannotReplay ==
    \A t \in everUnknown : phase[t] \notin {"Idle", "Active", "Stored", "Accepted"}

LocalIsOnlyACache == local \subseteq remote

Safety ==
    TypeOK
        /\ VisibilityIsRemote
        /\ AcknowledgementIsVisible
        /\ PublicationEpochIsMonotonic
        /\ UnknownCannotReplay
        /\ LocalIsOnlyACache

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM PreparePreservesSafety ==
    \A t \in Txns : Safety /\ Prepare(t) => Safety'
<1> QED BY DEF Prepare, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM StorePreservesSafety ==
    \A t \in Txns, b \in BatchIds : Safety /\ Store(t, b) => Safety'
<1> QED BY DEF Store, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM PublishPreservesSafety ==
    \A t \in Txns : Safety /\ Publish(t) => Safety'
<1> QED BY DEF Publish, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM SuccessPreservesSafety ==
    \A t \in Txns : Safety /\ ObserveSuccess(t) => Safety'
<1> QED BY DEF ObserveSuccess, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM LossPreservesSafety ==
    \A t \in Txns : Safety /\ LoseResponse(t) => Safety'
<1> QED BY DEF LoseResponse, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM ResolveCommitPreservesSafety ==
    \A t \in Txns : Safety /\ ResolveCommitted(t) => Safety'
<1> QED BY DEF ResolveCommitted, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM ResolveFailurePreservesSafety ==
    \A t \in Txns : Safety /\ ResolveFailed(t) => Safety'
<1> QED BY DEF ResolveFailed, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM AcquisitionPreservesSafety == Safety /\ AcquireWriter => Safety'
<1> QED BY DEF AcquireWriter, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> QED BY DEF Crash, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, PublicationEpochIsMonotonic, UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM NextPreservesSafety == Safety /\ Next => Safety'
<1> QED BY PreparePreservesSafety, StorePreservesSafety,
    PublishPreservesSafety, SuccessPreservesSafety, LossPreservesSafety,
    ResolveCommitPreservesSafety, ResolveFailurePreservesSafety,
    AcquisitionPreservesSafety, CrashPreservesSafety DEF Next

=============================================================================
