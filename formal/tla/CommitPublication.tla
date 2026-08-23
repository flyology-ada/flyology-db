-------------------------- MODULE CommitPublication --------------------------
EXTENDS FiniteSets, Integers, Naturals, TLC

CONSTANTS
    W1, W2,
    T1, T2,
    B1, B2,
    F1, F2,
    Q0, Q1, Q2, Q3, Q4,
    NoWriter, NoBatch, NoTransition

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
    batchTxns,
    batchPrevious,
    batchFirstSequence,
    batchLastSequence,
    batchEpoch,
    batchExpectedOrdinal,
    batchExpectedTransition,
    batchPublicationOrdinal,
    batchPublicationTransition,
    usedTransitionIdentities,
    receipt,
    acknowledged,
    wasUnknown,
    visibleTxns,
    localBatches,
    recoveredBatches,
    recoveredTxns,
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
    batchTxns,
    batchPrevious,
    batchFirstSequence,
    batchLastSequence,
    batchEpoch,
    batchExpectedOrdinal,
    batchExpectedTransition,
    batchPublicationOrdinal,
    batchPublicationTransition,
    usedTransitionIdentities,
    receipt,
    acknowledged,
    wasUnknown,
    visibleTxns,
    localBatches,
    recoveredBatches,
    recoveredTxns,
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
    batchTxns,
    batchPrevious,
    batchFirstSequence,
    batchLastSequence,
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

ReachableTxns == UNION {batchTxns[b] : b \in ReachableBatches}

VisibleFamilies(t) == IF t \in visibleTxns THEN TxnFamilies(t) ELSE {}

PreparedGroup(b) ==
    {t \in Txns : txnBatch[t] = b /\ txnState[t] = "Prepared"}

BatchRepresentative(b) == CHOOSE t \in batchTxns[b] : TRUE

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
    /\ batchTxns = [b \in BatchIds |-> {}]
    /\ batchPrevious = [b \in BatchIds |-> NoBatch]
    /\ batchFirstSequence = [b \in BatchIds |-> 0]
    /\ batchLastSequence = [b \in BatchIds |-> 0]
    /\ batchEpoch = [b \in BatchIds |-> 0]
    /\ batchExpectedOrdinal = [b \in BatchIds |-> 0]
    /\ batchExpectedTransition = [b \in BatchIds |-> NoTransition]
    /\ batchPublicationOrdinal = [b \in BatchIds |-> 0]
    /\ batchPublicationTransition = [b \in BatchIds |-> NoTransition]
    /\ usedTransitionIdentities = {TransitionIdentity(1, Q0)}
    /\ receipt = [t \in Txns |-> "None"]
    /\ acknowledged = {}
    /\ wasUnknown = [t \in Txns |-> FALSE]
    /\ visibleTxns = {}
    /\ localBatches = {}
    /\ recoveredBatches = {}
    /\ recoveredTxns = {}
    /\ recoveredSequence = 0
    /\ crashObserved = FALSE
    /\ stalePublicationObserved = FALSE
    /\ lastAction = "Init"

PrepareGroup(group, w, b, q, action) ==
    /\ group \subseteq Txns
    /\ group # {}
    /\ \A t \in group : txnState[t] = "Idle"
    /\ writerEpoch[w] = epoch
    /\ b \in BatchIds \ remoteBatches
    /\ \A t \in Txns : txnBatch[t] # b
    /\ q \in TransitionIds
    /\ q # headTransition
    /\ TransitionIdentity(headOrdinal + 1, q) \notin usedTransitionIdentities
    /\ txnState' =
        [t \in Txns |-> IF t \in group THEN "Prepared" ELSE txnState[t]]
    /\ txnWriter' =
        [t \in Txns |-> IF t \in group THEN w ELSE txnWriter[t]]
    /\ txnBatch' =
        [t \in Txns |-> IF t \in group THEN b ELSE txnBatch[t]]
    /\ expectedGeneration' =
        [t \in Txns |-> IF t \in group THEN generation ELSE expectedGeneration[t]]
    /\ expectedEpoch' =
        [t \in Txns |-> IF t \in group THEN epoch ELSE expectedEpoch[t]]
    /\ expectedOrdinal' =
        [t \in Txns |-> IF t \in group THEN headOrdinal ELSE expectedOrdinal[t]]
    /\ expectedTransition' =
        [t \in Txns |-> IF t \in group THEN headTransition ELSE expectedTransition[t]]
    /\ publicationOrdinal' =
        [t \in Txns |-> IF t \in group THEN headOrdinal + 1 ELSE publicationOrdinal[t]]
    /\ publicationTransition' =
        [t \in Txns |-> IF t \in group THEN q ELSE publicationTransition[t]]
    /\ usedTransitionIdentities' =
        usedTransitionIdentities \cup {TransitionIdentity(headOrdinal + 1, q)}
    /\ lastAction' = action
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, remoteBatches,
        OtherBatchFields, receipt, acknowledged, wasUnknown, visibleTxns, localBatches,
        recoveredBatches, recoveredTxns, recoveredSequence, crashObserved,
        stalePublicationObserved
       >>

