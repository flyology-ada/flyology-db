----------- MODULE PipelinedAdaptiveAggregateCommitCoalescing -----------
EXTENDS FiniteSets, Naturals, Sequences, TLC

(***************************************************************************
Source foundation only: three physical cohorts exercise reuse of two slots.
These numbers and the two members per cohort are finite test geometry, not
runtime defaults. Adaptive admission, byte/wait selection, conflict detection,
member grouping and immutable encoding remain the preceding layer's contract.
Freeze records its required validation prefix, including earlier frozen work.

Only batch PUTs overlap. HEAD, local installation, and terminal availability
retire in order; callers may collect already-terminal receipts in any order.
Logical predecessor fields freeze early; the opaque CAS token binds only when
the front cohort starts HEAD. A token is compared for equality, never ordered.
Same-receipt resolution retains its exact observed token through local install;
a later token cannot be borrowed as the predecessor of the next cohort.

Unknown A holds B. Close abandons every not-yet-HEAD cohort, joins provider
requests, detaches A's independent unknown authority, then drains B. An orphan
is not removed, rebased, resequenced, or replayed. A failed predecessor ends
this finite pipeline episode; starting a new episode is outside this model.
Cancellation after admission is a request to drain, not publication rollback.
No deadline policy is introduced. Crash is modeled only after provider joins
at the returned-authority boundary, not an arbitrary kill inside Commit.
No fairness, liveness, byte-format, provider, Ada refinement, or performance
claim follows from this source. Recovery discovers only the authoritative HEAD.
***************************************************************************)

Cohorts == 1..3
Slots == 1..2
Transactions == 1..6
Members(c) == {2 * c - 1, 2 * c}
MemberCohort(t) == (t + 1) \div 2
Slot(c) == ((c - 1) % 2) + 1
Tokens == {"Initial", "A", "B", "C", "Rival"}
Token(c) == CASE c = 1 -> "A" [] c = 2 -> "B" [] OTHER -> "C"
AsSet(q) == {q[i] : i \in 1..Len(q)}
EmptyImage == [previous |-> 0, first |-> 0, last |-> 0, members |-> {}]
ImageType == [previous : 0..3, first : 0..6, last : 0..6, members : SUBSET Transactions]
RequestStates == {"NotStarted", "InFlight", "Completed", "Joined"}
Phases == {"Unused", "Frozen", "BatchUnknown", "Ready", "HeadPending",
           "Accepted", "Unknown", "ResolutionReady", "Durable", "Abandoned", "Excluded"}
ReceiptStates == {"None", "Pending", "Unknown", "Success", "Failed"}

VARIABLE s
vars == <<s>>

Front == IF Len(s.pipe) = 0 THEN 0 ELSE Head(s.pipe)
TailCohort == IF Len(s.pipe) = 0 THEN s.head ELSE s.pipe[Len(s.pipe)]
Frozen == 1..(s.next - 1)
PipeSet == AsSet(s.pipe)
RECURSIVE Chain(_, _)
Chain(c, fuel) ==
    IF c = 0 \/ fuel = 0 THEN {}
    ELSE {c} \cup Chain(s.image[c].previous, fuel - 1)
HeadChain == Chain(s.head, 3)
InstalledChain == Chain(s.installed, 3)
Prefix(c) == Chain(s.image[c].previous, 3)
HeadMembers == UNION {Members(c) : c \in HeadChain}
BatchBorrowed == {c \in Cohorts : s.batchRequest[c] \in {"InFlight", "Completed"}}
HeadBorrowed == {c \in Cohorts : s.headRequest[c] \in {"InFlight", "Completed"}}
ReceiptImages == {MemberCohort(t) : t \in Transactions \ s.dropped}
ExportImages == {MemberCohort(t) : t \in s.exported}
ResolvingMembers == {s.resolvingMember[c] : c \in Cohorts} \ {0}
Retained == PipeSet \cup ReceiptImages \cup ExportImages
UnknownFront == Front # 0 /\ s.phase[Front] = "Unknown"
ResolutionReadyFront == Front # 0 /\ s.phase[Front] = "ResolutionReady"
UnsettledFront == UnknownFront \/ ResolutionReadyFront
NoBorrow == BatchBorrowed = {} /\ HeadBorrowed = {}

