---------------------- MODULE AggregateCommitCoalescing ----------------------
EXTENDS FiniteSets, Naturals, Sequences, TLC

(***************************************************************************
Private, new-root-only shared-physical-batch experiment. Width and Depth in the
configuration are caller-selected qualification geometry, not defaults. Depth
bounds admitted singleton work, including the frozen cohort. One worker owns
one frozen cohort; admission may continue while that worker publishes.

Caller-supplied transaction and aggregate identities are never reused. The
usedTxns/usedBatches sets are specification history: they survive process loss
but are NOT a durable implementation ledger. Reopen reconstructs localBatchIDs
only from HEAD. ObserveMissingIdentityBoundary exposes why an absent orphan
cannot enforce the caller contract; ProbeConfirmedOrphanCollision exposes the
conditional-create barrier when an unreachable immutable object DOES survive.

An image models the full ordered aggregate, including every member's opaque
payload. It is not a model of bytes, CRCs, allocation, or provider internals.
Successful HEAD entry is the only visibility authority. Resolving any member
reads and authenticates the full aggregate; it never writes batch or HEAD.
No fairness, finite-deadline support, tail timeout, retry, or progress guarantee
is selected. Exact-width underfill may wait for input or explicit close.
***************************************************************************)

CONSTANTS T1, T2, T3, T4, B1, B2, NoBatch, NoAuthority,
          DB, OtherDB, Width, Depth

Txns == {T1, T2, T3, T4}
BatchIDs == {B1, B2}
AggregateSymmetry ==
    {[id \in Txns \cup BatchIDs |->
          IF id \in Txns THEN txnPermutation[id]
          ELSE batchPermutation[id]] :
        txnPermutation \in Permutations(Txns),
        batchPermutation \in Permutations(BatchIDs)}
ASSUME /\ Cardinality(Txns \cup BatchIDs \cup
              {NoBatch, NoAuthority, DB, OtherDB}) = 10
       /\ Width \in 1..Cardinality(Txns)
       /\ Depth \in Width..Cardinality(Txns)

