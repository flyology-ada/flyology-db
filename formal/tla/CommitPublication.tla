-------------------------- MODULE CommitPublication --------------------------
EXTENDS FiniteSets, Integers, Naturals, TLC

CONSTANTS
    W1, W2,
    T1, T2,
    B1, B2,
    F1, F2,
    Q0, Q1, Q2, Q3, Q4,
    NoWriter, NoTxn, NoBatch, NoTransition

Writers == {W1, W2}
Txns == {T1, T2}
BatchIds == {B1, B2}
Families == {F1, F2}
TransitionIds == {Q0, Q1, Q2, Q3, Q4}
TransitionSymmetry == Permutations({Q1, Q2, Q3, Q4})

TransitionIdentity(number, value) == [ordinal |-> number, id |-> value]

TxnFamilies(t) == IF t = T1 THEN {F1, F2} ELSE {F2}

TxnStates ==
    {"Idle", "Prepared", "Stored", "Accepted", "Unknown", "Committed", "Failed"}
ReceiptStates == {"None", "Unknown", "Committed", "PreconditionFailed"}

VARIABLES
    epoch,
    sequence,
    latestBatch,
    headOrdinal,
    headTransition,
    headPredecessor,
    generation,
    writerEpoch,
    txnState,
    txnWriter,
    txnBatch,
    expectedGeneration,
    expectedEpoch,
    expectedOrdinal,
    expectedTransition,
    publicationOrdinal,
    publicationTransition,
    remoteBatches,
    batchTxn,
    batchPrevious,
    batchSequence,
    batchEpoch,
    batchExpectedOrdinal,
    batchExpectedTransition,
    batchPublicationOrdinal,
    batchPublicationTransition,
    usedTransitionIdentities,
    receipt,
    acknowledged,
    wasUnknown,
    localBatches,
    recoveredBatches,
    recoveredSequence,
    crashObserved,
    stalePublicationObserved,
    lastAction

vars == <<
    epoch,
    sequence,
    latestBatch,
    headOrdinal,
    headTransition,
    headPredecessor,
    generation,
    writerEpoch,
    txnState,
    txnWriter,
    txnBatch,
    expectedGeneration,
    expectedEpoch,
    expectedOrdinal,
    expectedTransition,
    publicationOrdinal,
    publicationTransition,
    remoteBatches,
    batchTxn,
    batchPrevious,
    batchSequence,
    batchEpoch,
    batchExpectedOrdinal,
    batchExpectedTransition,
    batchPublicationOrdinal,
    batchPublicationTransition,
    usedTransitionIdentities,
    receipt,
    acknowledged,
    wasUnknown,
    localBatches,
    recoveredBatches,
    recoveredSequence,
    crashObserved,
    stalePublicationObserved,
    lastAction
>>

OtherTxnFields == <<
    txnWriter,
    txnBatch,
    expectedGeneration,
    expectedEpoch,
    expectedOrdinal,
    expectedTransition,
    publicationOrdinal,
    publicationTransition
>>

OtherBatchFields == <<
    batchTxn,
    batchPrevious,
    batchSequence,
    batchEpoch,
    batchExpectedOrdinal,
    batchExpectedTransition,
    batchPublicationOrdinal,
    batchPublicationTransition
>>

