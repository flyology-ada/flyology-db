----------- MODULE PipelinedAdaptiveAggregateCommitCoalescing -----------
EXTENDS FiniteSets, Naturals, Sequences, TLC

(***************************************************************************
Source foundation only. All constants below are finite qualification geometry,
not runtime defaults or a public profile. Independent submissions enter one
bounded admission FIFO. Canonical transaction preparation and cohort assembly
have separate start/complete/join transitions and bounded shared offload slots.
The bounded ready queue owns assembled immutable cohorts awaiting batch PUT.
Input, future preparation/aggregate credit, and allocated fragments and aggregates all count
against one byte budget. Admission reserves the complete worst-case transition peak so an
accepted transaction cannot become permanently unpreparable solely because of byte capacity.
Freeze selects an admission-order compatible prefix and assigns each member
its own sequence and its original leader transaction's batch identity.

Preparation and batch PUTs overlap. Only the front owns the local-state validation
projection; successful validation history survives projection release. HEAD,
installation, and terminal availability
retire in order. An admitted operation retains its coordinator slot until its caller completion
set collects the terminal result. Public Finish is a later DeliverReceipt
transfer; operation-owned and caller-owned receipt authority outlive the slot.
Close waits for collection and joins, not public delivery. Operation finalization
may discard a collected, undelivered result without retaining the database.
Logical predecessor fields freeze early; the opaque CAS token binds only when
the front cohort starts HEAD. A token is compared for equality, never ordered.
Same-receipt resolution retains its exact observed token through local install;
a later token cannot be borrowed as the predecessor of the next cohort.

An unpublished conflicting predecessor leaves a candidate unfrozen. Only a
conclusive installed predecessor permits snapshot conflict revalidation.
Normal close permits compatible successor preparation and immutable PUTs to
overlap an outstanding predecessor; authoritative HEAD retirement stays ordered.
Unknown A halts admission, joins and abandons every not-yet-HEAD successor
and queued submission, then permits A's resolution or authority detachment.
An orphan is never rebased, resequenced, or replayed. Resolving A does not
restart this episode; reopen/new-episode identity policy is outside the model.
Cancellation after admission is a request to drain, not publication rollback.
No deadline policy is introduced. Crash is modeled only after provider joins
at the returned-authority boundary, not an arbitrary kill inside Commit.
Focused progress and lifecycle modules state their own finite assumptions.
No byte-format, provider, Ada refinement, or performance claim follows from
this source. Recovery discovers only the authoritative HEAD.
***************************************************************************)

CONSTANTS MaxWidth, MaxBytes, MaxWait, Depth, PipelineCapacity,
          PrepareCapacity, ByteCapacity, TxnBytes, ConflictPairs
Cohorts == 1..4
Transactions == 1..4
Slots == 1..PipelineCapacity
Slot(c) == ((c - 1) % PipelineCapacity) + 1
Tokens == {"Initial", "A", "B", "C", "D", "Rival"}
Token(c) == CASE c = 1 -> "A" [] c = 2 -> "B" [] c = 3 -> "C" [] OTHER -> "D"
TxnBytesModel == [t \in Transactions |-> IF t = 2 THEN 2 ELSE 1]
OversizedTxnBytesModel == [t \in Transactions |-> IF t = 2 THEN MaxBytes + 1 ELSE 1]
NoConflictPairsModel == {}
ConflictPairsModel == {<<3, 1>>}
ConstantsOK ==
    /\ MaxWidth \in 1..4 /\ MaxBytes \in Nat \ {0} /\ MaxWait \in Nat \ {0}
    /\ Depth \in 1..4 /\ PipelineCapacity \in 1..4 /\ PrepareCapacity \in 1..8
    /\ ByteCapacity \in Nat \ {0} /\ TxnBytes \in [Transactions -> Nat \ {0}]
    /\ ConflictPairs \subseteq Transactions \X Transactions
AsSet(q) == {q[i] : i \in 1..Len(q)}
Remove(q, values) == SelectSeq(q, LAMBDA value : value \notin values)
RECURSIVE SumBytes(_)
SumBytes(ts) == IF ts = {} THEN 0
               ELSE LET t == CHOOSE member \in ts : TRUE
                    IN TxnBytes[t] + SumBytes(ts \ {t})
PrefixBytes(q, n) == SumBytes(AsSet(SubSeq(q, 1, n)))
\* One envelope unit abstracts encoded header/trailer bytes, not a runtime size.
EncodedPrefixBytes(q, n) == 1 + PrefixBytes(q, n)
TxnWork(t) == <<"Txn", t>>
BatchWork(c) == <<"Batch", c>>
PrepareWork == {TxnWork(t) : t \in Transactions} \cup {BatchWork(c) : c \in Cohorts}
EmptyImage == [previous |-> 0, first |-> 0, last |-> 0, members |-> <<>>,
               fragments |-> <<>>, batch |-> 0, bytes |-> 0]
ImageType == [previous : 0..4, first : 0..4, last : 0..4,
              members : Seq(Transactions), fragments : Seq(Transactions),
              batch : Transactions \cup {0}, bytes : Nat]
RequestStates == {"NotStarted", "InFlight", "Completed", "Joined"}
Phases == {"Unused", "Frozen", "BatchReady", "PrepareFailed", "BatchUnknown", "Ready",
           "HeadReady", "PreHeadFailed", "HeadPending", "Accepted", "Unknown",
           "ResolutionReady", "Durable", "Abandoned", "Excluded"}
ReceiptStates == {"None", "Pending", "Unknown", "Success", "Failed"}

VARIABLE s
vars == <<s>>

Front == IF Len(s.pipe) = 0 THEN 0 ELSE Head(s.pipe)
TailCohort == IF Len(s.pipe) = 0 THEN s.installed ELSE s.pipe[Len(s.pipe)]
Frozen == 1..(s.next - 1)
PipeSet == AsSet(s.pipe)
Pending == AsSet(s.pending)
AdmissionPosition(t) == CHOOSE i \in 1..Len(s.admission) : s.admission[i] = t
ReadySet == AsSet(s.ready)
Members(c) == IF c = 0 THEN {} ELSE AsSet(s.image[c].members)
MemberCohort(t) == s.memberCohort[t]
FrozenMembers == UNION {Members(c) : c \in Frozen}
PreparedTxns == {t \in Transactions :
    s.prepareRequest[TxnWork(t)] = "Joined" /\ s.fragment[t] = t}
Sealed == {c \in Frozen : s.prepareRequest[BatchWork(c)] = "Joined" /\
                         s.prepareOutcome[BatchWork(c)] = "Success"}
PrepareBorrowed == {w \in PrepareWork : s.prepareRequest[w] \in {"InFlight", "Completed"}}
TxnBorrowed == {t \in Transactions : TxnWork(t) \in PrepareBorrowed}
BatchPreparing == {c \in Cohorts : BatchWork(c) \in PrepareBorrowed}
RECURSIVE Chain(_, _)
Chain(c, fuel) ==
    IF c = 0 \/ fuel = 0 THEN {}
    ELSE {c} \cup Chain(s.image[c].previous, fuel - 1)