Init ==
    s = [pipe |-> <<>>, next |-> 1, image |-> [c \in Cohorts |-> EmptyImage],
         frozenImage |-> [c \in Cohorts |-> EmptyImage],
         validated |-> [c \in Cohorts |-> {}],
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

Freeze ==
    /\ s.online /\ ~s.draining /\ ~s.halted /\ ~s.fenced /\ ~UnsettledFront
    /\ s.next \in Cohorts /\ Len(s.pipe) < 2 /\ s.slotOwner[Slot(s.next)] = 0
    /\ LET c == s.next
           predecessor == TailCohort
           last == IF predecessor = 0 THEN 0 ELSE s.image[predecessor].last
           image == [previous |-> predecessor, first |-> last + 1,
                     last |-> last + 2, members |-> Members(c)]
       IN s' = [s EXCEPT !.pipe = Append(@, c), !.next = c + 1,
          !.image[c] = image, !.frozenImage[c] = image,
          !.validated[c] = HeadChain \cup PipeSet,
          !.slotOwner[Slot(c)] = c, !.allocated = @ \cup {c}, !.phase[c] = "Frozen",
          !.receipt = [t \in Transactions |-> IF t \in Members(c) THEN "Pending" ELSE @[t]],
          !.dropped = @ \ Members(c), !.reusedSlot = @ \/ c = 3, !.lastAction = "Freeze"]

RequestCancellation(t) ==
    /\ s.online /\ t \in Transactions /\ s.receipt[t] = "Pending"
    /\ s' = [s EXCEPT !.cancelRequested = @ \cup {t}, !.lastAction = "RequestCancellation"]

StartBatch(c) ==
    /\ s.online /\ ~s.fenced /\ ~s.halted /\ ~s.draining
    /\ c \in PipeSet /\ s.phase[c] = "Frozen"
    /\ s.batchRequest[c] = "NotStarted" /\ s.batchPuts[c] = 0
    /\ s' = [s EXCEPT !.batchRequest[c] = "InFlight", !.batchPuts[c] = 1,
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
    /\ s' = [s EXCEPT !.staleIgnored = TRUE, !.lastAction = "IgnoreStaleCompletion"]

ObserveBatch(c) ==
    /\ s.online /\ c \in PipeSet /\ s.phase[c] = "BatchUnknown" /\ c \in s.stored
    /\ s' = [s EXCEPT !.phase[c] = "Ready", !.lastAction = "ObserveBatch"]

StartHead ==
    /\ s.online /\ ~s.fenced /\ ~s.draining /\ ~s.halted /\ Front # 0
    /\ s.phase[Front] = "Ready" /\ Front \in s.stored /\ HeadBorrowed = {}
    /\ s.image[Front].previous = s.head /\ s.installed = s.head
    /\ s.headPuts[Front] = 0 /\ s.headRequest[Front] = "NotStarted"
    /\ s' = [s EXCEPT !.headRequest[Front] = "InFlight", !.headPuts[Front] = 1,
          !.casToken[Front] = s.installedToken, !.phase[Front] = "HeadPending",
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
          !.phase[c] = CASE s.headOutcome[c] = "Success" -> "Accepted"
                         [] s.headOutcome[c] = "Unknown" -> "Unknown"
                         [] OTHER -> "Excluded",
          !.receipt = [t \in Transactions |->
              IF t \in Members(c) /\ s.headOutcome[c] = "Unknown" THEN "Unknown" ELSE @[t]],
          !.fenced = @ \/ s.headOutcome[c] = "Rejected", !.lastAction = "JoinHead"]

