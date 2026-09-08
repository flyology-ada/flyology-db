---------------- MODULE AdaptiveAggregateCommitCoalescing ----------------
EXTENDS FiniteSets, Naturals, Sequences, TLC

(***************************************************************************
Private adaptive-cohort publication model. Independently admitted logical
transactions share one immutable aggregate and one conditional HEAD update.
The oldest member's never-reused transaction ID is the physical batch ID.

MaxWidth, MaxBytes, MaxWait, Depth, and PayloadBytes are qualification
geometry, not product defaults. Admission is the ownership cut. Cancellation
after admission is a drain request. Queued expiry can remove one member before
freeze. Freeze fixes membership and sequences. Once HEAD might have entered,
the complete cohort is either visible or unknown; it never splits.
Close drains a conclusive tail, but never publishes it above an unknown cohort:
unfrozen members fail while the unknown authorities survive reopen.

The model abstracts exact bytes, CRCs, allocation, provider implementation,
and wall-clock units. Conditional object creation and authoritative HEAD reads
are trusted storage boundaries. DurableAuthority represents the complete
aggregate image, not a member-only payload. No runtime policy is selected by
this finite instance.
***************************************************************************)

CONSTANTS T1, T2, T3, NoTxn, NoAuthority, DB, OtherDB,
          MaxWidth, MaxBytes, MaxWait, Depth, PayloadBytes

Txns == {T1, T2, T3}
PayloadBytesModel ==
    [t \in Txns |-> CASE t = T1 -> 1 [] t = T2 -> 2 [] OTHER -> 1]

OversizedPayloadBytesModel ==
    [t \in Txns |-> CASE t = T2 -> MaxBytes + 1 [] OTHER -> 1]

ASSUME /\ Cardinality(Txns \cup {NoTxn, NoAuthority, DB, OtherDB}) = 7
       /\ MaxWidth \in 1..Cardinality(Txns)
       /\ Depth \in MaxWidth..Cardinality(Txns)
       /\ MaxBytes \in Nat \ {0}
       /\ MaxWait \in Nat \ {0}
       /\ PayloadBytes \in [Txns -> Nat \ {0}]