PrepareSingle(t, w, b, q) ==
    PrepareGroup({t}, w, b, q, "PrepareSingle")

PreparePooled(w, b, q) ==
    /\ Cardinality(Txns) > 1
    /\ PrepareGroup(Txns, w, b, q, "PreparePooled")

StoreBatch(b) ==
    LET group == PreparedGroup(b)
        representative == CHOOSE t \in group : TRUE
    IN
    /\ group # {}
    /\ b \in BatchIds \ remoteBatches
    /\ txnState' =
        [t \in Txns |-> IF t \in group THEN "Stored" ELSE txnState[t]]
    /\ remoteBatches' = remoteBatches \cup {b}
    /\ batchTxns' = [batchTxns EXCEPT ![b] = group]
    /\ batchPrevious' = [batchPrevious EXCEPT ![b] = latestBatch]
    /\ batchFirstSequence' = [batchFirstSequence EXCEPT ![b] = sequence + 1]
    /\ batchLastSequence' =
        [batchLastSequence EXCEPT ![b] = sequence + Cardinality(group)]
    /\ batchEpoch' = [batchEpoch EXCEPT ![b] = expectedEpoch[representative]]
    /\ batchExpectedOrdinal' =
        [batchExpectedOrdinal EXCEPT ![b] = expectedOrdinal[representative]]
    /\ batchExpectedTransition' =
        [batchExpectedTransition EXCEPT ![b] = expectedTransition[representative]]
    /\ batchPublicationOrdinal' =
        [batchPublicationOrdinal EXCEPT ![b] = publicationOrdinal[representative]]
    /\ batchPublicationTransition' =
        [batchPublicationTransition EXCEPT ![b] = publicationTransition[representative]]
    /\ localBatches' = localBatches \cup {b}
    /\ lastAction' = "StoreBatch"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        usedTransitionIdentities, receipt, acknowledged, wasUnknown, visibleTxns,
        recoveredBatches, recoveredTxns, recoveredSequence, crashObserved,
        stalePublicationObserved
       >>

GroupAgrees(b) ==
    LET representative == BatchRepresentative(b)
    IN
    /\ batchTxns[b] # {}
    /\ \A t \in batchTxns[b] :
        /\ txnBatch[t] = b
        /\ txnWriter[t] = txnWriter[representative]
        /\ expectedGeneration[t] = expectedGeneration[representative]
        /\ expectedEpoch[t] = expectedEpoch[representative]
        /\ expectedOrdinal[t] = expectedOrdinal[representative]
        /\ expectedTransition[t] = expectedTransition[representative]
        /\ publicationOrdinal[t] = publicationOrdinal[representative]
        /\ publicationTransition[t] = publicationTransition[representative]

CanPublish(b) ==
    LET representative == BatchRepresentative(b)
    IN
    /\ GroupAgrees(b)
    /\ \A t \in batchTxns[b] : txnState[t] = "Stored"
    /\ expectedGeneration[representative] = generation
    /\ expectedEpoch[representative] = epoch
    /\ expectedOrdinal[representative] = headOrdinal
    /\ expectedTransition[representative] = headTransition
    /\ writerEpoch[txnWriter[representative]] = epoch
    /\ b \in remoteBatches
    /\ batchPrevious[b] = latestBatch
    /\ batchFirstSequence[b] = sequence + 1
    /\ batchLastSequence[b] = sequence + Cardinality(batchTxns[b])
    /\ batchExpectedOrdinal[b] = headOrdinal
    /\ batchExpectedTransition[b] = headTransition
    /\ batchPublicationOrdinal[b] = headOrdinal + 1
    /\ batchPublicationTransition[b] = publicationTransition[representative]