AsSet(q) == {q[i] : i \in 1..Len(q)}
Without(q, t) == SelectSeq(q, LAMBDA u : u # t)
Position(q, t) == CHOOSE i \in 1..Len(q) : q[i] = t
EmptyImage == [members |-> <<>>, payload |-> [t \in {} |-> t],
               previous |-> NoBatch, first |-> 0, last |-> 0,
               expected |-> 0, publication |-> 0]
TxnStates == {"Idle", "Admitted", "Rejected", "Cancelled", "Unsupported",
              "Frozen", "Unknown", "Committed", "Failed", "Lost"}
ReceiptStates == {"None", "Rejected", "Unknown", "Committed", "Failed"}
Phases == {"Idle", "Frozen", "BatchUnknown", "BatchFailed", "Ready",
           "Accepted", "Unknown"}
ActionNames == {"Init", "SupplyAggregateID", "AdmitSingleton",
    "RejectBeforeAdmission", "RequestAdmittedCancellation",
    "RejectQueuedConflict", "FreezeCohort",
    "PublishAggregate", "ConfirmAggregate", "FailFrozenCohort",
    "RivalHead", "PublishHead", "ObserveSuccess", "RejectHead",
    "ResolveMember", "ResolveRejected", "RetainUnknown", "ExportAuthority",
    "ImportAuthority", "RejectMalformedAuthority", "RejectInexactResolution",
    "Crash", "ReopenFromHead", "Close", "ProbeConfirmedOrphanCollision",
    "ObserveMissingIdentityBoundary", "UnsafePartialVisibility",
    "UnsafeReplay", "UnsafeMemberOnlyResolve", "UnsafeCancelAdmitted", "UnsafeResupply",
    "UnsafeOrphanOverwrite"}

VARIABLE s
vars == <<s>>

Members(b) == IF b = NoBatch THEN {} ELSE AsSet(s.images[b].members)
ActiveMembers == Members(s.active)
Pending == AsSet(s.queue)

RECURSIVE Chain(_, _)
Chain(b, remaining) ==
    IF b = NoBatch \/ remaining = 0
    THEN <<>>
    ELSE Append(Chain(s.images[b].previous, remaining - 1), b)

HeadChain == Chain(s.headBatch, Cardinality(BatchIDs))
HeadBatches == AsSet(HeadChain)
HeadMembers == UNION {Members(b) : b \in HeadBatches}

Authority(t, b) ==
    [profile |-> "Aggregate", database |-> DB, member |-> t, batch |-> b,
     sequence |-> s.memberSequence[t], image |-> s.images[b]]

ImageValid(image) ==
    /\ image.members \in Seq(Txns)
    /\ Len(image.members) \in 1..Cardinality(Txns)
    /\ Cardinality(AsSet(image.members)) = Len(image.members)
    /\ image.payload \in [AsSet(image.members) -> Txns]
    /\ image.previous \in BatchIDs \cup {NoBatch}
    /\ image.first \in 1..Cardinality(Txns)
    /\ image.last = image.first + Len(image.members) - 1
    /\ image.last <= Cardinality(Txns)
    /\ (image.previous = NoBatch) = (image.first = 1)
    /\ image.expected \in 0..Cardinality(BatchIDs)
    /\ image.publication = image.expected + 1

StructuralAuthority(t, a) ==
    IF a = NoAuthority THEN FALSE
    ELSE /\ a.profile = "Aggregate"
         /\ a.database = DB
         /\ a.member = t
         /\ a.batch \in BatchIDs
         /\ ImageValid(a.image)
         /\ t \in AsSet(a.image.members)
         /\ a.batch # a.image.previous
         /\ a.sequence = a.image.first + Position(a.image.members, t) - 1

ExactAuthority(t, a) ==
    IF ~StructuralAuthority(t, a) THEN FALSE
    ELSE /\ a.batch \in s.stored
         /\ a.image = s.images[a.batch]
         /\ a.sequence = s.memberSequence[t]
         /\ s.memberBatch[t] = a.batch

Init ==
    s = [txn |-> [t \in Txns |-> "Idle"], queue |-> <<>>,
         usedTxns |-> {}, usedBatches |-> {}, localBatchIDs |-> {},
         offered |-> NoBatch, active |-> NoBatch, phase |-> "Idle",
         images |-> [b \in BatchIDs |-> EmptyImage], stored |-> {},
         memberBatch |-> [t \in Txns |-> NoBatch],
         memberSequence |-> [t \in Txns |-> 0],
         headBatch |-> NoBatch, highest |-> 0, generation |-> 0,
         published |-> {}, visible |-> {}, acknowledged |-> {}, excluded |-> {},
         receipt |-> [t \in Txns |-> "None"],
         liveAuthority |-> [t \in Txns |-> NoAuthority],
         durableAuthority |-> [t \in Txns |-> NoAuthority],
         batchPuts |-> [b \in BatchIDs |-> 0],
         headPuts |-> [b \in BatchIDs |-> 0], resolutionWrites |-> 0,
         recovered |-> {}, online |-> TRUE, crashed |-> FALSE,
         reopened |-> FALSE, fenced |-> FALSE, rivalObserved |-> FALSE,
         orphanProbed |-> {}, orphanRejected |-> {}, missingBoundary |-> {},
         deadlineRejected |-> {}, malformedRejected |-> FALSE,
         inexactResolutionRejected |-> FALSE, lastAction |-> "Init"]

SupplyAggregateID(b) ==
    /\ s.online /\ ~s.fenced
    /\ s.offered = NoBatch
    /\ b \notin s.localBatchIDs
    \* This is the caller's never-reuse obligation, not a runtime disk read.
    /\ b \notin s.usedBatches
    /\ s' = [s EXCEPT !.offered = b, !.lastAction = "SupplyAggregateID"]

AdmitSingleton(t) ==
    /\ s.online /\ ~s.fenced /\ s.phase # "Unknown"
    /\ s.txn[t] = "Idle" /\ t \notin s.usedTxns
    /\ Len(s.queue) + Cardinality(ActiveMembers) < Depth
    /\ s' = [s EXCEPT !.txn[t] = "Admitted", !.queue = Append(@, t),
                !.usedTxns = @ \cup {t}, !.lastAction = "AdmitSingleton"]

RejectBeforeAdmission(t, reason) ==
    /\ s.online /\ s.txn[t] = "Idle"
    /\ reason \in {"Rejected", "Cancelled", "Unsupported"}
    /\ s' = [s EXCEPT !.txn[t] = reason,
                !.excluded = @ \cup {t},
                !.deadlineRejected = IF reason = "Unsupported"
                                     THEN @ \cup {t} ELSE @,
                !.lastAction = "RejectBeforeAdmission"]