HeadChain == Chain(s.head, 4)
InstalledChain == Chain(s.installed, 4)
Prefix(c) == Chain(s.image[c].previous, 4)
HeadMembers == UNION {Members(c) : c \in HeadChain}
BatchBorrowed == {c \in Cohorts : s.batchRequest[c] \in {"InFlight", "Completed"}}
HeadBorrowed == {c \in Cohorts : s.headRequest[c] \in {"InFlight", "Completed"}}
ReceiptImages == {MemberCohort(t) : t \in Transactions \ s.dropped} \ {0}
ExportImages == {MemberCohort(t) : t \in s.exported}
ResolvingMembers == {s.resolvingMember[c] : c \in Cohorts} \ {0}
Retained == PipeSet \cup ReceiptImages \cup ExportImages
UnknownFront == Front # 0 /\ s.phase[Front] = "Unknown"
ResolutionReadyFront == Front # 0 /\ s.phase[Front] = "ResolutionReady"
UnsettledFront == UnknownFront \/ ResolutionReadyFront
NoBorrow == PrepareBorrowed = {} /\ BatchBorrowed = {} /\ HeadBorrowed = {}
SuccessorsDrained ==
    /\ Front # 0 /\ s.pipe = <<Front>> /\ s.pending = <<>> /\ s.ready = <<>>
    /\ PrepareBorrowed = {} /\ BatchBorrowed = {} /\ HeadBorrowed = {}
InstalledHighest == IF s.installed = 0 THEN 0 ELSE s.image[s.installed].last
LiveTransactions == s.admitted \ s.collected
RECURSIVE AggregateBytes(_)
AggregateBytes(cs) == IF cs = {} THEN 0
    ELSE LET c == CHOOSE cohort \in cs : TRUE
         IN s.image[c].bytes + AggregateBytes(cs \ {c})
ResidentBytes == SumBytes(s.inputOwned) + SumBytes(s.fragmentAllocated) + AggregateBytes(s.allocated)
ReservedBytes ==
    ResidentBytes + SumBytes(Pending \ TxnBorrowed) + Cardinality(Pending)
AdmissionBytes(t) == 2 * TxnBytes[t] + 1
Conflict(t, earlier) == \E other \in earlier : <<t, other>> \in ConflictPairs
UnpublishedConflict(t) == Conflict(t, UNION {Members(c) : c \in PipeSet \ InstalledChain})
CommittedConflict(t) ==
    \E other \in UNION {Members(c) : c \in InstalledChain} :
      <<t, other>> \in ConflictPairs /\ s.memberSequence[other] > s.snapshot[t]
CompatiblePrefix(n) ==
    /\ AsSet(SubSeq(s.pending, 1, n)) \subseteq PreparedTxns \cap s.fragmentAllocated
    /\ \A i \in 1..n :
         /\ ~CommittedConflict(s.pending[i]) /\ ~UnpublishedConflict(s.pending[i])
         /\ ~Conflict(s.pending[i], AsSet(SubSeq(s.pending, 1, i - 1)))
    /\ n = 1 \/ EncodedPrefixBytes(s.pending, n) <= MaxBytes
EligibleCounts == {n \in 1..MaxWidth : n <= Len(s.pending) /\ CompatiblePrefix(n)}
SelectedCount == IF EligibleCounts = {} THEN 0
                 ELSE CHOOSE n \in EligibleCounts : \A other \in EligibleCounts : other <= n
SelectedConflictBoundary ==
    IF SelectedCount > 0 /\ SelectedCount < Len(s.pending)
    THEN LET candidate == s.pending[SelectedCount + 1]
         IN /\ candidate \in PreparedTxns \cap s.fragmentAllocated
            /\ ~CommittedConflict(candidate)
            /\ (Conflict(candidate, AsSet(SubSeq(s.pending, 1, SelectedCount)))
                \/ UnpublishedConflict(candidate))
    ELSE FALSE
FreezeEligible ==
    /\ s.online /\ ~s.halted /\ ~s.fenced /\ ~UnsettledFront
    /\ s.next \in Cohorts /\ Len(s.pipe) < PipelineCapacity /\ s.slotOwner[Slot(s.next)] = 0
    /\ SelectedCount > 0
    /\ s.draining \/ SelectedCount = MaxWidth \/ s.age[Head(s.pending)] = MaxWait
       \/ SelectedConflictBoundary
       \/ EncodedPrefixBytes(s.pending, SelectedCount) >= MaxBytes
       \/ (SelectedCount < Len(s.pending) /\
           EncodedPrefixBytes(s.pending, SelectedCount + 1) > MaxBytes)
    /\ ResidentBytes + EncodedPrefixBytes(s.pending, SelectedCount) <= ByteCapacity

Init ==
    /\ ConstantsOK
    /\ s = [pending |-> <<>>, admitted |-> {}, collected |-> {}, delivered |-> {}, admission |-> <<>>,
         snapshot |-> [t \in Transactions |-> 0],
         age |-> [t \in Transactions |-> 0], inputOwned |-> {}, fragmentAllocated |-> {},
         fragment |-> [t \in Transactions |-> 0], ready |-> <<>>,
         prepareRequest |-> [w \in PrepareWork |-> "NotStarted"],
         prepareOutcome |-> [w \in PrepareWork |-> "None"],
         memberCohort |-> [t \in Transactions |-> 0],
         memberSequence |-> [t \in Transactions |-> 0],
         receiptBatch |-> [t \in Transactions |-> 0],
         conflictWaited |-> {}, conflictRejected |-> {},
         conflictBasis |-> [t \in Transactions |-> 0], abandonedSuccessors |-> {},
         unknownEpisode |-> FALSE,
         widthTail |-> FALSE, byteTail |-> FALSE, waitTail |-> FALSE,
         closeTail |-> FALSE, oversizedTail |-> FALSE,
         overlappedPrepare |-> FALSE, backpressured |-> FALSE, stalePrepareIgnored |-> FALSE,
         pipe |-> <<>>, next |-> 1, image |-> [c \in Cohorts |-> EmptyImage],
         frozenImage |-> [c \in Cohorts |-> EmptyImage],
         validationPrefix |-> [c \in Cohorts |-> {}],
         prepareFailed |-> {}, validated |-> {}, preHeadFailed |-> {}, projection |-> 0,
         validationHead |-> [c \in Cohorts |-> 0],
         validationToken |-> [c \in Cohorts |-> "Initial"],
         slotOwner |-> [slot \in Slots |-> 0], allocated |-> {},
         phase |-> [c \in Cohorts |-> "Unused"],
         batchRequest |-> [c \in Cohorts |-> "NotStarted"],
         batchOutcome |-> [c \in Cohorts |-> "None"], stored |-> {},
         headRequest |-> [c \in Cohorts |-> "NotStarted"],
         headDecision |-> [c \in Cohorts |-> "Pending"],
         headOutcome |-> [c \in Cohorts |-> "None"],
         casToken |-> [c \in Cohorts |-> "Initial"],
         resolutionToken |-> [c \in Cohorts |-> "Initial"],
         resolvingMember |-> [c \in Cohorts |-> 0],
         head |-> 0, headToken |-> "Initial", installed |-> 0, installedToken |-> "Initial",
         published |-> {}, acknowledged |-> {}, excluded |-> {},
         receipt |-> [t \in Transactions |-> "None"],
         dropped |-> Transactions, exported |-> {}, resolved |-> {},
         batchPuts |-> [c \in Cohorts |-> 0], headPuts |-> [c \in Cohorts |-> 0],
         resolutionWrites |-> 0, cancelRequested |-> {},
         online |-> TRUE, draining |-> FALSE, halted |-> FALSE, fenced |-> FALSE,
         rival |-> FALSE, outOfOrderBatch |-> FALSE, overlappedBatch |-> FALSE, reusedSlot |-> FALSE,
         localFailure |-> FALSE, closed |-> FALSE, reopened |-> FALSE, staleIgnored |-> FALSE,
         crashed |-> FALSE, imported |-> {},
         lastAction |-> "Init"]