PublicationWasStale(b) ==
    LET representative == BatchRepresentative(b)
    IN
    expectedEpoch[representative] # epoch
        \/ writerEpoch[txnWriter[representative]] # epoch

PublicationHistoryAfter(b) ==
    stalePublicationObserved \/ PublicationWasStale(b)

PublishHead(b) ==
    /\ CanPublish(b)
    /\ sequence' = batchLastSequence[b]
    /\ latestBatch' = b
    /\ headOrdinal' = batchPublicationOrdinal[b]
    /\ headTransition' = batchPublicationTransition[b]
    /\ headPredecessor' = headTransition
    /\ generation' = generation + 1
    /\ txnState' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Accepted" ELSE txnState[t]]
    /\ visibleTxns' = visibleTxns \cup batchTxns[b]
    /\ stalePublicationObserved' = PublicationHistoryAfter(b)
    /\ lastAction' = "PublishHead"
    /\ UNCHANGED <<
        epoch, writerEpoch, OtherTxnFields, remoteBatches, OtherBatchFields,
        usedTransitionIdentities, receipt, acknowledged, wasUnknown,
        localBatches, recoveredBatches, recoveredTxns, recoveredSequence,
        crashObserved
       >>

ObserveSuccess(b) ==
    /\ batchTxns[b] # {}
    /\ \A t \in batchTxns[b] : txnState[t] = "Accepted"
    /\ txnState' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Committed" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Committed" ELSE receipt[t]]
    /\ acknowledged' = acknowledged \cup batchTxns[b]
    /\ lastAction' = "ObserveSuccess"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities,
        wasUnknown, visibleTxns, localBatches, recoveredBatches, recoveredTxns,
        recoveredSequence, crashObserved, stalePublicationObserved
       >>

LoseAcceptedResponse(b) ==
    /\ batchTxns[b] # {}
    /\ \A t \in batchTxns[b] : txnState[t] = "Accepted"
    /\ txnState' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Unknown" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Unknown" ELSE receipt[t]]
    /\ wasUnknown' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN TRUE ELSE wasUnknown[t]]
    /\ lastAction' = "LoseAcceptedResponse"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities,
        acknowledged, visibleTxns, localBatches, recoveredBatches, recoveredTxns,
        recoveredSequence, crashObserved, stalePublicationObserved
       >>

LoseUnacceptedResponse(b) ==
    /\ batchTxns[b] # {}
    /\ \A t \in batchTxns[b] : txnState[t] = "Stored"
    /\ txnState' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Unknown" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Unknown" ELSE receipt[t]]
    /\ wasUnknown' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN TRUE ELSE wasUnknown[t]]
    /\ lastAction' = "LoseUnacceptedResponse"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities,
        acknowledged, visibleTxns, localBatches, recoveredBatches, recoveredTxns,
        recoveredSequence, crashObserved, stalePublicationObserved
       >>

ObservePreconditionFailure(b) ==
    /\ batchTxns[b] # {}
    /\ \A t \in batchTxns[b] : txnState[t] = "Stored"
    /\ ~CanPublish(b)
    /\ txnState' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Failed" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |->
            IF t \in batchTxns[b] THEN "PreconditionFailed" ELSE receipt[t]]
    /\ lastAction' = "ObservePreconditionFailure"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, acknowledged,
        wasUnknown, visibleTxns, localBatches, recoveredBatches, recoveredTxns,
        recoveredSequence, crashObserved, stalePublicationObserved
       >>