RECURSIVE ReachFrom(_, _)
ReachFrom(frontier, remaining) ==
    IF remaining = 0
    THEN frontier
    ELSE
        LET linked ==
                {b \in frontier : batchPrevious[b] # NoBatch}
            predecessors == {batchPrevious[b] : b \in linked}
        IN ReachFrom(frontier \cup predecessors, remaining - 1)

ReachableBatches ==
    IF latestBatch = NoBatch
    THEN {}
    ELSE ReachFrom({latestBatch}, Cardinality(BatchIds))

VisibleFamilies(t) ==
    IF \E b \in ReachableBatches : batchTxn[b] = t
    THEN TxnFamilies(t)
    ELSE {}

Init ==
    /\ epoch = 1
    /\ sequence = 0
    /\ latestBatch = NoBatch
    /\ headOrdinal = 1
    /\ headTransition = Q0
    /\ headPredecessor = NoTransition
    /\ generation = 1
    /\ writerEpoch = [w \in Writers |-> IF w = W1 THEN 1 ELSE 0]
    /\ txnState = [t \in Txns |-> "Idle"]
    /\ txnWriter = [t \in Txns |-> NoWriter]
    /\ txnBatch = [t \in Txns |-> NoBatch]
    /\ expectedGeneration = [t \in Txns |-> 0]
    /\ expectedEpoch = [t \in Txns |-> 0]
    /\ expectedOrdinal = [t \in Txns |-> 0]
    /\ expectedTransition = [t \in Txns |-> NoTransition]
    /\ publicationOrdinal = [t \in Txns |-> 0]
    /\ publicationTransition = [t \in Txns |-> NoTransition]
    /\ remoteBatches = {}
    /\ batchTxn = [b \in BatchIds |-> NoTxn]
    /\ batchPrevious = [b \in BatchIds |-> NoBatch]
    /\ batchSequence = [b \in BatchIds |-> 0]
    /\ batchEpoch = [b \in BatchIds |-> 0]
    /\ batchExpectedOrdinal = [b \in BatchIds |-> 0]
    /\ batchExpectedTransition = [b \in BatchIds |-> NoTransition]
    /\ batchPublicationOrdinal = [b \in BatchIds |-> 0]
    /\ batchPublicationTransition = [b \in BatchIds |-> NoTransition]
    /\ usedTransitionIdentities = {TransitionIdentity(1, Q0)}
    /\ receipt = [t \in Txns |-> "None"]
    /\ acknowledged = {}
    /\ wasUnknown = [t \in Txns |-> FALSE]
    /\ localBatches = {}
    /\ recoveredBatches = {}
    /\ recoveredSequence = 0
    /\ crashObserved = FALSE
    /\ stalePublicationObserved = FALSE
    /\ lastAction = "Init"

Prepare(t, w, b, q) ==
    /\ txnState[t] = "Idle"
    /\ writerEpoch[w] = epoch
    /\ b \notin remoteBatches
    /\ \A other \in Txns : txnState[other] # "Prepared" \/ txnBatch[other] # b
    /\ q \in TransitionIds
    /\ q # headTransition
    /\ TransitionIdentity(headOrdinal + 1, q) \notin usedTransitionIdentities
    /\ txnState' = [txnState EXCEPT ![t] = "Prepared"]
    /\ txnWriter' = [txnWriter EXCEPT ![t] = w]
    /\ txnBatch' = [txnBatch EXCEPT ![t] = b]
    /\ expectedGeneration' = [expectedGeneration EXCEPT ![t] = generation]
    /\ expectedEpoch' = [expectedEpoch EXCEPT ![t] = epoch]
    /\ expectedOrdinal' = [expectedOrdinal EXCEPT ![t] = headOrdinal]
    /\ expectedTransition' = [expectedTransition EXCEPT ![t] = headTransition]
    /\ publicationOrdinal' = [publicationOrdinal EXCEPT ![t] = headOrdinal + 1]
    /\ publicationTransition' = [publicationTransition EXCEPT ![t] = q]
    /\ usedTransitionIdentities' =
        usedTransitionIdentities \cup {TransitionIdentity(headOrdinal + 1, q)}
    /\ lastAction' = "Prepare"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, remoteBatches,
        OtherBatchFields, receipt, acknowledged, wasUnknown, localBatches,
        recoveredBatches, recoveredSequence, crashObserved,
        stalePublicationObserved
       >>

StoreBatch(t) ==
    LET b == txnBatch[t]
    IN
    /\ txnState[t] = "Prepared"
    /\ b \in BatchIds \ remoteBatches
    /\ txnState' = [txnState EXCEPT ![t] = "Stored"]
    /\ remoteBatches' = remoteBatches \cup {b}
    /\ batchTxn' = [batchTxn EXCEPT ![b] = t]
    /\ batchPrevious' = [batchPrevious EXCEPT ![b] = latestBatch]
    /\ batchSequence' = [batchSequence EXCEPT ![b] = sequence + 1]
    /\ batchEpoch' = [batchEpoch EXCEPT ![b] = expectedEpoch[t]]
    /\ batchExpectedOrdinal' =
        [batchExpectedOrdinal EXCEPT ![b] = expectedOrdinal[t]]
    /\ batchExpectedTransition' =
        [batchExpectedTransition EXCEPT ![b] = expectedTransition[t]]
    /\ batchPublicationOrdinal' =
        [batchPublicationOrdinal EXCEPT ![b] = publicationOrdinal[t]]
    /\ batchPublicationTransition' =
        [batchPublicationTransition EXCEPT ![b] = publicationTransition[t]]
    /\ localBatches' = localBatches \cup {b}
    /\ lastAction' = "StoreBatch"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        usedTransitionIdentities, receipt, acknowledged, wasUnknown,
        recoveredBatches, recoveredSequence, crashObserved,
        stalePublicationObserved
       >>

CanPublish(t) ==
    LET b == txnBatch[t]
    IN
    /\ txnState[t] = "Stored"
    /\ expectedGeneration[t] = generation
    /\ expectedEpoch[t] = epoch
    /\ expectedOrdinal[t] = headOrdinal
    /\ expectedTransition[t] = headTransition
    /\ writerEpoch[txnWriter[t]] = epoch
    /\ b \in remoteBatches
    /\ batchPrevious[b] = latestBatch
    /\ batchSequence[b] = sequence + 1
    /\ batchExpectedOrdinal[b] = headOrdinal
    /\ batchExpectedTransition[b] = headTransition
    /\ batchPublicationOrdinal[b] = headOrdinal + 1
    /\ batchPublicationTransition[b] = publicationTransition[t]

PublicationWasStale(t) ==
    expectedEpoch[t] # epoch \/ writerEpoch[txnWriter[t]] # epoch

PublicationHistoryAfter(t) ==
    stalePublicationObserved \/ PublicationWasStale(t)

PublishHead(t) ==
    LET b == txnBatch[t]
    IN
    /\ CanPublish(t)
    /\ sequence' = batchSequence[b]
    /\ latestBatch' = b
    /\ headOrdinal' = publicationOrdinal[t]
    /\ headTransition' = publicationTransition[t]
    /\ headPredecessor' = headTransition
    /\ generation' = generation + 1
    /\ txnState' = [txnState EXCEPT ![t] = "Accepted"]
    /\ stalePublicationObserved' = PublicationHistoryAfter(t)
    /\ lastAction' = "PublishHead"
    /\ UNCHANGED <<
        epoch, writerEpoch, OtherTxnFields, remoteBatches, OtherBatchFields,
        usedTransitionIdentities, receipt, acknowledged, wasUnknown,
        localBatches, recoveredBatches, recoveredSequence, crashObserved
       >>

ObserveSuccess(t) ==
    /\ txnState[t] = "Accepted"
    /\ txnState' = [txnState EXCEPT ![t] = "Committed"]
    /\ receipt' = [receipt EXCEPT ![t] = "Committed"]
    /\ acknowledged' = acknowledged \cup {t}
    /\ lastAction' = "ObserveSuccess"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities,
        wasUnknown, localBatches, recoveredBatches, recoveredSequence,
        crashObserved, stalePublicationObserved
       >>

LoseAcceptedResponse(t) ==
    /\ txnState[t] = "Accepted"
    /\ txnState' = [txnState EXCEPT ![t] = "Unknown"]
    /\ receipt' = [receipt EXCEPT ![t] = "Unknown"]
    /\ wasUnknown' = [wasUnknown EXCEPT ![t] = TRUE]
    /\ lastAction' = "LoseAcceptedResponse"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities,
        acknowledged, localBatches, recoveredBatches, recoveredSequence,
        crashObserved, stalePublicationObserved
       >>

LoseUnacceptedResponse(t) ==
    /\ txnState[t] = "Stored"
    /\ txnState' = [txnState EXCEPT ![t] = "Unknown"]
    /\ receipt' = [receipt EXCEPT ![t] = "Unknown"]
    /\ wasUnknown' = [wasUnknown EXCEPT ![t] = TRUE]
    /\ lastAction' = "LoseUnacceptedResponse"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities,
        acknowledged, localBatches, recoveredBatches, recoveredSequence,
        crashObserved, stalePublicationObserved
       >>

ObservePreconditionFailure(t) ==
    /\ txnState[t] = "Stored"
    /\ ~CanPublish(t)
    /\ txnState' = [txnState EXCEPT ![t] = "Failed"]
    /\ receipt' = [receipt EXCEPT ![t] = "PreconditionFailed"]
    /\ lastAction' = "ObservePreconditionFailure"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, acknowledged,
        wasUnknown, localBatches, recoveredBatches, recoveredSequence,
        crashObserved, stalePublicationObserved
       >>

ResolveCommitted(t) ==
    /\ txnState[t] = "Unknown"
    /\ \/ /\ headOrdinal = publicationOrdinal[t]
           /\ headTransition = publicationTransition[t]
           /\ latestBatch = txnBatch[t]
       \/ /\ headOrdinal = publicationOrdinal[t] + 1
           /\ headPredecessor = publicationTransition[t]
           /\ txnBatch[t] \in ReachableBatches
    /\ txnState' = [txnState EXCEPT ![t] = "Committed"]
    /\ receipt' = [receipt EXCEPT ![t] = "Committed"]
    /\ acknowledged' = acknowledged \cup {t}
    /\ lastAction' = "ResolveCommitted"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities,
        wasUnknown, localBatches, recoveredBatches, recoveredSequence,
        crashObserved, stalePublicationObserved
       >>

ResolvePreconditionFailure(t) ==
    /\ txnState[t] = "Unknown"
    /\ headOrdinal = expectedOrdinal[t] + 1
    /\ headPredecessor = expectedTransition[t]
    /\ headTransition # publicationTransition[t]
    /\ txnState' = [txnState EXCEPT ![t] = "Failed"]
    /\ receipt' = [receipt EXCEPT ![t] = "PreconditionFailed"]
    /\ lastAction' = "ResolvePreconditionFailure"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, acknowledged,
        wasUnknown, localBatches, recoveredBatches, recoveredSequence,
        crashObserved, stalePublicationObserved
       >>

AcquireWriter(w, q) ==
    /\ epoch = 1
    /\ q \in TransitionIds
    /\ q # headTransition
    /\ TransitionIdentity(headOrdinal + 1, q) \notin usedTransitionIdentities
    /\ epoch' = epoch + 1
    /\ headOrdinal' = headOrdinal + 1
    /\ headTransition' = q
    /\ headPredecessor' = headTransition
    /\ generation' = generation + 1
    /\ writerEpoch' = [writerEpoch EXCEPT ![w] = epoch + 1]
    /\ usedTransitionIdentities' =
        usedTransitionIdentities \cup {TransitionIdentity(headOrdinal + 1, q)}
    /\ lastAction' = "AcquireWriter"
    /\ UNCHANGED <<
        sequence, latestBatch, txnState, OtherTxnFields, remoteBatches,
        OtherBatchFields, receipt, acknowledged, wasUnknown, localBatches,
        recoveredBatches, recoveredSequence, crashObserved,
        stalePublicationObserved
       >>

Crash ==
    /\ localBatches # {} \/ recoveredBatches # {} \/ recoveredSequence # 0
    /\ localBatches' = {}
    /\ recoveredBatches' = {}
    /\ recoveredSequence' = 0
    /\ crashObserved' = TRUE
    /\ lastAction' = "Crash"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, txnState, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, receipt,
        acknowledged, wasUnknown, stalePublicationObserved
       >>

Recover ==
    /\ recoveredBatches # ReachableBatches \/ recoveredSequence # sequence
    /\ recoveredBatches' = ReachableBatches
    /\ recoveredSequence' = sequence
    /\ lastAction' = "Recover"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, txnState, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, receipt,
        acknowledged, wasUnknown, localBatches, crashObserved,
        stalePublicationObserved
       >>

Next ==
    \/ \E t \in Txns, w \in Writers, b \in BatchIds,
          q \in TransitionIds : Prepare(t, w, b, q)
    \/ \E t \in Txns : StoreBatch(t)
    \/ \E t \in Txns : PublishHead(t)
    \/ \E t \in Txns : ObserveSuccess(t)
    \/ \E t \in Txns : LoseAcceptedResponse(t)
    \/ \E t \in Txns : LoseUnacceptedResponse(t)
    \/ \E t \in Txns : ObservePreconditionFailure(t)
    \/ \E t \in Txns : ResolveCommitted(t)
    \/ \E t \in Txns : ResolvePreconditionFailure(t)
    \/ \E w \in Writers, q \in TransitionIds : AcquireWriter(w, q)
    \/ Crash
    \/ Recover

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ epoch \in Nat \ {0}
    /\ sequence \in Nat
    /\ latestBatch \in BatchIds \cup {NoBatch}
    /\ headOrdinal \in Nat \ {0}
    /\ headTransition \in TransitionIds
    /\ headPredecessor \in TransitionIds \cup {NoTransition}
    /\ generation \in Nat \ {0}
    /\ writerEpoch \in [Writers -> Nat]
    /\ txnState \in [Txns -> TxnStates]
    /\ txnWriter \in [Txns -> Writers \cup {NoWriter}]
    /\ txnBatch \in [Txns -> BatchIds \cup {NoBatch}]
    /\ expectedGeneration \in [Txns -> Nat]
    /\ expectedEpoch \in [Txns -> Nat]
    /\ expectedOrdinal \in [Txns -> Nat]
    /\ expectedTransition \in [Txns -> TransitionIds \cup {NoTransition}]
    /\ publicationOrdinal \in [Txns -> Nat]
    /\ publicationTransition \in [Txns -> TransitionIds \cup {NoTransition}]
    /\ remoteBatches \subseteq BatchIds
    /\ batchTxn \in [BatchIds -> Txns \cup {NoTxn}]
    /\ batchPrevious \in [BatchIds -> BatchIds \cup {NoBatch}]
    /\ batchSequence \in [BatchIds -> Nat]
    /\ batchEpoch \in [BatchIds -> Nat]
    /\ batchExpectedOrdinal \in [BatchIds -> Nat]
    /\ batchExpectedTransition \in
        [BatchIds -> TransitionIds \cup {NoTransition}]
    /\ batchPublicationOrdinal \in [BatchIds -> Nat]
    /\ batchPublicationTransition \in
        [BatchIds -> TransitionIds \cup {NoTransition}]
    /\ usedTransitionIdentities \subseteq
        [ordinal : Nat \ {0}, id : TransitionIds]
    /\ receipt \in [Txns -> ReceiptStates]
    /\ acknowledged \subseteq Txns
    /\ wasUnknown \in [Txns -> BOOLEAN]
    /\ localBatches \subseteq remoteBatches
    /\ recoveredBatches \subseteq remoteBatches
    /\ recoveredSequence \in Nat
    /\ crashObserved \in BOOLEAN
    /\ stalePublicationObserved \in BOOLEAN
    /\ lastAction \in {
        "Init", "Prepare", "StoreBatch", "PublishHead", "ObserveSuccess",
        "LoseAcceptedResponse", "LoseUnacceptedResponse",
        "ObservePreconditionFailure", "ResolveCommitted",
        "ResolvePreconditionFailure", "AcquireWriter", "Crash", "Recover"
       }

HeadShape ==
    /\ headOrdinal >= epoch
    /\ TransitionIdentity(headOrdinal, headTransition) \in
        usedTransitionIdentities
    /\ IF sequence = 0
       THEN latestBatch = NoBatch
       ELSE
          /\ latestBatch \in remoteBatches
          /\ batchSequence[latestBatch] = sequence
          /\ batchPublicationOrdinal[latestBatch] <= headOrdinal

ReachableChain ==
    /\ ReachableBatches \subseteq remoteBatches
    /\ Cardinality(ReachableBatches) = sequence
    /\ \A b \in ReachableBatches :
        /\ batchTxn[b] \in Txns
        /\ batchEpoch[b] <= epoch
        /\ batchPublicationOrdinal[b] = batchExpectedOrdinal[b] + 1
        /\ IF batchPrevious[b] = NoBatch
           THEN batchSequence[b] = 1
           ELSE
              /\ batchPrevious[b] \in ReachableBatches
              /\ batchSequence[batchPrevious[b]] + 1 = batchSequence[b]

DurableAcknowledgement ==
    \A t \in acknowledged :
        /\ receipt[t] = "Committed"
        /\ txnState[t] = "Committed"
        /\ txnBatch[t] \in ReachableBatches
        /\ VisibleFamilies(t) = TxnFamilies(t)

UnknownIsTerminal ==
    \A t \in Txns :
        wasUnknown[t] => txnState[t] \notin {"Idle", "Prepared", "Stored", "Accepted"}

RecoveryIsPrefix ==
    /\ recoveredBatches \subseteq ReachableBatches
    /\ recoveredSequence <= sequence
    /\ recoveredSequence = 0 <=> recoveredBatches = {}
    /\ recoveredSequence = sequence => recoveredBatches = ReachableBatches

NoStaleWriterPublication == ~stalePublicationObserved

Safety ==
    TypeOK /\ HeadShape /\ ReachableChain /\ DurableAcknowledgement
        /\ UnknownIsTerminal /\ RecoveryIsPrefix /\ NoStaleWriterPublication

WitnessComplete ==
    /\ wasUnknown[T1]
    /\ receipt[T1] = "Committed"
    /\ crashObserved
    /\ recoveredSequence = 1
    /\ recoveredBatches = ReachableBatches

=============================================================================