Admit(t, snapshot) ==
    /\ s.online /\ ~s.draining /\ ~s.halted /\ ~s.fenced /\ ~UnsettledFront
    /\ t \in Transactions \ s.admitted /\ snapshot \in 0..InstalledHighest
    /\ Cardinality(LiveTransactions) < Depth
    /\ ReservedBytes + AdmissionBytes(t) <= ByteCapacity
    /\ s' = [s EXCEPT !.pending = Append(@, t), !.admission = Append(@, t),
          !.admitted = @ \cup {t},
          !.snapshot[t] = snapshot, !.inputOwned = @ \cup {t},
          !.receipt[t] = "Pending", !.receiptBatch[t] = t, !.dropped = @ \ {t},
          !.lastAction = "Admit"]

RejectBeforeAdmission(t) ==
    /\ t \in Transactions \ s.admitted
    /\ UNCHANGED s
    \* Invalid, cancelled, unsupported-deadline, or peak-reservation failure acquires no ownership.

ObserveBackpressure(t) ==
    /\ t \in Transactions \ s.admitted /\ ~s.backpressured
    /\ Cardinality(LiveTransactions) = Depth
       \/ ReservedBytes + AdmissionBytes(t) > ByteCapacity
    /\ s' = [s EXCEPT !.backpressured = TRUE, !.lastAction = "ObserveBackpressure"]

Tick ==
    /\ \E t \in Pending : s.age[t] < MaxWait
    /\ s' = [s EXCEPT !.age = [t \in Transactions |->
          IF t \in Pending /\ @[t] < MaxWait THEN @[t] + 1 ELSE @[t]], !.lastAction = "Tick"]

WaitForPredecessor(t) ==
    /\ t \in Pending \ s.conflictWaited /\ UnpublishedConflict(t)
    /\ s' = [s EXCEPT !.conflictWaited = @ \cup {t}, !.lastAction = "WaitForPredecessor"]

RejectQueuedConflict(t) ==
    /\ t \in Pending \ TxnBorrowed /\ ~UnpublishedConflict(t) /\ CommittedConflict(t)
    /\ s' = [s EXCEPT !.pending = Remove(@, {t}), !.excluded = @ \cup {t},
          !.conflictRejected = @ \cup {t}, !.inputOwned = @ \ {t},
          !.conflictBasis[t] = CHOOSE other \in UNION {Members(c) : c \in InstalledChain} :
              <<t, other>> \in ConflictPairs /\ s.memberSequence[other] > s.snapshot[t],
          !.fragmentAllocated = @ \ {t}, !.receipt[t] = "Failed",
          !.lastAction = "RejectQueuedConflict"]

StartPrepare(w) ==
    /\ s.online /\ ~s.halted /\ ~s.fenced /\ ~UnsettledFront
    /\ w \in PrepareWork /\ s.prepareRequest[w] = "NotStarted"
    /\ Cardinality(PrepareBorrowed) < PrepareCapacity
    /\ IF w[1] = "Txn"
          THEN /\ w[2] \in Pending \cap s.inputOwned
               /\ ResidentBytes + TxnBytes[w[2]] <= ByteCapacity
          ELSE /\ w[2] \in PipeSet /\ s.phase[w[2]] = "Frozen"
               /\ Members(w[2]) \subseteq s.fragmentAllocated
    /\ s' = [s EXCEPT !.prepareRequest[w] = "InFlight",
          !.fragmentAllocated = IF w[1] = "Txn" THEN @ \cup {w[2]} ELSE @,
          !.overlappedPrepare = @ \/ BatchBorrowed # {}, !.lastAction = "StartPrepare"]

CompletePrepare(w, outcome) ==
    /\ s.prepareRequest[w] = "InFlight" /\ outcome \in {"Success", "Failed"}
    /\ s' = [s EXCEPT !.prepareRequest[w] = "Completed", !.prepareOutcome[w] = outcome,
                      !.lastAction = "CompletePrepare"]

JoinPrepare(w) ==
    /\ s.prepareRequest[w] = "Completed"
    /\ LET id == w[2]
           txn == w[1] = "Txn"
           accepted == s.prepareOutcome[w] = "Success" /\
                       (IF txn THEN id \in Pending ELSE s.phase[id] # "Abandoned")
       IN s' = [s EXCEPT !.prepareRequest[w] = "Joined",
          !.inputOwned = IF txn THEN @ \ {id} ELSE @,
          !.fragment = IF txn /\ accepted THEN [@ EXCEPT ![id] = id] ELSE @,
          !.fragmentAllocated = IF txn THEN IF accepted THEN @ ELSE @ \ {id}
                                ELSE @ \ Members(id),
          !.pending = IF txn /\ ~accepted THEN Remove(@, {id}) ELSE @,
          !.excluded = IF txn /\ ~accepted THEN @ \cup {id} ELSE @,
          !.receipt = IF txn /\ ~accepted THEN [@ EXCEPT ![id] = "Failed"] ELSE @,
          !.prepareFailed = IF ~txn /\ s.prepareOutcome[w] = "Failed" THEN @ \cup {id} ELSE @,
          !.phase = IF txn THEN @ ELSE [@ EXCEPT ![id] =
              IF @ = "Abandoned" THEN @ ELSE IF accepted THEN "BatchReady" ELSE "PrepareFailed"],
          !.ready = IF ~txn /\ accepted THEN Append(@, id) ELSE @,
          !.lastAction = "JoinPrepare"]

IgnoreStalePrepareCompletion(c) ==
    /\ s.prepareRequest[BatchWork(c)] = "Joined"
    /\ s.slotOwner[Slot(c)] \notin {0, c} /\ ~s.stalePrepareIgnored
    /\ s' = [s EXCEPT !.stalePrepareIgnored = TRUE, !.lastAction = "IgnoreStalePrepareCompletion"]

Freeze ==
    /\ FreezeEligible
    /\ LET c == s.next
           n == SelectedCount
           members == SubSeq(s.pending, 1, n)
           memberSet == AsSet(members)
           predecessor == TailCohort
           last == IF predecessor = 0 THEN 0 ELSE s.image[predecessor].last
           image == [previous |-> predecessor, first |-> last + 1,
                     last |-> last + n, members |-> members, fragments |-> members,
                     batch |-> Head(members), bytes |-> 1 + SumBytes(memberSet)]
       IN s' = [s EXCEPT !.pending = SubSeq(@, n + 1, Len(@)),
          !.pipe = Append(@, c), !.next = c + 1,
          !.image[c] = image, !.frozenImage[c] = image,
          !.validationPrefix[c] = InstalledChain \cup PipeSet,
          !.slotOwner[Slot(c)] = c, !.allocated = @ \cup {c}, !.phase[c] = "Frozen",
          !.memberCohort = [t \in Transactions |-> IF t \in memberSet THEN c ELSE @[t]],
          !.memberSequence = [t \in Transactions |-> IF t \in memberSet
              THEN last + (CHOOSE i \in 1..n : members[i] = t) ELSE @[t]],
          !.receiptBatch = [t \in Transactions |-> IF t \in memberSet THEN Head(members) ELSE @[t]],
          !.reusedSlot = @ \/ c > PipelineCapacity,
          !.widthTail = @ \/ n = MaxWidth,
          !.byteTail = @ \/ (n < MaxWidth /\ n < Len(s.pending) /\
                            EncodedPrefixBytes(s.pending, n + 1) > MaxBytes),
          !.waitTail = @ \/ s.age[Head(members)] = MaxWait,
          !.closeTail = @ \/ s.draining,
          !.oversizedTail = @ \/ image.bytes > MaxBytes,
          !.lastAction = "Freeze"]