MinNat(left, right) == IF left <= right THEN left ELSE right
AsSet(q) == {q[i] : i \in 1..Len(q)}
Without(q, t) == SelectSeq(q, LAMBDA u : u # t)
Position(q, t) == CHOOSE i \in 1..Len(q) : q[i] = t

RECURSIVE PrefixBytes(_, _)
PrefixBytes(q, count) ==
    IF count = 0
    THEN 0
    ELSE PrefixBytes(q, count - 1) + PayloadBytes[q[count]]

EligibleCounts(q) ==
    {count \in 1..MinNat(MaxWidth, Len(q)) :
        count = 1 \/ PrefixBytes(q, count) <= MaxBytes}

SelectedCount(q) ==
    CHOOSE count \in EligibleCounts(q) :
        \A other \in EligibleCounts(q) : other <= count

EmptyImage ==
    [members |-> <<>>, previous |-> NoTxn, first |-> 0, last |-> 0,
     expected |-> 0, publication |-> 0, bytes |-> 0]

TxnStates == {"Idle", "Queued", "TimedOut", "Rejected", "Frozen",
              "Unknown", "Committed", "Failed", "Lost"}
ReceiptStates == {"None", "TimedOut", "Rejected", "Unknown", "Committed", "Failed"}
Phases == {"Idle", "Frozen", "BatchUnknown", "BatchFailed", "Ready",
           "HeadAttempted", "Accepted", "Unknown"}
ActionNames == {"Init", "Admit", "CancelBeforeAdmission", "RequestCancellation",
    "ReachDeadline", "ExpireQueued", "Tick", "RejectQueuedConflict", "BeginClose",
    "FreezeCohort", "PublishAggregate", "ConfirmAggregate", "ObserveBatchFailure",
    "BeginHeadAttempt", "RivalHead", "HeadAccepted", "HeadResponseLost",
    "HeadPreconditionRejected", "ObserveSuccess", "ObserveLocalInstallFailure",
    "ResolveMember", "ResolveRejected",
    "RetainUnknown", "ExportAuthority", "ImportAuthority", "RejectMalformedAuthority",
    "Crash", "ReopenFromHead", "CloseWithUnknown", "Close",
    "UnsafePartialVisibility", "UnsafeReplay",
    "UnsafeCancelFrozen", "UnsafeSplitOutcome", "UnsafeAliasNonOldest",
    "UnsafeMemberOnlyResolve", "UnsafeDropUnknownAuthority",
    "UnsafeConsumeCancelledIdentity",
    "UnsafeSequenceGap", "UnsafeTimeoutWithoutDeadline"}

VARIABLE s
vars == <<s>>

Members(batch) == IF batch = NoTxn THEN {} ELSE AsSet(s.images[batch].members)
ActiveMembers == Members(s.active)
Pending == AsSet(s.queue)

RECURSIVE Chain(_, _)
Chain(batch, remaining) ==
    IF batch = NoTxn \/ remaining = 0
    THEN <<>>
    ELSE Append(Chain(s.images[batch].previous, remaining - 1), batch)

HeadChain == Chain(s.headBatch, Cardinality(Txns))
HeadBatches == AsSet(HeadChain)
HeadMembers == UNION {Members(batch) : batch \in HeadBatches}

ImageValid(batch, image) ==
    /\ batch \in Txns
    /\ image.members \in Seq(Txns)
    /\ Len(image.members) \in 1..MaxWidth
    /\ Cardinality(AsSet(image.members)) = Len(image.members)
    /\ image.members[1] = batch
    /\ image.previous \in Txns \cup {NoTxn}
    /\ image.previous # batch
    /\ image.first \in 1..Cardinality(Txns)
    /\ image.last = image.first + Len(image.members) - 1
    /\ image.last <= Cardinality(Txns)
    /\ (image.previous = NoTxn) = (image.first = 1)
    /\ image.expected \in 0..Cardinality(Txns)
    /\ image.publication = image.expected + 1
    /\ image.bytes = PrefixBytes(image.members, Len(image.members))
    /\ image.bytes >= 1
    /\ Len(image.members) = 1 \/ image.bytes <= MaxBytes

Authority(member, batch) ==
    [profile |-> "AdaptiveAggregate", database |-> DB, member |-> member,
     batch |-> batch, sequence |-> s.memberSequence[member], image |-> s.images[batch]]

StructuralAuthority(member, authority) ==
    IF authority = NoAuthority
    THEN FALSE
    ELSE /\ authority.profile = "AdaptiveAggregate"
         /\ authority.database = DB
         /\ authority.member = member
         /\ authority.batch \in Txns
         /\ ImageValid(authority.batch, authority.image)
         /\ member \in AsSet(authority.image.members)
         /\ authority.sequence = authority.image.first
              + Position(authority.image.members, member) - 1

ExactAuthority(member, authority) ==
    IF ~StructuralAuthority(member, authority)
    THEN FALSE
    ELSE /\ authority.batch \in s.stored
         /\ authority.image = s.images[authority.batch]

Init ==
    s = [txn |-> [t \in Txns |-> "Idle"], queue |-> <<>>,
         age |-> [t \in Txns |-> 0], usedTxns |-> {}, usedBatches |-> {},
         active |-> NoTxn, phase |-> "Idle",
         images |-> [t \in Txns |-> EmptyImage], stored |-> {},
         memberBatch |-> [t \in Txns |-> NoTxn],
         memberSequence |-> [t \in Txns |-> 0],
         headBatch |-> NoTxn, highest |-> 0, generation |-> 0,
         published |-> {}, visible |-> {}, acknowledged |-> {}, excluded |-> {},
         receipt |-> [t \in Txns |-> "None"],
         liveAuthority |-> [t \in Txns |-> NoAuthority],
         durableAuthority |-> [t \in Txns |-> NoAuthority],
         batchPuts |-> [t \in Txns |-> 0], headPuts |-> [t \in Txns |-> 0],
         resolutionWrites |-> 0, cancelRequested |-> {}, deadlineReached |-> {},
         deadlineExpired |-> {},
         headMayHaveEntered |-> FALSE, draining |-> FALSE,
         online |-> TRUE, crashed |-> FALSE, reopened |-> FALSE,
         fenced |-> FALSE, rivalObserved |-> FALSE, recovered |-> {},
         closedHead |-> NoTxn, closedUnknown |-> NoTxn, closedPending |-> {},
         malformedRejected |-> FALSE, lastAction |-> "Init"]

Admit(t) ==
    /\ s.online /\ ~s.fenced /\ ~s.draining /\ s.phase # "Unknown"
    /\ s.txn[t] = "Idle" /\ t \notin s.usedTxns
    /\ Len(s.queue) + Cardinality(ActiveMembers) < Depth
    /\ s' = [s EXCEPT !.txn[t] = "Queued", !.queue = Append(@, t),
                !.age[t] = 0, !.usedTxns = @ \cup {t}, !.lastAction = "Admit"]