RequestAdmittedCancellation(t) ==
    /\ s.online
    /\ t \in Pending \cup ActiveMembers
    \* Cancellation after admission is a drain request. It cannot withdraw a
    \* member, alter its identity, or select its eventual publication result.
    /\ s' = [s EXCEPT !.lastAction = "RequestAdmittedCancellation"]

RejectQueuedConflict(t) ==
    /\ s.online /\ t \in Pending
    \* Abstract the latest-history/intra-cohort predicate, before freeze.
    /\ s' = [s EXCEPT !.txn[t] = "Rejected", !.receipt[t] = "Rejected",
                !.queue = Without(@, t), !.excluded = @ \cup {t},
                !.lastAction = "RejectQueuedConflict"]

FreezeCohort ==
    /\ s.online /\ ~s.fenced /\ s.phase = "Idle"
    /\ s.offered # NoBatch /\ Len(s.queue) >= Width
    /\ LET q == SubSeq(s.queue, 1, Width)
           group == AsSet(q)
           b == s.offered
       IN s' = [s EXCEPT
          !.queue = SubSeq(@, Width + 1, Len(@)),
          !.active = b, !.offered = NoBatch, !.phase = "Frozen",
          !.usedBatches = @ \cup {b}, !.localBatchIDs = @ \cup {b},
          !.images[b] = [members |-> q, payload |-> [t \in group |-> t],
              previous |-> s.headBatch, first |-> s.highest + 1,
              last |-> s.highest + Width, expected |-> s.generation,
              publication |-> s.generation + 1],
          !.txn = [t \in Txns |-> IF t \in group THEN "Frozen" ELSE @[t]],
          !.memberBatch = [t \in Txns |-> IF t \in group THEN b ELSE @[t]],
          !.memberSequence = [t \in Txns |-> IF t \in group
              THEN s.highest + Position(q, t) ELSE @[t]],
          !.lastAction = "FreezeCohort"]

PublishAggregate(outcome) ==
    /\ s.online /\ s.phase = "Frozen"
    /\ s.batchPuts[s.active] = 0
    /\ outcome \in {"Confirmed", "UnknownStored", "UnknownAbsent", "Failed"}
    /\ s' = [s EXCEPT !.batchPuts[s.active] = 1,
          !.stored = IF outcome \in {"Confirmed", "UnknownStored"}
                     THEN @ \cup {s.active} ELSE @,
          !.phase = CASE outcome = "Confirmed" -> "Ready"
                     [] outcome = "Failed" -> "BatchFailed"
                     [] OTHER -> "BatchUnknown",
          !.lastAction = "PublishAggregate"]

ConfirmAggregate ==
    /\ s.online /\ s.phase = "BatchUnknown"
    \* One exact immutable-object read; there is no second Put.
    /\ s' = [s EXCEPT !.phase = IF s.active \in s.stored
                               THEN "Ready" ELSE "BatchFailed",
                !.lastAction = "ConfirmAggregate"]

FailFrozenCohort ==
    /\ s.online /\ s.phase \in {"Frozen", "BatchFailed", "Ready"}
    \* Includes failure after a confirmed aggregate but before HEAD entry.
    /\ s' = [s EXCEPT
          !.txn = [t \in Txns |-> IF t \in ActiveMembers THEN "Failed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in ActiveMembers THEN "Failed" ELSE @[t]],
          !.excluded = @ \cup ActiveMembers,
          !.active = NoBatch, !.phase = "Idle", !.lastAction = "FailFrozenCohort"]

RivalHead ==
    /\ s.online /\ ~s.rivalObserved
    /\ s.phase \in {"Ready", "Unknown"}
    /\ s.active \notin HeadBatches
    \* A competing metadata transition is enough to defeat exact-generation
    \* CAS without changing the represented transaction history.
    /\ s' = [s EXCEPT !.generation = @ + 1, !.rivalObserved = TRUE,
                !.lastAction = "RivalHead"]