RequestCancellation(t) ==
    /\ s.online /\ t \in Transactions /\ s.receipt[t] = "Pending"
    /\ t \notin s.cancelRequested
    /\ s' = [s EXCEPT !.cancelRequested = @ \cup {t}, !.lastAction = "RequestCancellation"]

CollectTerminal(t) ==
    /\ t \in s.admitted \ s.collected /\ s.receipt[t] \in {"Success", "Failed", "Unknown"}
    /\ t \notin TxnBorrowed /\ MemberCohort(t) \notin BatchPreparing \cup BatchBorrowed \cup HeadBorrowed
    /\ s' = [s EXCEPT !.collected = @ \cup {t}, !.lastAction = "CollectTerminal"]

\* Public Finish moves detached receipt authority without retaining the DB.
DeliverReceipt(t) ==
    /\ t \in s.collected \ (s.delivered \cup s.dropped)
    /\ s.receipt[t] \in {"Success", "Failed", "Unknown"}
    /\ s' = [s EXCEPT !.delivered = @ \cup {t}, !.lastAction = "DeliverReceipt"]

\* A terminal operation may finalize without delivering its receipt.
DiscardCollected(t) ==
    /\ t \in s.collected \ (s.delivered \cup s.dropped)
    /\ s.receipt[t] \in {"Success", "Failed", "Unknown"}
    /\ s' = [s EXCEPT !.dropped = @ \cup {t}, !.receipt[t] = "None",
                      !.lastAction = "DiscardCollected"]

StartBatch(c) ==
    /\ s.online /\ ~s.fenced /\ ~s.halted /\ ~UnsettledFront
    /\ c \in ReadySet \cap Sealed /\ s.phase[c] = "BatchReady"
    /\ s.batchRequest[c] = "NotStarted" /\ s.batchPuts[c] = 0
    /\ s' = [s EXCEPT !.ready = Remove(@, {c}),
                      !.batchRequest[c] = "InFlight", !.batchPuts[c] = 1,
                      !.overlappedBatch = @ \/ BatchBorrowed # {},
                      !.lastAction = "StartBatch"]

StoreBatch(c) ==
    /\ c \in PipeSet /\ s.batchRequest[c] = "InFlight" /\ c \notin s.stored
    /\ s' = [s EXCEPT !.stored = @ \cup {c}, !.lastAction = "StoreBatch"]

CompleteBatch(c, outcome) ==
    /\ s.batchRequest[c] = "InFlight"
    /\ outcome \in {"Success", "Absent", "Unknown"}
    /\ (outcome = "Success" => c \in s.stored)
    /\ (outcome = "Absent" => c \notin s.stored)
    /\ s' = [s EXCEPT !.batchRequest[c] = "Completed", !.batchOutcome[c] = outcome,
                      !.lastAction = "CompleteBatch"]

JoinBatch(c) ==
    /\ s.batchRequest[c] = "Completed"
    /\ s' = [s EXCEPT !.batchRequest[c] = "Joined",
          !.phase[c] = IF @ = "Abandoned" THEN @
                       ELSE IF s.batchOutcome[c] = "Success" THEN "Ready"
                       ELSE "BatchUnknown",
          !.outOfOrderBatch = @ \/ (c = 2 /\ s.batchRequest[1] # "Joined"),
          !.lastAction = "JoinBatch"]

IgnoreStaleCompletion(c) ==
    /\ s.batchRequest[c] = "Joined" /\ s.slotOwner[Slot(c)] \notin {0, c}
    /\ ~s.staleIgnored
    /\ s' = [s EXCEPT !.staleIgnored = TRUE, !.lastAction = "IgnoreStaleCompletion"]

ObserveBatch(c) ==
    /\ s.online /\ c \in PipeSet /\ s.phase[c] = "BatchUnknown" /\ c \in s.stored
    /\ s' = [s EXCEPT !.phase[c] = "Ready", !.lastAction = "ObserveBatch"]

\* A failed later preparation does not halt its successful predecessors.
FailPreparedFront(c) ==
    /\ s.online /\ c = Front /\ c \in s.prepareFailed
    /\ s.phase[c] = "PrepareFailed" /\ ~s.halted
    /\ s.prepareRequest[BatchWork(c)] = "Joined" /\ s.headPuts[c] = 0
    /\ s' = [s EXCEPT !.halted = TRUE, !.lastAction = "FailPreparedFront"]

\* Freeze validates isolation; this separate cut reserves the singleton local
\* installation projection against the exact installed predecessor.
ValidateFront(c, success) ==
    /\ s.online /\ ~s.fenced /\ ~s.halted /\ c = Front /\ c \in PipeSet
    /\ s.phase[c] = "Ready" /\ c \in s.stored /\ HeadBorrowed = {}
    /\ s.projection = 0 /\ s.image[c].previous = s.installed /\ s.installed = s.head
    /\ s.headPuts[c] = 0 /\ s.headRequest[c] = "NotStarted" /\ success \in BOOLEAN
    /\ s' = [s EXCEPT !.phase[c] = IF success THEN "HeadReady" ELSE "PreHeadFailed",
          !.projection = IF success THEN c ELSE 0,
          !.validated = IF success THEN @ \cup {c} ELSE @,
          !.preHeadFailed = IF success THEN @ ELSE @ \cup {c},
          !.validationHead[c] = IF success THEN s.installed ELSE @,
          !.validationToken[c] = IF success THEN s.installedToken ELSE @,
          !.halted = @ \/ ~success, !.lastAction = "ValidateFront"]

StartHead ==
    /\ s.online /\ ~s.fenced /\ ~s.halted /\ Front # 0
    /\ s.phase[Front] = "HeadReady" /\ Front \in s.stored /\ HeadBorrowed = {}
    /\ s.projection = Front /\ Front \in s.validated
    /\ s.image[Front].previous = s.head /\ s.installed = s.head
    /\ s.validationHead[Front] = s.installed /\ s.validationToken[Front] = s.installedToken
    /\ s.headPuts[Front] = 0 /\ s.headRequest[Front] = "NotStarted"
    /\ s' = [s EXCEPT !.headRequest[Front] = "InFlight", !.headPuts[Front] = 1,
          !.casToken[Front] = s.validationToken[Front], !.phase[Front] = "HeadPending",
          !.lastAction = "StartHead"]

ApplyHead(c) ==
    /\ c = Front /\ s.headRequest[c] = "InFlight" /\ s.headDecision[c] = "Pending"
    /\ s.casToken[c] = s.headToken /\ s.image[c].previous = s.head
    /\ s' = [s EXCEPT !.head = c, !.headToken = Token(c),
          !.headDecision[c] = "Accepted", !.published = @ \cup {c}, !.lastAction = "ApplyHead"]