CancelBeforeAdmission(t) ==
    /\ s.online /\ s.txn[t] = "Idle" /\ t \notin s.usedTxns
    /\ s' = [s EXCEPT !.lastAction = "CancelBeforeAdmission"]

RequestCancellation(t) ==
    /\ s.online /\ t \in Pending \cup ActiveMembers
    /\ s' = [s EXCEPT !.cancelRequested = @ \cup {t},
                !.lastAction = "RequestCancellation"]

ReachDeadline(t) ==
    /\ s.online /\ t \in Pending \cup ActiveMembers
    /\ s' = [s EXCEPT !.deadlineReached = @ \cup {t},
                !.lastAction = "ReachDeadline"]

ExpireQueued(t) ==
    /\ s.online /\ t \in Pending /\ t \in s.deadlineReached
    /\ s' = [s EXCEPT !.txn[t] = "TimedOut", !.receipt[t] = "TimedOut",
                !.queue = Without(@, t), !.deadlineExpired = @ \cup {t},
                !.excluded = @ \cup {t}, !.lastAction = "ExpireQueued"]

Tick ==
    /\ s.online /\ s.queue # <<>>
    /\ \E t \in Pending : s.age[t] < MaxWait
    /\ s' = [s EXCEPT
          !.age = [t \in Txns |->
              IF t \in Pending THEN MinNat(MaxWait, @[t] + 1) ELSE @[t]],
          !.lastAction = "Tick"]

RejectQueuedConflict(t) ==
    /\ s.online /\ t \in Pending
    /\ s' = [s EXCEPT !.txn[t] = "Rejected", !.receipt[t] = "Rejected",
                !.queue = Without(@, t), !.excluded = @ \cup {t},
                !.lastAction = "RejectQueuedConflict"]

BeginClose ==
    /\ s.online /\ ~s.draining
    /\ s' = [s EXCEPT !.draining = TRUE, !.lastAction = "BeginClose"]

FreezeEligible ==
    /\ s.online /\ ~s.fenced /\ s.phase = "Idle" /\ s.queue # <<>>
    /\ \/ Len(s.queue) >= MaxWidth
       \/ s.age[s.queue[1]] = MaxWait
       \/ PrefixBytes(s.queue, SelectedCount(s.queue)) >= MaxBytes
       \/ SelectedCount(s.queue) < Len(s.queue)
       \/ s.draining

FreezeCohort ==
    /\ FreezeEligible
    /\ LET count == SelectedCount(s.queue)
           members == SubSeq(s.queue, 1, count)
           group == AsSet(members)
           batch == members[1]
       IN s' = [s EXCEPT
          !.queue = SubSeq(@, count + 1, Len(@)),
          !.active = batch, !.phase = "Frozen", !.usedBatches = @ \cup {batch},
          !.images[batch] =
              [members |-> members, previous |-> s.headBatch,
               first |-> s.highest + 1, last |-> s.highest + count,
               expected |-> s.generation, publication |-> s.generation + 1,
               bytes |-> PrefixBytes(members, count)],
          !.txn = [t \in Txns |-> IF t \in group THEN "Frozen" ELSE @[t]],
          !.memberBatch = [t \in Txns |-> IF t \in group THEN batch ELSE @[t]],
          !.memberSequence = [t \in Txns |->
              IF t \in group THEN s.highest + Position(members, t) ELSE @[t]],
          !.lastAction = "FreezeCohort"]

PublishAggregate(outcome) ==
    /\ s.online /\ s.phase = "Frozen" /\ s.batchPuts[s.active] = 0
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
    /\ s' = [s EXCEPT !.phase = IF s.active \in s.stored THEN "Ready" ELSE "BatchFailed",
                !.lastAction = "ConfirmAggregate"]

ObserveBatchFailure ==
    /\ s.online /\ s.phase = "BatchFailed"
    /\ LET members == ActiveMembers
       IN s' = [s EXCEPT
          !.txn = [t \in Txns |-> IF t \in members THEN "Failed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in members THEN "Failed" ELSE @[t]],
          !.excluded = @ \cup members, !.active = NoTxn, !.phase = "Idle",
          !.lastAction = "ObserveBatchFailure"]