PublishHead(outcome) ==
    /\ s.online /\ s.phase = "Ready"
    /\ s.active \in s.stored /\ s.headPuts[s.active] = 0
    /\ s.generation = s.images[s.active].expected
    /\ outcome \in {"Accepted", "UnknownAccepted", "UnknownNotEntered"}
    /\ LET entered == outcome # "UnknownNotEntered"
       IN s' = [s EXCEPT !.headPuts[s.active] = 1,
          !.headBatch = IF entered THEN s.active ELSE @,
          !.highest = IF entered THEN s.images[s.active].last ELSE @,
          !.generation = IF entered THEN @ + 1 ELSE @,
          !.published = IF entered THEN @ \cup {s.active} ELSE @,
          !.visible = IF entered THEN @ \cup ActiveMembers ELSE @,
          !.phase = IF outcome = "Accepted" THEN "Accepted" ELSE "Unknown",
          !.txn = [t \in Txns |-> IF t \in ActiveMembers /\ outcome # "Accepted"
                                  THEN "Unknown" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in ActiveMembers /\ outcome # "Accepted"
                                      THEN "Unknown" ELSE @[t]],
          !.liveAuthority = [t \in Txns |-> IF t \in ActiveMembers /\ outcome # "Accepted"
                              THEN Authority(t, s.active) ELSE @[t]],
          !.lastAction = "PublishHead"]

ObserveSuccess ==
    /\ s.online /\ s.phase = "Accepted"
    /\ s' = [s EXCEPT
          !.txn = [t \in Txns |-> IF t \in ActiveMembers THEN "Committed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in ActiveMembers THEN "Committed" ELSE @[t]],
          !.acknowledged = @ \cup ActiveMembers,
          !.active = NoBatch, !.phase = "Idle", !.lastAction = "ObserveSuccess"]

RejectHead ==
    /\ s.online /\ s.phase = "Ready"
    /\ s.generation # s.images[s.active].expected
    /\ s.headPuts[s.active] = 0
    /\ s' = [s EXCEPT !.headPuts[s.active] = 1,
          !.txn = [t \in Txns |-> IF t \in ActiveMembers \cup Pending
                                  THEN "Failed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in ActiveMembers \cup Pending
                                      THEN "Failed" ELSE @[t]],
          !.excluded = @ \cup ActiveMembers \cup Pending,
          !.queue = <<>>, !.active = NoBatch, !.offered = NoBatch,
          !.phase = "Idle", !.fenced = TRUE, !.lastAction = "RejectHead"]

ResolveMember(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown"
    /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s.active \in {NoBatch, s.liveAuthority[t].batch}
    /\ s.liveAuthority[t].batch \in HeadBatches
    /\ s' = [s EXCEPT !.txn[t] = "Committed", !.receipt[t] = "Committed",
          !.acknowledged = @ \cup {t},
          !.active = IF s.active = s.liveAuthority[t].batch THEN NoBatch ELSE @,
          !.phase = IF s.active = s.liveAuthority[t].batch THEN "Idle" ELSE @,
          !.lastAction = "ResolveMember"]

ResolveRejected(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown"
    /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s.active \in {NoBatch, s.liveAuthority[t].batch}
    /\ s.liveAuthority[t].batch \notin HeadBatches
    /\ s.generation >= s.liveAuthority[t].image.publication
    /\ s' = [s EXCEPT !.txn = [u \in Txns |-> IF u = t \/ u \in Pending
                                                    THEN "Failed" ELSE @[u]],
          !.receipt = [u \in Txns |-> IF u = t \/ u \in Pending
                                      THEN "Failed" ELSE @[u]],
          !.excluded = @ \cup {t} \cup Pending, !.queue = <<>>,
          !.active = NoBatch, !.offered = NoBatch, !.phase = "Idle",
          !.fenced = TRUE, !.lastAction = "ResolveRejected"]

