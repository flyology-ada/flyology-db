------------------------ MODULE PublicationSafetyProof -----------------------
EXTENDS Naturals

CONSTANTS BatchIds, Txns, BatchTransactions

BatchTransactionsAreDisjoint ==
    \A left, right \in BatchIds :
        left # right => BatchTransactions[left] \intersect BatchTransactions[right] = {}

OwnershipAssumptions ==
    /\ BatchIds # {}
    /\ Txns # {}
    /\ BatchTransactions \in [BatchIds -> SUBSET Txns]
    /\ \A b \in BatchIds : BatchTransactions[b] # {}
    /\ BatchTransactionsAreDisjoint

ASSUME OwnershipAssumptions

Phases == {"Idle", "Active", "Stored", "Accepted", "Unknown", "Committed", "Failed"}

VARIABLES
    remote,
    visible,
    phase,
    acknowledged,
    everUnknown,
    epoch,
    publicationEpoch,
    local

vars == <<
    remote,
    visible,
    phase,
    acknowledged,
    everUnknown,
    epoch,
    publicationEpoch,
    local
>>

VisibleTxns == UNION {BatchTransactions[b] : b \in visible}
AcknowledgedTxns == UNION {BatchTransactions[b] : b \in acknowledged}
ActiveBatches == {b \in BatchIds : phase[b] \in {"Active", "Stored", "Accepted"}}

Init ==
    /\ remote = {}
    /\ visible = {}
    /\ phase = [b \in BatchIds |-> "Idle"]
    /\ acknowledged = {}
    /\ everUnknown = {}
    /\ epoch = 1
    /\ publicationEpoch = [b \in BatchIds |-> 0]
    /\ local = {}

Prepare(b) ==
    /\ b \in BatchIds
    /\ phase[b] = "Idle"
    /\ phase' = [phase EXCEPT ![b] = "Active"]
    /\ UNCHANGED <<
        remote, visible, acknowledged, everUnknown, epoch, publicationEpoch,
        local
       >>

Store(b) ==
    /\ b \in BatchIds \ remote
    /\ phase[b] = "Active"
    /\ remote' = remote \cup {b}
    /\ phase' = [phase EXCEPT ![b] = "Stored"]
    /\ local' = local \cup {b}
    /\ UNCHANGED <<
        visible, acknowledged, everUnknown, epoch, publicationEpoch
       >>

Publish(b) ==
    /\ b \in remote \ visible
    /\ phase[b] = "Stored"
    /\ visible' = visible \cup {b}
    /\ phase' = [phase EXCEPT ![b] = "Accepted"]
    /\ publicationEpoch' = [publicationEpoch EXCEPT ![b] = epoch]
    /\ UNCHANGED <<remote, acknowledged, everUnknown, epoch, local>>

ObserveSuccess(b) ==
    /\ b \in visible
    /\ phase[b] = "Accepted"
    /\ phase' = [phase EXCEPT ![b] = "Committed"]
    /\ acknowledged' = acknowledged \cup {b}
    /\ UNCHANGED <<
        remote, visible, everUnknown, epoch, publicationEpoch, local
       >>

LoseResponse(b) ==
    /\ b \in remote
    /\ phase[b] \in {"Stored", "Accepted"}
    /\ phase' = [phase EXCEPT ![b] = "Unknown"]
    /\ everUnknown' = everUnknown \cup {b}
    /\ UNCHANGED <<
        remote, visible, acknowledged, epoch, publicationEpoch, local
       >>

ResolveCommitted(b) ==
    /\ b \in visible
    /\ phase[b] = "Unknown"
    /\ phase' = [phase EXCEPT ![b] = "Committed"]
    /\ acknowledged' = acknowledged \cup {b}
    /\ UNCHANGED <<
        remote, visible, everUnknown, epoch, publicationEpoch, local
       >>

ResolveFailed(b) ==
    /\ b \in remote \ visible
    /\ phase[b] = "Unknown"
    /\ phase' = [phase EXCEPT ![b] = "Failed"]
    /\ UNCHANGED <<
        remote, visible, acknowledged, everUnknown, epoch, publicationEpoch,
        local
       >>

AcquireWriter ==
    /\ epoch' = epoch + 1
    /\ UNCHANGED <<
        remote, visible, phase, acknowledged, everUnknown, publicationEpoch,
        local
       >>

Crash ==
    /\ local' = {}
    /\ UNCHANGED <<
        remote, visible, phase, acknowledged, everUnknown, epoch,
        publicationEpoch
       >>