ResolveCommitted(b) ==
    /\ batchTxns[b] # {}
    /\ \A t \in batchTxns[b] : txnState[t] = "Unknown"
    /\ b \in ReachableBatches
    /\ txnState' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Committed" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Committed" ELSE receipt[t]]
    /\ acknowledged' = acknowledged \cup batchTxns[b]
    /\ lastAction' = "ResolveCommitted"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities,
        wasUnknown, visibleTxns, localBatches, recoveredBatches, recoveredTxns,
        recoveredSequence, crashObserved, stalePublicationObserved
       >>

ResolvePreconditionFailure(b) ==
    LET representative == BatchRepresentative(b)
    IN
    /\ batchTxns[b] # {}
    /\ \A t \in batchTxns[b] : txnState[t] = "Unknown"
    /\ b \notin ReachableBatches
    /\ headOrdinal >= publicationOrdinal[representative]
    /\ txnState' =
        [t \in Txns |-> IF t \in batchTxns[b] THEN "Failed" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |->
            IF t \in batchTxns[b] THEN "PreconditionFailed" ELSE receipt[t]]
    /\ lastAction' = "ResolvePreconditionFailure"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, acknowledged,
        wasUnknown, visibleTxns, localBatches, recoveredBatches, recoveredTxns,
        recoveredSequence, crashObserved, stalePublicationObserved
       >>

AdvanceWriterEpoch(w, q) ==
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
        OtherBatchFields, receipt, acknowledged, wasUnknown, visibleTxns, localBatches,
        recoveredBatches, recoveredTxns, recoveredSequence, crashObserved,
        stalePublicationObserved
       >>

AcquireWriter(w, q) ==
    /\ epoch = 1
    /\ AdvanceWriterEpoch(w, q)

Crash ==
    /\ localBatches # {} \/ recoveredBatches # {} \/ recoveredTxns # {}
        \/ recoveredSequence # 0
    /\ localBatches' = {}
    /\ recoveredBatches' = {}
    /\ recoveredTxns' = {}
    /\ recoveredSequence' = 0
    /\ crashObserved' = TRUE
    /\ lastAction' = "Crash"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, txnState, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, receipt,
        acknowledged, wasUnknown, visibleTxns, stalePublicationObserved
       >>

Recover ==
    /\ recoveredBatches # ReachableBatches \/ recoveredTxns # ReachableTxns
        \/ recoveredSequence # sequence
    /\ recoveredBatches' = ReachableBatches
    /\ recoveredTxns' = ReachableTxns
    /\ recoveredSequence' = sequence
    /\ lastAction' = "Recover"
    /\ UNCHANGED <<
        epoch, sequence, latestBatch, headOrdinal, headTransition,
        headPredecessor, generation, writerEpoch, txnState, OtherTxnFields,
        remoteBatches, OtherBatchFields, usedTransitionIdentities, receipt,
        acknowledged, wasUnknown, visibleTxns, localBatches, crashObserved,
        stalePublicationObserved
       >>