RivalHead ==
    /\ s.online /\ ~s.rival
    /\ s' = [s EXCEPT !.headToken = "Rival", !.rival = TRUE, !.lastAction = "RivalHead"]

CompleteHead(c, outcome) ==
    /\ s.headRequest[c] = "InFlight"
    /\ outcome \in {"Success", "Rejected", "Unknown"}
    /\ (outcome = "Success" => s.headDecision[c] = "Accepted")
    /\ (outcome = "Rejected" => s.headDecision[c] = "Pending" /\ s.casToken[c] # s.headToken)
    /\ s' = [s EXCEPT !.headRequest[c] = "Completed", !.headOutcome[c] = outcome,
          !.headDecision[c] = IF @ = "Accepted" THEN @ ELSE "NotEntered",
          !.lastAction = "CompleteHead"]

JoinHead(c) ==
    /\ s.headRequest[c] = "Completed" /\ c = Front
    /\ s' = [s EXCEPT !.headRequest[c] = "Joined",
          !.projection = IF s.headOutcome[c] = "Success" THEN @ ELSE 0,
          !.phase[c] = CASE s.headOutcome[c] = "Success" -> "Accepted"
                         [] s.headOutcome[c] = "Unknown" -> "Unknown"
                         [] OTHER -> "Excluded",
          !.receipt = [t \in Transactions |->
              IF t \in Members(c) /\ s.headOutcome[c] = "Unknown" THEN "Unknown" ELSE @[t]],
          !.fenced = @ \/ s.headOutcome[c] = "Rejected",
          !.unknownEpisode = @ \/ s.headOutcome[c] = "Unknown",
          !.halted = @ \/ s.headOutcome[c] \in {"Unknown", "Rejected"}, !.lastAction = "JoinHead"]

RetireSuccess(localFailure) ==
    /\ s.online /\ Front # 0 /\ s.phase[Front] = "Accepted"
    /\ s.headRequest[Front] = "Joined" /\ localFailure \in BOOLEAN
    /\ LET c == Front IN
       s' = [s EXCEPT !.pipe = Tail(@), !.slotOwner[Slot(c)] = 0, !.phase[c] = "Durable",
          !.projection = 0,
          !.receipt = [t \in Transactions |-> IF t \in Members(c) THEN "Success" ELSE @[t]],
          !.acknowledged = @ \cup Members(c),
          !.installed = IF localFailure THEN @ ELSE s.head,
          !.installedToken = IF localFailure THEN @ ELSE Token(c),
          !.fenced = @ \/ localFailure, !.halted = @ \/ localFailure,
          !.localFailure = @ \/ localFailure, !.lastAction = "RetireSuccess"]

AbandonPending ==
    /\ s.online /\ s.pending # <<>> /\ (s.halted \/ s.fenced)
    /\ s' = [s EXCEPT !.pending = <<>>, !.excluded = @ \cup Pending,
          !.inputOwned = @ \ (Pending \ TxnBorrowed),
          !.fragmentAllocated = @ \ (Pending \ TxnBorrowed),
          !.receipt = [t \in Transactions |-> IF t \in Pending THEN "Failed" ELSE @[t]],
          !.lastAction = "AbandonPending"]

AbandonSuccessors ==
    /\ s.online /\ UnsettledFront
    /\ \E c \in PipeSet \ {Front} : s.phase[c] # "Abandoned"
    /\ s' = [s EXCEPT !.halted = TRUE,
          !.phase = [c \in Cohorts |->
              IF c \in PipeSet \ {Front} THEN "Abandoned" ELSE @[c]],
          !.ready = Remove(@, PipeSet \ {Front}),
          !.abandonedSuccessors = @ \cup (PipeSet \ {Front}),
          !.lastAction = "AbandonSuccessors"]

AbandonSuffix ==
    /\ s.online /\ Front # 0
    /\ (s.phase[Front] \in {"BatchUnknown", "Excluded"} \/ s.fenced \/ s.halted)
    /\ HeadBorrowed = {} /\ ~UnsettledFront
    /\ \A c \in PipeSet : c \notin HeadChain
    /\ \E c \in PipeSet : s.phase[c] # "Abandoned"
    /\ s' = [s EXCEPT !.halted = TRUE, !.ready = <<>>,
          !.projection = IF @ \in PipeSet THEN 0 ELSE @,
          !.phase = [c \in Cohorts |-> IF c \in PipeSet THEN "Abandoned" ELSE @[c]],
          !.lastAction = "AbandonSuffix"]

BeginClose ==
    /\ s.online /\ ~s.draining
    /\ s' = [s EXCEPT !.draining = TRUE, !.lastAction = "BeginClose"]

DrainAbandoned(c) ==
    /\ c \in PipeSet /\ s.phase[c] = "Abandoned"
    /\ c = Front \/ (UnsettledFront /\ s.headPuts[c] = 0)
    /\ s.prepareRequest[BatchWork(c)] \in {"NotStarted", "Joined"}
    /\ s.batchRequest[c] \in {"NotStarted", "Joined"}
    /\ s.headRequest[c] \in {"NotStarted", "Joined"}
    /\ s' = [s EXCEPT !.pipe = Remove(@, {c}), !.slotOwner[Slot(c)] = 0, !.phase[c] = "Excluded",
          !.projection = IF @ = c THEN 0 ELSE @,
          !.excluded = @ \cup Members(c),
          !.fragmentAllocated = @ \ Members(c),
          !.receipt = [t \in Transactions |->
              IF t \in Members(c) /\ @[t] = "Pending" THEN "Failed" ELSE @[t]],
          !.lastAction = "DrainAbandoned"]

ObserveFrontResolution(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \in s.delivered \ s.dropped
    /\ s.admitted = s.collected
    /\ MemberCohort(t) = Front /\ UnknownFront /\ Front \in HeadChain
    /\ s.resolvingMember[Front] = 0 /\ SuccessorsDrained
    /\ s' = [s EXCEPT !.phase[Front] = "ResolutionReady",
          !.resolutionToken[Front] = s.headToken, !.resolvingMember[Front] = t,
          !.fenced = @ \/ s.rival, !.halted = @ \/ s.rival,
          !.lastAction = "ObserveFrontResolution"]

FinishFrontResolution(localFailure) ==
    /\ s.online /\ ResolutionReadyFront /\ localFailure \in BOOLEAN /\ SuccessorsDrained
    /\ LET c == Front
           t == s.resolvingMember[c]
           tokenChanged == s.headToken # s.resolutionToken[c]
       IN /\ t \in s.delivered \ s.dropped /\ s.receipt[t] = "Unknown"
          /\ s' = [s EXCEPT !.pipe = IF localFailure THEN @ ELSE Tail(@),
               !.slotOwner[Slot(c)] = IF localFailure THEN @ ELSE 0,
               !.phase[c] = IF localFailure THEN "Unknown" ELSE "Durable",
               !.resolvingMember[c] = 0,
               !.receipt[t] = IF localFailure THEN @ ELSE "Success",
               !.acknowledged = IF localFailure THEN @ ELSE @ \cup {t},
               !.resolved = IF localFailure THEN @ ELSE @ \cup {c},
               !.installed = IF localFailure THEN @ ELSE s.head,
               !.installedToken = IF localFailure THEN @ ELSE s.resolutionToken[c],
               !.fenced = @ \/ localFailure \/ s.rival \/ tokenChanged,
               !.halted = TRUE,
               !.localFailure = @ \/ localFailure,
               !.lastAction = "FinishFrontResolution"]