RetainUnknown(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown"
    /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s.liveAuthority[t].batch \notin HeadBatches
    /\ s.generation < s.liveAuthority[t].image.publication
    /\ s' = [s EXCEPT !.lastAction = "RetainUnknown"]

ExportAuthority(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown"
    /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s.durableAuthority[t] = NoAuthority
    /\ s' = [s EXCEPT !.durableAuthority[t] = s.liveAuthority[t],
                !.lastAction = "ExportAuthority"]

AuthorityInputs(t) ==
    IF s.durableAuthority[t] = NoAuthority THEN {}
    ELSE LET a == s.durableAuthority[t]
             siblings == {u \in AsSet(a.image.members) \ {t} :
                              a.image.payload[u] # t}
         IN {a, [a EXCEPT !.database = OtherDB],
                [a EXCEPT !.profile = "OtherProfile"]}
            \cup {[a EXCEPT !.member = u] :
                      u \in Txns \ {a.member}}
            \cup {[a EXCEPT !.image.payload[t] = u] :
                      u \in Txns \ {a.image.payload[t]}}
            \cup {[a EXCEPT !.image.payload[u] = t] :
                      u \in siblings}

ImportAuthority(t) ==
    /\ s.online /\ s.receipt[t] = "None"
    /\ \E a \in AuthorityInputs(t) :
        /\ StructuralAuthority(t, a)
        \* Deliberately local/structural. Full immutable equality is checked by
        \* Resolve, so a structurally valid altered payload may reach this state.
        /\ s' = [s EXCEPT !.receipt[t] = "Unknown", !.txn[t] = "Unknown",
                    !.liveAuthority[t] = a, !.lastAction = "ImportAuthority"]

RejectMalformedAuthority(t) ==
    /\ s.online /\ s.receipt[t] = "None"
    /\ \E a \in AuthorityInputs(t) :
        /\ ~StructuralAuthority(t, a)
        /\ s' = [s EXCEPT !.malformedRejected = TRUE,
                    !.lastAction = "RejectMalformedAuthority"]

RejectInexactResolution(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown"
    /\ StructuralAuthority(t, s.liveAuthority[t])
    /\ ~ExactAuthority(t, s.liveAuthority[t])
    /\ s' = [s EXCEPT !.inexactResolutionRejected = TRUE,
                !.lastAction = "RejectInexactResolution"]

Crash ==
    /\ s.online /\ ~s.crashed
    /\ s' = [s EXCEPT !.online = FALSE, !.crashed = TRUE,
          !.txn = [t \in Txns |-> IF t \in s.usedTxns THEN "Lost" ELSE @[t]],
          !.queue = <<>>, !.active = NoBatch, !.offered = NoBatch, !.phase = "Idle",
          !.localBatchIDs = {}, !.recovered = {},
          !.receipt = [t \in Txns |-> "None"],
          !.liveAuthority = [t \in Txns |-> NoAuthority], !.lastAction = "Crash"]

ReopenFromHead ==
    /\ ~s.online /\ s.crashed /\ ~s.reopened
    /\ HeadBatches \subseteq s.stored
    /\ s' = [s EXCEPT !.online = TRUE, !.reopened = TRUE, !.fenced = FALSE,
          !.localBatchIDs = HeadBatches, !.recovered = HeadMembers,
          !.lastAction = "ReopenFromHead"]

Close ==
    /\ s.online /\ s.phase = "Idle"
    /\ s' = [s EXCEPT !.online = FALSE,
          !.txn = [t \in Txns |-> IF t \in Pending THEN "Failed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in Pending THEN "Failed" ELSE @[t]],
          !.excluded = @ \cup Pending, !.queue = <<>>, !.offered = NoBatch,
          !.lastAction = "Close"]

ProbeConfirmedOrphanCollision(b) ==
    /\ s.online /\ s.reopened /\ s.phase = "Idle"
    /\ b \in s.stored \ HeadBatches
    /\ b \notin s.localBatchIDs \cup s.orphanProbed
    \* An explicit out-of-contract repeated identity encounters the existing
    \* immutable key. Conditional create cannot overwrite even exact bytes.
    /\ s' = [s EXCEPT !.orphanProbed = @ \cup {b},
          !.orphanRejected = @ \cup {b}, !.fenced = TRUE, !.offered = NoBatch,
          !.txn = [t \in Txns |-> IF t \in Pending THEN "Failed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in Pending THEN "Failed" ELSE @[t]],
          !.excluded = @ \cup Pending, !.queue = <<>>,
          !.lastAction = "ProbeConfirmedOrphanCollision"]

ObserveMissingIdentityBoundary(b) ==
    /\ s.online /\ s.reopened
    /\ b \in s.usedBatches \ s.stored
    /\ b \notin s.localBatchIDs \cup s.missingBoundary
    \* No object or HEAD history can distinguish this from a fresh ID. The
    \* compliant Supply action excludes it ONLY through the caller contract.
    /\ s' = [s EXCEPT !.missingBoundary = @ \cup {b},
                !.lastAction = "ObserveMissingIdentityBoundary"]