RetireSuccess(localFailure) ==
    /\ s.online /\ Front # 0 /\ s.phase[Front] = "Accepted"
    /\ s.headRequest[Front] = "Joined" /\ localFailure \in BOOLEAN
    /\ LET c == Front IN
       s' = [s EXCEPT !.pipe = Tail(@), !.slotOwner[Slot(c)] = 0, !.phase[c] = "Durable",
          !.receipt = [t \in Transactions |-> IF t \in Members(c) THEN "Success" ELSE @[t]],
          !.acknowledged = @ \cup Members(c),
          !.installed = IF localFailure THEN @ ELSE s.head,
          !.installedToken = IF localFailure THEN @ ELSE Token(c),
          !.fenced = @ \/ localFailure, !.halted = @ \/ localFailure,
          !.localFailure = @ \/ localFailure, !.lastAction = "RetireSuccess"]

AbandonSuffix ==
    /\ s.online /\ Front # 0
    /\ (s.phase[Front] \in {"BatchUnknown", "Excluded"} \/ s.fenced \/ s.halted)
    /\ HeadBorrowed = {} /\ ~UnsettledFront
    /\ \A c \in PipeSet : c \notin HeadChain
    /\ s' = [s EXCEPT !.halted = TRUE,
          !.phase = [c \in Cohorts |-> IF c \in PipeSet THEN "Abandoned" ELSE @[c]],
          !.lastAction = "AbandonSuffix"]

BeginClose ==
    /\ s.online /\ ~s.draining
    /\ s' = [s EXCEPT !.draining = TRUE, !.halted = TRUE,
          !.phase = [c \in Cohorts |->
              IF c \in PipeSet /\ s.headPuts[c] = 0 THEN "Abandoned" ELSE @[c]],
          !.lastAction = "BeginClose"]

DrainAbandoned ==
    /\ Front # 0 /\ s.phase[Front] = "Abandoned"
    /\ s.batchRequest[Front] \in {"NotStarted", "Joined"}
    /\ s.headRequest[Front] \in {"NotStarted", "Joined"}
    /\ LET c == Front IN
       s' = [s EXCEPT !.pipe = Tail(@), !.slotOwner[Slot(c)] = 0, !.phase[c] = "Excluded",
          !.excluded = @ \cup Members(c),
          !.receipt = [t \in Transactions |->
              IF t \in Members(c) /\ @[t] = "Pending" THEN "Failed" ELSE @[t]],
          !.lastAction = "DrainAbandoned"]

ObserveFrontResolution(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \notin s.dropped
    /\ MemberCohort(t) = Front /\ UnknownFront /\ Front \in HeadChain
    /\ s.resolvingMember[Front] = 0
    /\ s' = [s EXCEPT !.phase[Front] = "ResolutionReady",
          !.resolutionToken[Front] = s.headToken, !.resolvingMember[Front] = t,
          !.fenced = @ \/ s.rival, !.halted = @ \/ s.rival,
          !.lastAction = "ObserveFrontResolution"]

FinishFrontResolution(localFailure) ==
    /\ s.online /\ ResolutionReadyFront /\ localFailure \in BOOLEAN
    /\ LET c == Front
           t == s.resolvingMember[c]
           tokenChanged == s.headToken # s.resolutionToken[c]
       IN /\ t \in Transactions /\ s.receipt[t] = "Unknown"
          /\ s' = [s EXCEPT !.pipe = IF localFailure THEN @ ELSE Tail(@),
               !.slotOwner[Slot(c)] = IF localFailure THEN @ ELSE 0,
               !.phase[c] = IF localFailure THEN "Unknown" ELSE "Durable",
               !.resolvingMember[c] = 0,
               !.receipt[t] = IF localFailure THEN @ ELSE "Success",
               !.acknowledged = IF localFailure THEN @ ELSE @ \cup {t},
               !.resolved = IF localFailure THEN @ ELSE @ \cup {c},
               !.installed = IF localFailure THEN @ ELSE s.head,
               !.installedToken = IF localFailure THEN @ ELSE s.resolutionToken[c],
               !.fenced = IF localFailure THEN TRUE ELSE s.rival \/ tokenChanged,
               !.halted = IF localFailure THEN TRUE ELSE s.rival \/ tokenChanged,
               !.localFailure = @ \/ localFailure,
               !.lastAction = "FinishFrontResolution"]