ResolveDetachedMember(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \in s.delivered \ s.dropped
    /\ s.admitted = s.collected
    /\ MemberCohort(t) \in InstalledChain /\ MemberCohort(t) \notin PipeSet
    /\ s' = [s EXCEPT !.receipt[t] = "Success", !.acknowledged = @ \cup {t},
          !.resolved = @ \cup {MemberCohort(t)}, !.fenced = @ \/ s.rival,
          !.halted = @ \/ s.rival, !.lastAction = "ResolveDetachedMember"]

ResolveRejected(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \in s.delivered \ s.dropped
    /\ s.admitted = s.collected
    /\ MemberCohort(t) \notin HeadChain /\ s.headToken = "Rival"
    /\ s.headRequest[MemberCohort(t)] = "Joined"
    /\ s.casToken[MemberCohort(t)] # s.headToken
    /\ MemberCohort(t) \notin PipeSet \/ (MemberCohort(t) = Front /\ SuccessorsDrained)
    /\ s' = [s EXCEPT !.receipt[t] = "Failed", !.fenced = TRUE, !.halted = TRUE,
          !.phase[MemberCohort(t)] = "Excluded", !.lastAction = "ResolveRejected"]

DetachUnknown ==
    /\ s.draining /\ UnknownFront /\ s.headRequest[Front] = "Joined" /\ SuccessorsDrained
    /\ LET c == Front IN
       s' = [s EXCEPT !.pipe = Tail(@), !.slotOwner[Slot(c)] = 0, !.lastAction = "DetachUnknown"]

ExportAuthority(t) ==
    /\ s.receipt[t] = "Unknown" /\ t \in s.delivered \ s.dropped /\ t \notin s.exported
    /\ s' = [s EXCEPT !.exported = @ \cup {t}, !.lastAction = "ExportAuthority"]

ImportAuthority(t) ==
    /\ s.online /\ t \in s.exported /\ t \in s.dropped
    /\ s' = [s EXCEPT !.dropped = @ \ {t}, !.receipt[t] = "Unknown",
                      !.imported = @ \cup {t}, !.lastAction = "ImportAuthority"]

DropReceipt(t) ==
    /\ t \in s.delivered \ s.dropped /\ t \notin ResolvingMembers
    /\ s.receipt[t] \in {"Unknown", "Success", "Failed"}
    /\ s' = [s EXCEPT !.dropped = @ \cup {t}, !.receipt[t] = "None", !.lastAction = "DropReceipt"]

CollectImage(c) ==
    /\ c \in s.allocated /\ c \notin Retained
    /\ c \notin BatchBorrowed \cup HeadBorrowed \cup BatchPreparing
    /\ s' = [s EXCEPT !.allocated = @ \ {c}, !.lastAction = "CollectImage"]

Close ==
    /\ s.online /\ s.draining /\ s.pipe = <<>> /\ s.pending = <<>> /\ s.ready = <<>> /\ NoBorrow
    /\ s.admitted = s.collected /\ s.projection = 0
    /\ s' = [s EXCEPT !.online = FALSE, !.closed = TRUE, !.lastAction = "Close"]

CrashAfterReturn ==
    /\ s.pipe = <<>> /\ s.pending = <<>> /\ s.ready = <<>> /\ NoBorrow /\ ~s.crashed
    /\ s.admitted = s.collected /\ s.admitted = s.delivered /\ s.projection = 0
    \* This crash lane starts only after every admitted result was publicly delivered.
    /\ s' = [s EXCEPT !.online = FALSE, !.halted = TRUE, !.dropped = Transactions,
          !.crashed = TRUE,
          !.receipt = [t \in Transactions |-> "None"], !.lastAction = "CrashAfterReturn"]

Reopen ==
    /\ ~s.online /\ ~s.reopened
    /\ s' = [s EXCEPT !.online = TRUE, !.installed = s.head, !.installedToken = s.headToken,
                      !.halted = TRUE, !.reopened = TRUE, !.lastAction = "Reopen"]

PipelineNext ==
    \/ Freeze \/ Tick \/ StartHead \/ RivalHead \/ AbandonSuffix \/ AbandonSuccessors
    \/ AbandonPending \/ BeginClose
    \/ DetachUnknown \/ Close \/ CrashAfterReturn \/ Reopen
    \/ \E failure \in BOOLEAN : RetireSuccess(failure) \/ FinishFrontResolution(failure)
    \/ \E c \in Cohorts : FailPreparedFront(c) \/ StartBatch(c) \/ StoreBatch(c) \/ JoinBatch(c)
         \/ ObserveBatch(c) \/ ApplyHead(c) \/ JoinHead(c) \/ CollectImage(c) \/ IgnoreStaleCompletion(c)
         \/ IgnoreStalePrepareCompletion(c) \/ DrainAbandoned(c)
    \/ \E c \in Cohorts, success \in BOOLEAN : ValidateFront(c, success)
    \/ \E w \in PrepareWork : StartPrepare(w) \/ JoinPrepare(w)
    \/ \E w \in PrepareWork, outcome \in {"Success", "Failed"} : CompletePrepare(w, outcome)
    \/ \E c \in Cohorts, outcome \in {"Success", "Absent", "Unknown"} : CompleteBatch(c, outcome)
    \/ \E c \in Cohorts, outcome \in {"Success", "Rejected", "Unknown"} : CompleteHead(c, outcome)
    \/ \E t \in Transactions : RequestCancellation(t) \/ CollectTerminal(t) \/ DeliverReceipt(t)
         \/ ObserveFrontResolution(t)
         \/ ResolveDetachedMember(t) \/ ResolveRejected(t) \/ RejectBeforeAdmission(t)
         \/ WaitForPredecessor(t) \/ RejectQueuedConflict(t) \/ ObserveBackpressure(t)
    \/ \E t \in Transactions, snapshot \in 0..4 : Admit(t, snapshot)

AuthorityLifecycleNext ==
    \E t \in Transactions : ExportAuthority(t) \/ ImportAuthority(t) \/ DropReceipt(t)
         \/ DiscardCollected(t)

Next == PipelineNext \/ AuthorityLifecycleNext

(***************************************************************************
SafetySpec exhausts the physical pipeline and resolution state graph. The
full Spec additionally includes export/import/drop and undelivered discard.
A focused lifecycle module includes these authority interleavings. The proof
kernel states its narrower abstraction boundary. These sources have not yet
been requalified after adding admission, preparation, delivery and validation.
***************************************************************************)
Spec == Init /\ [][Next]_vars
SafetySpec == Init /\ [][PipelineNext]_vars