BeginHeadAttempt ==
    /\ s.online /\ s.phase = "Ready" /\ s.active \in s.stored
    /\ s.headPuts[s.active] = 0
    /\ s' = [s EXCEPT !.headPuts[s.active] = 1, !.phase = "HeadAttempted",
                !.headMayHaveEntered = TRUE, !.lastAction = "BeginHeadAttempt"]

RivalHead ==
    /\ s.online /\ ~s.rivalObserved
    /\ s.phase \in {"Ready", "HeadAttempted", "Unknown"}
    /\ s.active \notin HeadBatches
    /\ s' = [s EXCEPT !.generation = @ + 1, !.rivalObserved = TRUE,
                !.lastAction = "RivalHead"]

EnterHead ==
    [s EXCEPT !.headBatch = s.active, !.highest = s.images[s.active].last,
        !.generation = @ + 1, !.published = @ \cup {s.active},
        !.visible = @ \cup ActiveMembers,
        !.recovered = IF s.reopened THEN @ \cup ActiveMembers ELSE @]

HeadAccepted ==
    /\ s.online /\ s.phase = "HeadAttempted"
    /\ s.generation = s.images[s.active].expected
    /\ s' = [EnterHead EXCEPT !.phase = "Accepted",
                !.headMayHaveEntered = FALSE, !.lastAction = "HeadAccepted"]

ClassifyHeadUnknown(entered, action) ==
    /\ s.online /\ s.phase = "HeadAttempted"
    /\ entered \in BOOLEAN
    /\ entered => s.generation = s.images[s.active].expected
    /\ LET next == IF entered THEN EnterHead ELSE s
           members == ActiveMembers
       IN s' = [next EXCEPT !.phase = "Unknown",
          !.txn = [t \in Txns |-> IF t \in members THEN "Unknown" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in members THEN "Unknown" ELSE @[t]],
          !.liveAuthority = [t \in Txns |->
              IF t \in members THEN Authority(t, s.active) ELSE @[t]],
          !.headMayHaveEntered = FALSE, !.lastAction = action]

HeadResponseLost(entered) ==
    ClassifyHeadUnknown(entered, "HeadResponseLost")

HeadPreconditionRejected ==
    /\ s.online /\ s.phase = "HeadAttempted"
    /\ s.generation # s.images[s.active].expected
    /\ LET members == ActiveMembers
       IN s' = [s EXCEPT
          !.txn = [t \in Txns |-> IF t \in members \cup Pending THEN "Failed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in members \cup Pending THEN "Failed" ELSE @[t]],
          !.excluded = @ \cup members \cup Pending, !.queue = <<>>,
          !.active = NoTxn, !.phase = "Idle", !.headMayHaveEntered = FALSE,
          !.fenced = TRUE, !.lastAction = "HeadPreconditionRejected"]

ObserveSuccess ==
    /\ s.online /\ s.phase = "Accepted"
    /\ LET members == ActiveMembers
       IN s' = [s EXCEPT
          !.txn = [t \in Txns |-> IF t \in members THEN "Committed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in members THEN "Committed" ELSE @[t]],
          !.acknowledged = @ \cup members, !.active = NoTxn, !.phase = "Idle",
          !.lastAction = "ObserveSuccess"]

ObserveLocalInstallFailure ==
    /\ s.online /\ s.phase = "Accepted"
    /\ LET members == ActiveMembers
           pending == Pending
       IN s' = [s EXCEPT
          !.txn = [t \in Txns |->
              IF t \in members THEN "Committed"
              ELSE IF t \in pending THEN "Failed" ELSE @[t]],
          !.receipt = [t \in Txns |->
              IF t \in members THEN "Committed"
              ELSE IF t \in pending THEN "Failed" ELSE @[t]],
          !.acknowledged = @ \cup members, !.excluded = @ \cup pending,
          !.queue = <<>>, !.active = NoTxn, !.phase = "Idle", !.fenced = TRUE,
          !.lastAction = "ObserveLocalInstallFailure"]