Next ==
    \/ \E b \in BatchIDs : SupplyAggregateID(b)
    \/ \E t \in Txns : AdmitSingleton(t)
    \/ \E t \in Txns, reason \in {"Rejected", "Cancelled", "Unsupported"} :
           RejectBeforeAdmission(t, reason)
    \/ \E t \in Txns : RequestAdmittedCancellation(t)
    \/ \E t \in Txns : RejectQueuedConflict(t)
    \/ FreezeCohort
    \/ \E outcome \in {"Confirmed", "UnknownStored", "UnknownAbsent", "Failed"} :
           PublishAggregate(outcome)
    \/ ConfirmAggregate \/ FailFrozenCohort \/ RivalHead
    \/ \E outcome \in {"Accepted", "UnknownAccepted", "UnknownNotEntered"} :
           PublishHead(outcome)
    \/ ObserveSuccess \/ RejectHead
    \/ \E t \in Txns : ResolveMember(t) \/ ResolveRejected(t) \/ RetainUnknown(t)
    \/ \E t \in Txns : ExportAuthority(t)
    \/ \E t \in Txns : ImportAuthority(t)
    \/ \E t \in Txns : RejectMalformedAuthority(t)
    \/ \E t \in Txns : RejectInexactResolution(t)
    \/ Crash \/ ReopenFromHead \/ Close
    \/ \E b \in BatchIDs : ProbeConfirmedOrphanCollision(b)
    \/ \E b \in BatchIDs : ObserveMissingIdentityBoundary(b)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ s.txn \in [Txns -> TxnStates]
    /\ s.queue \in Seq(Txns) /\ Len(s.queue) <= Depth
    /\ Cardinality(Pending) = Len(s.queue)
    /\ s.usedTxns \subseteq Txns /\ s.usedBatches \subseteq BatchIDs
    /\ s.localBatchIDs \subseteq s.usedBatches
    /\ s.offered \in BatchIDs \cup {NoBatch}
    /\ s.active \in BatchIDs \cup {NoBatch} /\ s.phase \in Phases
    /\ DOMAIN s.images = BatchIDs
    /\ \A b \in BatchIDs : s.images[b] = EmptyImage \/ ImageValid(s.images[b])
    /\ s.stored \subseteq BatchIDs /\ s.published \subseteq BatchIDs
    /\ s.memberBatch \in [Txns -> BatchIDs \cup {NoBatch}]
    /\ s.memberSequence \in [Txns -> 0..Cardinality(Txns)]
    /\ s.headBatch \in BatchIDs \cup {NoBatch}
    /\ s.highest \in 0..Cardinality(Txns)
    /\ s.generation \in 0..(Cardinality(BatchIDs) + 1)
    /\ s.visible \subseteq Txns /\ s.acknowledged \subseteq Txns
    /\ s.excluded \subseteq Txns /\ s.recovered \subseteq Txns
    /\ s.receipt \in [Txns -> ReceiptStates]
    /\ DOMAIN s.liveAuthority = Txns /\ DOMAIN s.durableAuthority = Txns
    /\ s.batchPuts \in [BatchIDs -> 0..2] /\ s.headPuts \in [BatchIDs -> 0..1]
    /\ s.resolutionWrites \in Nat
    /\ s.online \in BOOLEAN /\ s.crashed \in BOOLEAN /\ s.reopened \in BOOLEAN
    /\ s.fenced \in BOOLEAN /\ s.rivalObserved \in BOOLEAN
    /\ s.orphanProbed \subseteq BatchIDs /\ s.orphanRejected \subseteq BatchIDs
    /\ s.missingBoundary \subseteq BatchIDs /\ s.deadlineRejected \subseteq Txns
    /\ s.malformedRejected \in BOOLEAN /\ s.inexactResolutionRejected \in BOOLEAN
    /\ s.lastAction \in ActionNames

CallerIdentityContract ==
    /\ s.offered # NoBatch => s.offered \notin s.usedBatches
    /\ \A left, right \in s.usedBatches :
           left # right => Members(left) \intersect Members(right) = {}
    /\ \A t \in Txns : s.memberBatch[t] # NoBatch =>
           /\ t \in Members(s.memberBatch[t])
           /\ s.memberSequence[t] = s.images[s.memberBatch[t]].first
                + Position(s.images[s.memberBatch[t]].members, t) - 1