ResolveDetachedMember(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \notin s.dropped
    /\ MemberCohort(t) \in InstalledChain /\ MemberCohort(t) \notin PipeSet
    /\ s' = [s EXCEPT !.receipt[t] = "Success", !.acknowledged = @ \cup {t},
          !.resolved = @ \cup {MemberCohort(t)}, !.fenced = @ \/ s.rival,
          !.halted = @ \/ s.rival, !.lastAction = "ResolveDetachedMember"]

ResolveRejected(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown" /\ t \notin s.dropped
    /\ MemberCohort(t) \notin HeadChain /\ s.headToken = "Rival"
    /\ s.headRequest[MemberCohort(t)] = "Joined"
    /\ s.casToken[MemberCohort(t)] # s.headToken
    /\ s' = [s EXCEPT !.receipt[t] = "Failed", !.fenced = TRUE, !.halted = TRUE,
          !.phase[MemberCohort(t)] = "Excluded", !.lastAction = "ResolveRejected"]

DetachUnknown ==
    /\ s.draining /\ UnknownFront /\ s.headRequest[Front] = "Joined"
    /\ LET c == Front IN
       s' = [s EXCEPT !.pipe = Tail(@), !.slotOwner[Slot(c)] = 0, !.lastAction = "DetachUnknown"]

ExportAuthority(t) ==
    /\ s.receipt[t] = "Unknown" /\ t \notin s.dropped
    /\ s' = [s EXCEPT !.exported = @ \cup {t}, !.lastAction = "ExportAuthority"]

ImportAuthority(t) ==
    /\ s.online /\ t \in s.exported /\ t \in s.dropped
    /\ s' = [s EXCEPT !.dropped = @ \ {t}, !.receipt[t] = "Unknown",
                      !.imported = @ \cup {t}, !.lastAction = "ImportAuthority"]

DropReceipt(t) ==
    /\ t \notin s.dropped /\ t \notin ResolvingMembers
    /\ s.receipt[t] \in {"Unknown", "Success", "Failed"}
    /\ s' = [s EXCEPT !.dropped = @ \cup {t}, !.receipt[t] = "None", !.lastAction = "DropReceipt"]

CollectImage(c) ==
    /\ c \in s.allocated /\ c \notin Retained /\ c \notin BatchBorrowed \cup HeadBorrowed
    /\ s' = [s EXCEPT !.allocated = @ \ {c}, !.lastAction = "CollectImage"]

Close ==
    /\ s.online /\ s.draining /\ s.pipe = <<>> /\ NoBorrow
    /\ s' = [s EXCEPT !.online = FALSE, !.closed = TRUE, !.lastAction = "Close"]

CrashAfterReturn ==
    /\ s.pipe = <<>> /\ NoBorrow
    /\ s' = [s EXCEPT !.online = FALSE, !.halted = TRUE, !.dropped = Transactions,
          !.crashed = TRUE,
          !.receipt = [t \in Transactions |-> "None"], !.lastAction = "CrashAfterReturn"]

Reopen ==
    /\ ~s.online
    /\ s' = [s EXCEPT !.online = TRUE, !.installed = s.head, !.installedToken = s.headToken,
                      !.reopened = TRUE, !.lastAction = "Reopen"]

PipelineNext ==
    \/ Freeze \/ StartHead \/ RivalHead \/ AbandonSuffix \/ BeginClose \/ DrainAbandoned
    \/ DetachUnknown \/ Close \/ CrashAfterReturn \/ Reopen
    \/ \E failure \in BOOLEAN : RetireSuccess(failure) \/ FinishFrontResolution(failure)
    \/ \E c \in Cohorts : StartBatch(c) \/ StoreBatch(c) \/ JoinBatch(c)
         \/ ObserveBatch(c) \/ ApplyHead(c) \/ JoinHead(c) \/ CollectImage(c) \/ IgnoreStaleCompletion(c)
    \/ \E c \in Cohorts, outcome \in {"Success", "Absent", "Unknown"} : CompleteBatch(c, outcome)
    \/ \E c \in Cohorts, outcome \in {"Success", "Rejected", "Unknown"} : CompleteHead(c, outcome)
    \/ \E t \in Transactions : RequestCancellation(t) \/ ObserveFrontResolution(t)
         \/ ResolveDetachedMember(t) \/ ResolveRejected(t)