ResolveMember(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s.active \in {NoTxn, s.liveAuthority[t].batch}
    /\ s.liveAuthority[t].batch \in HeadBatches
    /\ s' = [s EXCEPT !.txn[t] = "Committed", !.receipt[t] = "Committed",
          !.acknowledged = @ \cup {t},
          !.liveAuthority[t] = NoAuthority,
          !.active = IF s.active = s.liveAuthority[t].batch THEN NoTxn ELSE @,
          !.phase = IF s.active = s.liveAuthority[t].batch THEN "Idle" ELSE @,
          !.lastAction = "ResolveMember"]

ResolveRejected(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s.active \in {NoTxn, s.liveAuthority[t].batch}
    /\ s.liveAuthority[t].batch \notin HeadBatches
    /\ s.generation >= s.liveAuthority[t].image.publication
    /\ LET members == AsSet(s.liveAuthority[t].image.members)
           pending == Pending
       IN s' = [s EXCEPT
          !.txn = [u \in Txns |-> IF u \in members \cup pending THEN "Failed" ELSE @[u]],
          !.receipt = [u \in Txns |->
              IF u = t \/ u \in pending THEN "Failed" ELSE @[u]],
          !.liveAuthority[t] = NoAuthority,
          !.excluded = @ \cup members \cup pending, !.queue = <<>>,
          !.active = NoTxn, !.phase = "Idle", !.fenced = TRUE,
          !.lastAction = "ResolveRejected"]

RetainUnknown(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s.liveAuthority[t].batch \notin HeadBatches
    /\ s.generation < s.liveAuthority[t].image.publication
    /\ s' = [s EXCEPT !.lastAction = "RetainUnknown"]

ExportAuthority(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s.durableAuthority[t] = NoAuthority
    /\ s' = [s EXCEPT !.durableAuthority[t] = s.liveAuthority[t],
                !.lastAction = "ExportAuthority"]

AuthorityInputs(t) ==
    IF s.durableAuthority[t] = NoAuthority
    THEN {}
    ELSE LET authority == s.durableAuthority[t]
         IN {authority, [authority EXCEPT !.database = OtherDB],
                [authority EXCEPT !.member =
                    CHOOSE other \in Txns \ {authority.member} : TRUE],
                [authority EXCEPT !.image.members = Tail(authority.image.members)]}

ImportAuthority(t) ==
    /\ s.online /\ s.receipt[t] = "None"
    /\ \E authority \in AuthorityInputs(t) :
        /\ StructuralAuthority(t, authority)
        /\ s' = [s EXCEPT !.receipt[t] = "Unknown", !.txn[t] = "Unknown",
                    !.liveAuthority[t] = authority, !.lastAction = "ImportAuthority"]

RejectMalformedAuthority(t) ==
    /\ s.online /\ s.receipt[t] = "None"
    /\ \E authority \in AuthorityInputs(t) :
        /\ ~StructuralAuthority(t, authority)
        /\ s' = [s EXCEPT !.malformedRejected = TRUE,
                    !.lastAction = "RejectMalformedAuthority"]

Crash(headEntered) ==
    /\ s.online /\ ~s.crashed
    /\ headEntered \in BOOLEAN
    /\ headEntered =>
         s.phase = "HeadAttempted" /\ s.generation = s.images[s.active].expected
    /\ LET durable == IF headEntered THEN EnterHead ELSE s
       IN s' = [durable EXCEPT !.online = FALSE, !.crashed = TRUE,
          !.reopened = FALSE,
          !.txn = [t \in Txns |-> IF t \in s.usedTxns THEN "Lost" ELSE @[t]],
          !.queue = <<>>, !.active = NoTxn, !.phase = "Idle",
          !.headMayHaveEntered = FALSE, !.receipt = [t \in Txns |-> "None"],
          !.liveAuthority = [t \in Txns |-> NoAuthority], !.recovered = {},
          !.memberBatch = [t \in Txns |-> NoTxn],
          !.memberSequence = [t \in Txns |-> 0], !.lastAction = "Crash"]

ReopenFromHead ==
    /\ ~s.online /\ ~s.reopened /\ HeadBatches \subseteq s.stored
    /\ s' = [s EXCEPT !.online = TRUE, !.reopened = TRUE, !.fenced = FALSE,
          !.draining = FALSE,
          !.recovered = HeadMembers,
          !.memberBatch = [t \in Txns |->
              IF t \in HeadMembers
              THEN CHOOSE batch \in HeadBatches : t \in Members(batch)
              ELSE NoTxn],
          !.memberSequence = [t \in Txns |->
              IF t \in HeadMembers
              THEN LET batch == CHOOSE b \in HeadBatches : t \in Members(b)
                   IN s.images[batch].first
                        + Position(s.images[batch].members, t) - 1
              ELSE 0],
          !.lastAction = "ReopenFromHead"]