Next ==
    \/ \E t \in Txns, w \in Writers, b \in BatchIds,
          q \in TransitionIds : PrepareSingle(t, w, b, q)
    \/ \E w \in Writers, b \in BatchIds,
          q \in TransitionIds : PreparePooled(w, b, q)
    \/ \E b \in BatchIds : StoreBatch(b)
    \/ \E b \in BatchIds : PublishHead(b)
    \/ \E b \in BatchIds : ObserveSuccess(b)
    \/ \E b \in BatchIds : LoseAcceptedResponse(b)
    \/ \E b \in BatchIds : LoseUnacceptedResponse(b)
    \/ \E b \in BatchIds : ObservePreconditionFailure(b)
    \/ \E b \in BatchIds : ResolveCommitted(b)
    \/ \E b \in BatchIds : ResolvePreconditionFailure(b)
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
    /\ batchTxns \in [BatchIds -> SUBSET Txns]
    /\ batchPrevious \in [BatchIds -> BatchIds \cup {NoBatch}]
    /\ batchFirstSequence \in [BatchIds -> Nat]
    /\ batchLastSequence \in [BatchIds -> Nat]
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
    /\ visibleTxns \subseteq Txns
    /\ localBatches \subseteq remoteBatches
    /\ recoveredBatches \subseteq remoteBatches
    /\ recoveredTxns \subseteq Txns
    /\ recoveredSequence \in Nat
    /\ crashObserved \in BOOLEAN
    /\ stalePublicationObserved \in BOOLEAN
    /\ lastAction \in {
        "Init", "PrepareSingle", "PreparePooled", "StoreBatch", "PublishHead",
        "ObserveSuccess", "LoseAcceptedResponse", "LoseUnacceptedResponse",
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
          /\ batchLastSequence[latestBatch] = sequence
          /\ batchPublicationOrdinal[latestBatch] <= headOrdinal

ReachableChain ==
    /\ ReachableBatches \subseteq remoteBatches
    /\ Cardinality(ReachableTxns) = sequence
    /\ \A b \in ReachableBatches :
        /\ batchTxns[b] # {}
        /\ GroupAgrees(b)
        /\ batchFirstSequence[b] > 0
        /\ batchLastSequence[b] =
            batchFirstSequence[b] + Cardinality(batchTxns[b]) - 1
        /\ batchEpoch[b] <= epoch
        /\ batchPublicationOrdinal[b] = batchExpectedOrdinal[b] + 1
        /\ IF batchPrevious[b] = NoBatch
           THEN batchFirstSequence[b] = 1
           ELSE
              /\ batchPrevious[b] \in ReachableBatches
              /\ batchLastSequence[batchPrevious[b]] + 1 =
                  batchFirstSequence[b]

DurableAcknowledgement ==
    \A t \in acknowledged :
        /\ receipt[t] = "Committed"
        /\ txnState[t] = "Committed"
        /\ txnBatch[t] \in ReachableBatches
        /\ t \in batchTxns[txnBatch[t]]
        /\ VisibleFamilies(t) = TxnFamilies(t)

PooledVisibilityIsAtomic ==
    /\ visibleTxns = ReachableTxns
    /\ \A b \in ReachableBatches : batchTxns[b] \subseteq visibleTxns

BatchTransactionsAreDisjoint ==
    \A left, right \in remoteBatches :
        left # right => batchTxns[left] \intersect batchTxns[right] = {}

BatchOutcomesAgree ==
    \A b \in remoteBatches :
        LET representative == BatchRepresentative(b)
        IN \A t \in batchTxns[b] :
            /\ txnState[t] = txnState[representative]
            /\ receipt[t] = receipt[representative]
            /\ (t \in acknowledged) = (representative \in acknowledged)
            /\ wasUnknown[t] = wasUnknown[representative]

UnknownIsTerminal ==
    \A t \in Txns :
        wasUnknown[t] => txnState[t] \notin {"Idle", "Prepared", "Stored", "Accepted"}

RecoveryIsPrefix ==
    /\ recoveredBatches \subseteq ReachableBatches
    /\ recoveredTxns = UNION {batchTxns[b] : b \in recoveredBatches}
    /\ recoveredTxns \subseteq ReachableTxns
    /\ recoveredSequence = Cardinality(recoveredTxns)
    /\ recoveredSequence <= sequence
    /\ recoveredSequence = 0 <=> recoveredBatches = {}
    /\ recoveredSequence = sequence => recoveredBatches = ReachableBatches

RecoveredBatchesAreAtomic ==
    \A b \in recoveredBatches : batchTxns[b] \subseteq recoveredTxns

NoStaleWriterPublication == ~stalePublicationObserved

Safety ==
    TypeOK /\ HeadShape /\ ReachableChain /\ DurableAcknowledgement
        /\ PooledVisibilityIsAtomic /\ BatchTransactionsAreDisjoint
        /\ BatchOutcomesAgree
        /\ UnknownIsTerminal /\ RecoveryIsPrefix
        /\ RecoveredBatchesAreAtomic /\ NoStaleWriterPublication

WitnessComplete ==
    /\ batchTxns[B1] = Txns
    /\ txnBatch[T1] = B1
    /\ txnBatch[T2] = B1
    /\ wasUnknown[T1]
    /\ wasUnknown[T2]
    /\ receipt[T1] = "Committed"
    /\ receipt[T2] = "Committed"
    /\ crashObserved
    /\ recoveredSequence = 2
    /\ recoveredBatches = {B1}
    /\ recoveredTxns = Txns

=============================================================================