Next ==
    \/ \E b \in BatchIds : Prepare(b)
    \/ \E b \in BatchIds : Store(b)
    \/ \E b \in BatchIds : Publish(b)
    \/ \E b \in BatchIds : ObserveSuccess(b)
    \/ \E b \in BatchIds : LoseResponse(b)
    \/ \E b \in BatchIds : ResolveCommitted(b)
    \/ \E b \in BatchIds : ResolveFailed(b)
    \/ AcquireWriter
    \/ Crash

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ remote \subseteq BatchIds
    /\ visible \subseteq BatchIds
    /\ phase \in [BatchIds -> Phases]
    /\ acknowledged \subseteq BatchIds
    /\ everUnknown \subseteq BatchIds
    /\ epoch \in Nat \ {0}
    /\ publicationEpoch \in [BatchIds -> Nat]
    /\ local \subseteq BatchIds

VisibilityIsRemote == visible \subseteq remote

AcknowledgementIsVisible == acknowledged \subseteq visible

AcknowledgedTransactionsAreVisible == AcknowledgedTxns \subseteq VisibleTxns

PublicationEpochIsMonotonic == \A b \in visible : publicationEpoch[b] <= epoch

UnknownCannotReplay ==
    \A b \in everUnknown : phase[b] \notin {"Idle", "Active", "Stored", "Accepted"}

UnknownTransactionsCannotBeActive ==
    \A unknownBatch \in everUnknown, activeBatch \in ActiveBatches :
        BatchTransactions[unknownBatch] \intersect BatchTransactions[activeBatch] = {}

LocalIsOnlyACache == local \subseteq remote

Safety ==
    TypeOK
        /\ VisibilityIsRemote
        /\ AcknowledgementIsVisible
        /\ AcknowledgedTransactionsAreVisible
        /\ PublicationEpochIsMonotonic
        /\ UnknownCannotReplay
        /\ LocalIsOnlyACache

THEOREM DisjointOwnershipImpliesNoActiveReplay ==
    OwnershipAssumptions /\ TypeOK /\ UnknownCannotReplay =>
        UnknownTransactionsCannotBeActive
<1> QED BY DEF TypeOK, UnknownCannotReplay,
    UnknownTransactionsCannotBeActive, ActiveBatches,
    OwnershipAssumptions, BatchTransactionsAreDisjoint, Phases

THEOREM TransactionLevelNoActiveReplay ==
    OwnershipAssumptions /\ Safety => UnknownTransactionsCannotBeActive
<1> QED BY DisjointOwnershipImpliesNoActiveReplay DEF Safety

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM PreparePreservesSafety ==
    \A b \in BatchIds : Safety /\ Prepare(b) => Safety'
<1> QED BY DEF Prepare, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM StorePreservesSafety ==
    \A b \in BatchIds : Safety /\ Store(b) => Safety'
<1> QED BY DEF Store, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM PublishPreservesSafety ==
    \A b \in BatchIds : Safety /\ Publish(b) => Safety'
<1> QED BY DEF Publish, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM SuccessPreservesSafety ==
    \A b \in BatchIds : Safety /\ ObserveSuccess(b) => Safety'
<1> QED BY DEF ObserveSuccess, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM LossPreservesSafety ==
    \A b \in BatchIds : Safety /\ LoseResponse(b) => Safety'
<1> QED BY DEF LoseResponse, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM ResolveCommitPreservesSafety ==
    \A b \in BatchIds : Safety /\ ResolveCommitted(b) => Safety'
<1> QED BY DEF ResolveCommitted, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM ResolveFailurePreservesSafety ==
    \A b \in BatchIds : Safety /\ ResolveFailed(b) => Safety'
<1> QED BY DEF ResolveFailed, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM AcquisitionPreservesSafety ==
    Safety /\ AcquireWriter => Safety'
<1> QED BY DEF AcquireWriter, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> QED BY DEF Crash, Safety, TypeOK, VisibilityIsRemote,
    AcknowledgementIsVisible, AcknowledgedTransactionsAreVisible,
    AcknowledgedTxns, VisibleTxns, PublicationEpochIsMonotonic,
    UnknownCannotReplay,
    LocalIsOnlyACache, Phases

THEOREM NextPreservesSafety == Safety /\ Next => Safety'
<1> QED BY PreparePreservesSafety, StorePreservesSafety,
    PublishPreservesSafety, SuccessPreservesSafety, LossPreservesSafety,
    ResolveCommitPreservesSafety, ResolveFailurePreservesSafety,
    AcquisitionPreservesSafety, CrashPreservesSafety DEF Next

=============================================================================