CloseWithUnknown ==
    /\ s.online /\ s.draining /\ s.phase = "Unknown"
    /\ LET pending == Pending
       IN s' = [s EXCEPT
          !.txn = [t \in Txns |-> IF t \in pending THEN "Failed" ELSE @[t]],
          !.receipt = [t \in Txns |-> IF t \in pending THEN "Failed" ELSE @[t]],
          !.excluded = @ \cup pending, !.queue = <<>>,
          !.online = FALSE, !.reopened = FALSE,
          !.active = NoTxn, !.phase = "Idle",
          !.closedHead = s.headBatch, !.closedUnknown = s.active,
          !.closedPending = pending,
          !.lastAction = "CloseWithUnknown"]

Close ==
    /\ s.online /\ s.draining /\ s.phase = "Idle" /\ s.queue = <<>>
    /\ s' = [s EXCEPT !.online = FALSE, !.reopened = FALSE,
                !.closedHead = s.headBatch, !.closedUnknown = NoTxn,
                !.closedPending = {},
                !.lastAction = "Close"]

Next ==
    \/ \E t \in Txns : Admit(t) \/ CancelBeforeAdmission(t)
           \/ RequestCancellation(t) \/ ReachDeadline(t) \/ ExpireQueued(t)
    \/ Tick \/ \E t \in Txns : RejectQueuedConflict(t)
    \/ BeginClose \/ FreezeCohort
    \/ \E outcome \in {"Confirmed", "UnknownStored", "UnknownAbsent", "Failed"} :
           PublishAggregate(outcome)
    \/ ConfirmAggregate \/ ObserveBatchFailure \/ BeginHeadAttempt \/ RivalHead
    \/ HeadAccepted \/ \E entered \in BOOLEAN : HeadResponseLost(entered)
    \/ HeadPreconditionRejected \/ ObserveSuccess \/ ObserveLocalInstallFailure
    \/ \E t \in Txns : ResolveMember(t) \/ ResolveRejected(t) \/ RetainUnknown(t)
    \/ \E t \in Txns : ExportAuthority(t) \/ ImportAuthority(t)
           \/ RejectMalformedAuthority(t)
    \/ \E headEntered \in BOOLEAN : Crash(headEntered)
    \/ ReopenFromHead \/ CloseWithUnknown \/ Close

Spec == Init /\ [][Next]_vars

CoreConstraint == s.txn[T3] = "Idle" /\ T3 \notin s.usedTxns

SchedulerNext ==
    \/ \E t \in Txns : Admit(t) \/ CancelBeforeAdmission(t)
           \/ RequestCancellation(t) \/ ReachDeadline(t) \/ ExpireQueued(t)
    \/ Tick \/ \E t \in Txns : RejectQueuedConflict(t)
    \/ BeginClose \/ FreezeCohort
    \/ \E outcome \in {"Confirmed", "UnknownStored", "UnknownAbsent", "Failed"} :
           PublishAggregate(outcome)
    \/ ConfirmAggregate \/ ObserveBatchFailure \/ BeginHeadAttempt \/ RivalHead
    \/ HeadAccepted \/ \E entered \in BOOLEAN : HeadResponseLost(entered)
    \/ HeadPreconditionRejected \/ ObserveSuccess \/ ObserveLocalInstallFailure
    \/ CloseWithUnknown \/ Close

SchedulerSpec == Init /\ [][SchedulerNext]_vars

PublicationProgress ==
    (\E outcome \in {"Confirmed", "UnknownStored", "UnknownAbsent", "Failed"} :
        PublishAggregate(outcome))
    \/ ConfirmAggregate \/ ObserveBatchFailure \/ BeginHeadAttempt
    \/ HeadAccepted \/ (\E entered \in BOOLEAN : HeadResponseLost(entered))
    \/ HeadPreconditionRejected \/ ObserveSuccess \/ ObserveLocalInstallFailure

FairSpec == Spec /\ WF_vars(Tick) /\ WF_vars(FreezeCohort) /\ WF_vars(PublicationProgress)