TypeOK ==
    /\ ConstantsOK /\ s.pipe \in Seq(Cohorts) /\ s.next \in 1..5
    /\ s.pending \in Seq(Transactions) /\ s.ready \in Seq(Cohorts)
    /\ s.admission \in Seq(Transactions) /\ s.unknownEpisode \in BOOLEAN
    /\ s.admitted \subseteq Transactions /\ s.inputOwned \subseteq Transactions
    /\ s.collected \subseteq s.admitted /\ s.delivered \subseteq s.collected
    /\ s.prepareFailed \subseteq Frozen /\ s.validated \subseteq Frozen
    /\ s.preHeadFailed \subseteq Frozen /\ s.projection \in Cohorts \cup {0}
    /\ s.validationHead \in [Cohorts -> 0..4] /\ s.validationToken \in [Cohorts -> Tokens]
    /\ s.fragmentAllocated \subseteq Transactions /\ s.fragment \in [Transactions -> 0..4]
    /\ s.snapshot \in [Transactions -> 0..4] /\ s.age \in [Transactions -> 0..MaxWait]
    /\ s.prepareRequest \in [PrepareWork -> RequestStates]
    /\ s.prepareOutcome \in [PrepareWork -> {"None", "Success", "Failed"}]
    /\ s.memberCohort \in [Transactions -> Cohorts \cup {0}]
    /\ s.memberSequence \in [Transactions -> 0..4]
    /\ s.receiptBatch \in [Transactions -> Transactions \cup {0}]
    /\ s.conflictWaited \subseteq Transactions /\ s.conflictRejected \subseteq Transactions
    /\ s.conflictBasis \in [Transactions -> Transactions \cup {0}]
    /\ s.abandonedSuccessors \subseteq Cohorts
    /\ s.overlappedPrepare \in BOOLEAN /\ s.backpressured \in BOOLEAN
    /\ s.stalePrepareIgnored \in BOOLEAN
    /\ s.widthTail \in BOOLEAN /\ s.byteTail \in BOOLEAN /\ s.waitTail \in BOOLEAN
    /\ s.closeTail \in BOOLEAN /\ s.oversizedTail \in BOOLEAN
    /\ s.phase \in [Cohorts -> Phases]
    /\ s.image \in [Cohorts -> ImageType] /\ s.frozenImage \in [Cohorts -> ImageType]
    /\ s.validationPrefix \in [Cohorts -> SUBSET Cohorts]
    /\ s.batchRequest \in [Cohorts -> RequestStates] /\ s.headRequest \in [Cohorts -> RequestStates]
    /\ s.batchOutcome \in [Cohorts -> {"None", "Success", "Absent", "Unknown"}]
    /\ s.headOutcome \in [Cohorts -> {"None", "Success", "Rejected", "Unknown"}]
    /\ s.headDecision \in [Cohorts -> {"Pending", "Accepted", "NotEntered"}]
    /\ s.receipt \in [Transactions -> ReceiptStates]
    /\ s.resolvingMember \in [Cohorts -> Transactions \cup {0}]
    /\ s.head \in Cohorts \cup {0} /\ s.installed \in Cohorts \cup {0}
    /\ s.headToken \in Tokens /\ s.installedToken \in Tokens /\ s.casToken \in [Cohorts -> Tokens]
    /\ s.resolutionToken \in [Cohorts -> Tokens]
    /\ s.stored \subseteq Frozen /\ s.published \subseteq Frozen /\ s.allocated \subseteq Frozen
    /\ s.acknowledged \subseteq Transactions /\ s.excluded \subseteq Transactions
    /\ s.dropped \subseteq Transactions /\ s.exported \subseteq Transactions
    /\ s.imported \subseteq Transactions /\ s.cancelRequested \subseteq Transactions
    /\ s.resolved \subseteq Cohorts /\ s.resolutionWrites \in Nat
    /\ s.slotOwner \in [Slots -> Cohorts \cup {0}]
    /\ s.batchPuts \in [Cohorts -> 0..1] /\ s.headPuts \in [Cohorts -> 0..1]
    /\ s.online \in BOOLEAN /\ s.draining \in BOOLEAN /\ s.halted \in BOOLEAN
    /\ s.fenced \in BOOLEAN /\ s.rival \in BOOLEAN /\ s.outOfOrderBatch \in BOOLEAN
    /\ s.overlappedBatch \in BOOLEAN /\ s.reusedSlot \in BOOLEAN /\ s.localFailure \in BOOLEAN
    /\ s.closed \in BOOLEAN /\ s.reopened \in BOOLEAN /\ s.staleIgnored \in BOOLEAN
    /\ s.crashed \in BOOLEAN

FrozenIdentity ==
    \A c \in Frozen :
      /\ s.image[c] = s.frozenImage[c]
      /\ Len(s.image[c].members) \in 1..MaxWidth
      /\ Cardinality(Members(c)) = Len(s.image[c].members)
      /\ s.image[c].batch = Head(s.image[c].members)
      /\ s.image[c].previous \in 0..(c - 1)
      /\ s.image[c].first = (IF s.image[c].previous = 0 THEN 1
                            ELSE s.image[s.image[c].previous].last + 1)
      /\ s.image[c].last = s.image[c].first + Len(s.image[c].members) - 1
      /\ s.image[c].bytes = 1 + SumBytes(Members(c))
      /\ Len(s.image[c].members) = 1 \/ s.image[c].bytes <= MaxBytes

AdmissionOrder ==
    /\ Cardinality(s.admitted) = Len(s.admission) /\ AsSet(s.admission) = s.admitted
    /\ Cardinality(Pending) = Len(s.pending) /\ Pending \subseteq s.admitted
    /\ Pending \cap FrozenMembers = {} /\ FrozenMembers \subseteq s.admitted
    /\ \A c, d \in Frozen : c # d => Members(c) \cap Members(d) = {}
    /\ \A t \in Transactions : MemberCohort(t) = 0 <=> t \notin FrozenMembers
    /\ \A i, j \in 1..Len(s.pending) :
         i < j => AdmissionPosition(s.pending[i]) < AdmissionPosition(s.pending[j])
    /\ \A t \in FrozenMembers, other \in Pending : AdmissionPosition(t) < AdmissionPosition(other)
    /\ \A t, other \in FrozenMembers :
         s.memberSequence[t] < s.memberSequence[other] => AdmissionPosition(t) < AdmissionPosition(other)
MemberReceiptBinding ==
    \A c \in Frozen : \A i \in 1..Len(s.image[c].members) :
      LET t == s.image[c].members[i] IN
        /\ MemberCohort(t) = c /\ s.receiptBatch[t] = s.image[c].batch
        /\ s.memberSequence[t] = s.image[c].first + i - 1
PreparedBeforeFreeze ==
    \A c \in Frozen : Members(c) \subseteq PreparedTxns /\ s.image[c].fragments = s.image[c].members
ReadyQueueSafety ==
    /\ Cardinality(ReadySet) = Len(s.ready) /\ ReadySet \subseteq PipeSet \cap Sealed \cap s.allocated
    /\ \A c \in ReadySet : s.phase[c] = "BatchReady" /\ s.batchRequest[c] = "NotStarted"
BatchRequiresSeal == \A c \in Cohorts : s.batchPuts[c] = 1 => c \in Sealed
ConflictSafety ==
    /\ s.conflictRejected \subseteq s.excluded
    /\ \A t \in s.conflictRejected : MemberCohort(t) = 0
    /\ \A t \in s.conflictRejected :
         /\ s.conflictBasis[t] \in UNION {Members(c) : c \in InstalledChain}
         /\ <<t, s.conflictBasis[t]>> \in ConflictPairs
         /\ s.memberSequence[s.conflictBasis[t]] > s.snapshot[t]
    /\ \A c \in Frozen : \A i \in 1..Len(s.image[c].members) :
         ~Conflict(s.image[c].members[i], AsSet(SubSeq(s.image[c].members, 1, i - 1)))
    /\ \A c \in Frozen : \A t \in Members(c), d \in Prefix(c) : \A other \in Members(d) :
         s.memberSequence[other] > s.snapshot[t] => <<t, other>> \notin ConflictPairs