AuthorityLifecycleNext ==
    \E t \in Transactions : ExportAuthority(t) \/ ImportAuthority(t) \/ DropReceipt(t)

Next == PipelineNext \/ AuthorityLifecycleNext

(***************************************************************************
SafetySpec exhausts the physical pipeline and resolution state graph. The
full Spec additionally includes export/import/drop lifecycle actions. A
focused witness covers export/import recovery; the TLAPS kernel abstracts all
three lifecycle actions, while concrete drop interleavings remain outside the
positive TLC graph.
***************************************************************************)
Spec == Init /\ [][Next]_vars
SafetySpec == Init /\ [][PipelineNext]_vars

TypeOK ==
    /\ s.pipe \in Seq(Cohorts) /\ s.next \in 1..4
    /\ s.phase \in [Cohorts -> Phases]
    /\ s.image \in [Cohorts -> ImageType] /\ s.frozenImage \in [Cohorts -> ImageType]
    /\ s.validated \in [Cohorts -> SUBSET Cohorts]
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
      /\ s.image[c] = s.frozenImage[c] /\ s.image[c].members = Members(c)
      /\ s.image[c].previous \in 0..(c - 1)
      /\ s.image[c].first = (IF s.image[c].previous = 0 THEN 1
                            ELSE s.image[s.image[c].previous].last + 1)
      /\ s.image[c].last = s.image[c].first + 1

ValidationPrefix == \A c \in Frozen : s.validated[c] = Prefix(c)
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
    UnsettledFront => \A c \in PipeSet \ {Front} : s.headPuts[c] = 0
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
Ownership ==
    /\ Len(s.pipe) <= 2 /\ Cardinality(PipeSet) = Len(s.pipe)
    /\ PipeSet \subseteq s.allocated /\ Retained \subseteq s.allocated
    /\ BatchBorrowed \cup HeadBorrowed \subseteq PipeSet
    /\ Cardinality(HeadBorrowed) <= 1
    /\ \A c \in PipeSet : s.slotOwner[Slot(c)] = c
    /\ \A slot \in Slots : s.slotOwner[slot] # 0 => s.slotOwner[slot] \in PipeSet
    /\ (~s.online => s.pipe = <<>> /\ NoBorrow)
Safety == TypeOK /\ FrozenIdentity /\ ValidationPrefix /\ OrderedHead
          /\ NoPrematureSuccess /\ UnknownBarrier /\ NoReplay
          /\ ResolutionBinding /\ NoPrematureResolutionSuccess
          /\ ResolutionInstalled /\ ResolutionOwnership /\ Ownership

Trace == [action |-> s.lastAction, pipe |-> s.pipe, phase |-> s.phase,
          head |-> s.head, installed |-> s.installed, stored |-> s.stored,
          headToken |-> s.headToken, installedToken |-> s.installedToken,
          resolutionToken |-> s.resolutionToken, resolvingMember |-> s.resolvingMember,
          receipt |-> s.receipt, batchPuts |-> s.batchPuts, headPuts |-> s.headPuts,
          allocated |-> s.allocated, borrowed |-> BatchBorrowed \cup HeadBorrowed]

StateView == [s EXCEPT !.lastAction = "Init"]

SafetyStateView ==
    [StateView EXCEPT
       !.cancelRequested = {}, !.imported = {},
       !.outOfOrderBatch = FALSE, !.overlappedBatch = FALSE,
       !.reusedSlot = FALSE, !.localFailure = FALSE,
       !.closed = FALSE, !.reopened = FALSE,
       !.staleIgnored = FALSE, !.crashed = FALSE]
=============================================================================