TypeOK ==
    /\ s.txn \in [Txns -> TxnStates]
    /\ s.queue \in Seq(Txns) /\ Cardinality(Pending) = Len(s.queue)
    /\ Len(s.queue) <= Depth
    /\ s.age \in [Txns -> 0..MaxWait]
    /\ s.usedTxns \subseteq Txns /\ s.usedBatches \subseteq Txns
    /\ s.active \in Txns \cup {NoTxn} /\ s.phase \in Phases
    /\ DOMAIN s.images = Txns
    /\ \A t \in Txns : s.images[t] = EmptyImage \/ ImageValid(t, s.images[t])
    /\ s.stored \subseteq Txns /\ s.published \subseteq Txns
    /\ s.memberBatch \in [Txns -> Txns \cup {NoTxn}]
    /\ s.memberSequence \in [Txns -> 0..Cardinality(Txns)]
    /\ s.headBatch \in Txns \cup {NoTxn}
    /\ s.highest \in 0..Cardinality(Txns)
    /\ s.generation \in 0..(Cardinality(Txns) + 1)
    /\ s.visible \subseteq Txns /\ s.acknowledged \subseteq Txns
    /\ s.excluded \subseteq Txns /\ s.recovered \subseteq Txns
    /\ s.receipt \in [Txns -> ReceiptStates]
    /\ DOMAIN s.liveAuthority = Txns /\ DOMAIN s.durableAuthority = Txns
    /\ s.batchPuts \in [Txns -> 0..1] /\ s.headPuts \in [Txns -> 0..1]
    /\ s.resolutionWrites \in Nat
    /\ s.cancelRequested \subseteq s.usedTxns
    /\ s.deadlineReached \subseteq s.usedTxns
    /\ s.deadlineExpired \subseteq s.usedTxns
    /\ s.headMayHaveEntered \in BOOLEAN /\ s.draining \in BOOLEAN
    /\ s.online \in BOOLEAN /\ s.crashed \in BOOLEAN /\ s.reopened \in BOOLEAN
    /\ s.fenced \in BOOLEAN /\ s.rivalObserved \in BOOLEAN
    /\ s.closedHead \in Txns \cup {NoTxn}
    /\ s.closedUnknown \in Txns \cup {NoTxn}
    /\ s.closedPending \subseteq Txns
    /\ s.malformedRejected \in BOOLEAN /\ s.lastAction \in ActionNames

BoundedOwnership ==
    /\ Len(s.queue) + Cardinality(ActiveMembers) <= Depth
    /\ Pending = {t \in Txns : s.txn[t] = "Queued"}
    /\ ActiveMembers \intersect Pending = {}
    /\ (s.active = NoTxn) = (s.phase = "Idle")

PreAdmissionCancellationKeepsIdentity ==
    \A t \in Txns : s.txn[t] = "Idle" => t \notin s.usedTxns

LeaderAliasIsExact ==
    /\ s.usedBatches \subseteq s.usedTxns
    /\ \A batch \in s.usedBatches :
         /\ s.images[batch].members[1] = batch
         /\ Cardinality({index \in 1..Len(s.images[batch].members) :
               s.images[batch].members[index] = batch}) = 1
    /\ \A member \in Txns : s.memberBatch[member] # NoTxn =>
         /\ member \in Members(s.memberBatch[member])
         /\ s.memberSequence[member] = s.images[s.memberBatch[member]].first
              + Position(s.images[s.memberBatch[member]].members, member) - 1

WholeCohortVisibility ==
    /\ s.visible = HeadMembers /\ s.published = HeadBatches
    /\ \A batch \in s.usedBatches :
         Members(batch) \intersect s.visible = {} \/ Members(batch) \subseteq s.visible

ExactHeadChain ==
    /\ (s.headBatch = NoTxn) = (s.highest = 0)
    /\ s.headBatch # NoTxn => s.highest = s.images[s.headBatch].last
    /\ \A batch \in HeadBatches :
         /\ batch \in s.stored /\ ImageValid(batch, s.images[batch])
         /\ IF s.images[batch].previous = NoTxn
            THEN s.images[batch].first = 1
            ELSE /\ s.images[batch].previous \in HeadBatches
                 /\ s.images[batch].first =
                      s.images[s.images[batch].previous].last + 1
    /\ \A left, right \in HeadBatches :
         left # right => Members(left) \intersect Members(right) = {}
    /\ s.highest = Cardinality(s.visible)