ValidationPrefix == \A c \in Frozen : s.validationPrefix[c] = Prefix(c)
OrderedHead ==
    /\ s.published = HeadChain /\ HeadChain \subseteq s.stored
    /\ \A c \in Cohorts : s.headPuts[c] = 1 => Prefix(c) \subseteq s.published
    /\ \A c \in HeadBorrowed : c = Front
NoPrematureSuccess ==
    /\ s.acknowledged \subseteq HeadMembers /\ s.excluded \cap HeadMembers = {}
    /\ \A t \in Transactions :
         /\ (s.receipt[t] = "Success" => t \in HeadMembers)
         /\ (s.receipt[t] = "Failed" => t \notin HeadMembers)
UnknownBarrier ==
    /\ s.unknownEpisode => s.halted
    /\ UnsettledFront => s.halted /\ \A c \in PipeSet \ {Front} : s.headPuts[c] = 0
    /\ ResolutionReadyFront => SuccessorsDrained
    /\ \A c \in s.abandonedSuccessors : s.headPuts[c] = 0
NoReplay == s.resolutionWrites = 0 /\
    \A c \in Cohorts : s.batchPuts[c] <= 1 /\ s.headPuts[c] <= 1
ResolutionBinding ==
    ResolutionReadyFront =>
      /\ s.resolutionToken[Front] \in {Token(Front), "Rival"}
      /\ (s.resolutionToken[Front] # s.headToken => s.rival)
NoPrematureResolutionSuccess ==
    UnsettledFront => \A t \in Members(Front) : s.receipt[t] # "Success"
ResolutionInstalled == s.resolved \subseteq InstalledChain
ResolutionOwnership ==
    ResolutionReadyFront =>
      /\ s.resolvingMember[Front] \in Members(Front)
      /\ s.resolvingMember[Front] \notin s.dropped
      /\ s.receipt[s.resolvingMember[Front]] = "Unknown"
      /\ s.resolvingMember[Front] \in s.delivered
Ownership ==
    /\ Cardinality(PipeSet) = Len(s.pipe)
    /\ PipeSet \subseteq s.allocated /\ Retained \subseteq s.allocated
    /\ BatchBorrowed \cup HeadBorrowed \subseteq PipeSet
    /\ Cardinality(HeadBorrowed) <= 1
    /\ \A c \in PipeSet : s.slotOwner[Slot(c)] = c
    /\ \A slot \in Slots : s.slotOwner[slot] # 0 => s.slotOwner[slot] \in PipeSet
    /\ (~s.online => s.pipe = <<>> /\ s.pending = <<>> /\ s.ready = <<>> /\ NoBorrow)
PreparationOwnership ==
    /\ TxnBorrowed \subseteq s.inputOwned \cap s.fragmentAllocated
    /\ BatchPreparing \subseteq PipeSet \cap s.allocated
    /\ \A c \in BatchPreparing : Members(c) \subseteq s.fragmentAllocated
    /\ s.inputOwned \subseteq Pending \cup TxnBorrowed
CompletionOwnership ==
    /\ s.collected \cap Pending = {} /\ s.collected \cap TxnBorrowed = {}
    /\ \A t \in s.collected : s.receipt[t] # "Pending"
    /\ s.exported \subseteq s.delivered
    /\ \A t \in s.collected : MemberCohort(t) \notin BatchPreparing \cup BatchBorrowed \cup HeadBorrowed
    /\ ~s.online => s.admitted = s.collected
    /\ ResolutionReadyFront => s.admitted = s.collected

\* Durable validation history cannot disappear when the mutable projection is released.
HeadValidation ==
    /\ s.validated \cap (s.prepareFailed \cup s.preHeadFailed) = {}
    /\ \A c \in s.validated : s.validationHead[c] = s.image[c].previous
    /\ \A c \in Cohorts : s.headPuts[c] = 1 =>
         c \in s.validated /\ s.casToken[c] = s.validationToken[c]
ProjectionOwnership ==
    /\ s.projection # 0 =>
         /\ s.projection = Front /\ Front \in s.validated \cap PipeSet
         /\ s.phase[Front] \in {"HeadReady", "HeadPending", "Accepted"}
         /\ s.validationHead[Front] = s.installed
         /\ s.validationToken[Front] = s.installedToken
    /\ \A c \in Cohorts : s.phase[c] \in {"HeadReady", "HeadPending", "Accepted"} =>
         s.projection = c
    /\ ~s.online => s.projection = 0
PreHeadFailureSafety ==
    \A c \in s.preHeadFailed \cup s.prepareFailed :
      /\ s.headPuts[c] = 0 /\ c \notin s.published
      /\ \A t \in Members(c) : s.receipt[t] \notin {"Success", "Unknown"}
ReceiptDelivery ==
    /\ s.delivered \subseteq s.collected /\ s.exported \subseteq s.delivered
    /\ ResolvingMembers \subseteq s.delivered
    /\ s.crashed => s.admitted = s.delivered

ResourceBounds ==
    /\ Cardinality(LiveTransactions) <= Depth /\ Cardinality(PrepareBorrowed) <= PrepareCapacity
    /\ Len(s.pipe) <= PipelineCapacity /\ Len(s.ready) <= PipelineCapacity
    /\ ResidentBytes <= ReservedBytes /\ ReservedBytes <= ByteCapacity
Safety == TypeOK /\ FrozenIdentity /\ AdmissionOrder /\ MemberReceiptBinding
          /\ HeadValidation /\ ProjectionOwnership /\ PreHeadFailureSafety /\ ReceiptDelivery
          /\ PreparedBeforeFreeze /\ ReadyQueueSafety /\ BatchRequiresSeal /\ ConflictSafety
          /\ PreparationOwnership /\ CompletionOwnership /\ ResourceBounds /\ ValidationPrefix /\ OrderedHead
          /\ NoPrematureSuccess /\ UnknownBarrier /\ NoReplay
          /\ ResolutionBinding /\ NoPrematureResolutionSuccess
          /\ ResolutionInstalled /\ ResolutionOwnership /\ Ownership

Trace == [action |-> s.lastAction, pending |-> s.pending, ready |-> s.ready,
          pipe |-> s.pipe, phase |-> s.phase, prepareRequest |-> s.prepareRequest,
          fragment |-> s.fragment, memberCohort |-> s.memberCohort,
          collected |-> s.collected, delivered |-> s.delivered, completionSlots |-> LiveTransactions,
          projection |-> s.projection, validated |-> s.validated, prepareFailed |-> s.prepareFailed,
          validationHead |-> s.validationHead, validationToken |-> s.validationToken,
          preHeadFailed |-> s.preHeadFailed,
          memberSequence |-> s.memberSequence, receiptBatch |-> s.receiptBatch,
          residentBytes |-> ResidentBytes, reservedBytes |-> ReservedBytes,
          prepareBorrowed |-> PrepareBorrowed,
          head |-> s.head, installed |-> s.installed, stored |-> s.stored,
          headToken |-> s.headToken, installedToken |-> s.installedToken,
          resolutionToken |-> s.resolutionToken, resolvingMember |-> s.resolvingMember,
          receipt |-> s.receipt, batchPuts |-> s.batchPuts, headPuts |-> s.headPuts,
          allocated |-> s.allocated, borrowed |-> BatchBorrowed \cup HeadBorrowed]

StateView == [s EXCEPT !.lastAction = "Init"]
=============================================================================