WholeCohortVisibility ==
    /\ s.visible = HeadMembers
    /\ s.published = HeadBatches
    /\ \A b \in s.usedBatches :
           Members(b) \intersect s.visible = {} \/ Members(b) \subseteq s.visible

StoredBeforeVisibility == HeadBatches \subseteq s.stored
NoEarlyAcknowledgement ==
    /\ s.acknowledged \subseteq s.visible
    /\ \A t \in Txns : s.receipt[t] = "Committed" => t \in s.visible
PreFreezeExclusion == s.excluded \intersect (Pending \cup ActiveMembers \cup s.visible) = {}
FiniteDeadlineExclusion == s.deadlineRejected \intersect s.usedTxns = {}
AdmittedCancellationDoesNotClassify ==
    \A t \in s.usedTxns : s.txn[t] # "Cancelled"
OnePutAndHeadPerAggregate ==
    /\ \A b \in BatchIDs : s.batchPuts[b] <= 1 /\ s.headPuts[b] <= s.batchPuts[b]
    /\ \A b \in s.published : s.batchPuts[b] = 1 /\ s.headPuts[b] = 1
ResolutionDoesNotReplay == s.resolutionWrites = 0
FencingStopsAdmission == s.fenced => s.queue = <<>> /\ s.active = NoBatch
IndependentAdmissionAndFreeze ==
    /\ Len(s.queue) + Cardinality(ActiveMembers) <= Depth
    /\ Pending = {t \in Txns : s.txn[t] = "Admitted"}
    /\ s.phase = "Idle" <=> s.active = NoBatch
    /\ ActiveMembers \intersect Pending = {}
    /\ s.active # NoBatch => Cardinality(ActiveMembers) = Width
HeadChainIsExact ==
    /\ Cardinality(HeadBatches) = Len(HeadChain)
    /\ (s.headBatch = NoBatch) = (s.highest = 0)
    /\ s.highest = Cardinality(s.visible)
    /\ s.headBatch # NoBatch => s.images[s.headBatch].last = s.highest
    /\ \A i \in 1..Len(HeadChain) :
           /\ s.images[HeadChain[i]].previous = IF i = 1 THEN NoBatch ELSE HeadChain[i - 1]
           /\ s.images[HeadChain[i]].first = IF i = 1 THEN 1 ELSE s.images[HeadChain[i - 1]].last + 1
           /\ s.images[HeadChain[i]].publication <= s.generation
FullCohortAuthority ==
    \A t \in Txns : s.durableAuthority[t] # NoAuthority =>
        ExactAuthority(t, s.durableAuthority[t])
ResolvedAuthorityIsExact ==
    \A t \in Txns : s.receipt[t] = "Committed" /\ s.liveAuthority[t] # NoAuthority =>
        ExactAuthority(t, s.liveAuthority[t])
RecoveryUsesHeadOnly ==
    /\ s.recovered \subseteq HeadMembers
    /\ s.lastAction = "ReopenFromHead" =>
           s.recovered = HeadMembers /\ s.localBatchIDs = HeadBatches
ConfirmedOrphanBarrier == s.orphanProbed = s.orphanRejected
MissingIdentityIsCallerBoundary == s.missingBoundary \subseteq s.usedBatches \ s.stored

Safety ==
    /\ TypeOK /\ CallerIdentityContract /\ WholeCohortVisibility
    /\ StoredBeforeVisibility /\ NoEarlyAcknowledgement /\ PreFreezeExclusion
    /\ FiniteDeadlineExclusion /\ AdmittedCancellationDoesNotClassify
    /\ OnePutAndHeadPerAggregate /\ ResolutionDoesNotReplay
    /\ FencingStopsAdmission /\ IndependentAdmissionAndFreeze /\ HeadChainIsExact
    /\ FullCohortAuthority /\ ResolvedAuthorityIsExact /\ RecoveryUsesHeadOnly
    /\ ConfirmedOrphanBarrier /\ MissingIdentityIsCallerBoundary

Trace == [action |-> s.lastAction, phase |-> s.phase, queue |-> s.queue,
          active |-> s.active, head |-> s.headBatch, sequence |-> s.highest,
          visible |-> s.visible, receipt |-> s.receipt,
          batchPuts |-> s.batchPuts, headPuts |-> s.headPuts,
          resolutionWrites |-> s.resolutionWrites, recovered |-> s.recovered,
          fenced |-> s.fenced]

=============================================================================