NoEarlyAcknowledgement ==
    /\ s.acknowledged \subseteq s.visible
    /\ \A t \in Txns : s.receipt[t] = "Committed" => t \in s.visible

NoSplitAfterHeadAttempt ==
    /\ s.headMayHaveEntered => s.phase = "HeadAttempted"
    /\ s.phase \in {"HeadAttempted", "Unknown", "Accepted"} =>
         \A left, right \in ActiveMembers :
           /\ s.txn[left] \notin {"TimedOut", "Rejected", "Failed"}
           /\ s.txn[right] \notin {"TimedOut", "Rejected", "Failed"}
    /\ \A batch \in s.usedBatches :
         Members(batch) \intersect s.visible # {} =>
           \A member \in Members(batch) :
             s.txn[member] \notin {"TimedOut", "Rejected", "Failed"}

PublicationGeometry ==
    /\ HeadBatches \subseteq s.stored
    /\ \A batch \in Txns : s.batchPuts[batch] <= 1 /\ s.headPuts[batch] <= 1
    /\ \A batch \in s.published : s.batchPuts[batch] = 1 /\ s.headPuts[batch] = 1
    /\ s.resolutionWrites = 0

CancellationAndDeadlineCut ==
    /\ s.cancelRequested \subseteq s.usedTxns
    /\ s.deadlineExpired \subseteq s.deadlineReached
    /\ \A t \in Txns : s.txn[t] = "TimedOut" =>
         t \notin Pending \cup ActiveMembers \cup s.visible
    /\ \A t \in s.cancelRequested : s.txn[t] # "Cancelled"

ExclusionIsNotVisible == s.excluded \intersect s.visible = {}

FencingStopsAdmission == s.fenced => s.queue = <<>> /\ s.active = NoTxn

AuthorityIsComplete ==
    /\ \A t \in Txns : s.receipt[t] = "Unknown" =>
         ExactAuthority(t, s.liveAuthority[t])
    /\ \A t \in Txns : s.durableAuthority[t] # NoAuthority =>
         ExactAuthority(t, s.durableAuthority[t])
    /\ \A t \in Txns : s.receipt[t] = "Committed" /\ s.liveAuthority[t] # NoAuthority =>
         ExactAuthority(t, s.liveAuthority[t])

RecoveryUsesHeadOnly ==
    /\ s.recovered \subseteq HeadMembers
    /\ s.reopened => s.recovered = HeadMembers

Safety ==
    /\ TypeOK /\ BoundedOwnership /\ PreAdmissionCancellationKeepsIdentity
    /\ LeaderAliasIsExact
    /\ WholeCohortVisibility /\ ExactHeadChain
    /\ NoEarlyAcknowledgement /\ NoSplitAfterHeadAttempt
    /\ PublicationGeometry /\ CancellationAndDeadlineCut
    /\ ExclusionIsNotVisible /\ FencingStopsAdmission
    /\ AuthorityIsComplete /\ RecoveryUsesHeadOnly

SchedulerSafety ==
    /\ TypeOK /\ BoundedOwnership /\ PreAdmissionCancellationKeepsIdentity
    /\ LeaderAliasIsExact
    /\ WholeCohortVisibility /\ ExactHeadChain
    /\ NoEarlyAcknowledgement /\ NoSplitAfterHeadAttempt
    /\ PublicationGeometry /\ CancellationAndDeadlineCut
    /\ ExclusionIsNotVisible /\ FencingStopsAdmission

QueuedEventuallyLeaves(t) == t \in Pending ~> t \notin Pending
FrozenEventuallyClassifies(t) == t \in ActiveMembers ~> s.txn[t] # "Frozen"
TailEventuallyFreezes == s.queue # <<>> ~> s.phase # "Idle" \/ s.queue = <<>>

Trace ==
    [action |-> s.lastAction, phase |-> s.phase, queue |-> s.queue,
     age |-> s.age, active |-> s.active, head |-> s.headBatch,
     sequence |-> s.highest, visible |-> s.visible, receipt |-> s.receipt,
     batchPuts |-> s.batchPuts, headPuts |-> s.headPuts,
     cancellation |-> s.cancelRequested, expired |-> s.deadlineExpired,
     fenced |-> s.fenced]

StateView == [s EXCEPT !.lastAction = "Init"]

=============================================================================
