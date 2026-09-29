------ MODULE PipelinedAdaptiveAggregateCommitCoalescingSafetyProof ------
EXTENDS FiniteSetTheorems, Naturals, TLAPS

(***************************************************************************
Unqualified proof-source kernel for arbitrary finite domains and bounds.
Membership is selected from prepared pending submissions at Freeze, not a
constant preassigned partition. Rank orders cohorts, not transaction keys.
The kernel overapproximates selection: snapshot conflicts, FIFO selection,
member sequence arithmetic, opaque tokens, canonical bytes, completion before
join, and fallible resolution installation remain concrete-model obligations.
It is not an Ada/concrete-model refinement proof.

ByteDomain is a finite set of exclusive byte credits. Input, fragment, and
aggregate reservations are disjoint subsets of this same domain. A concrete
implementation must establish the reservation-size/encoding correspondence;
credit disjointness is not itself a proof of an Ada allocation size.
Aggregate reservations are made at Freeze and survive worker/provider borrows.

Accepted HEAD retires normally. Unknown HEAD halts the episode permanently.
Its successors must be abandoned and joined before active resolution or
detachment. Closing permits compatible successor preparation and immutable PUTs
before predecessor retirement; authoritative HEAD calls remain ordered.
No fairness, termination, or performance theorem is
claimed by this safety kernel. Every proof below must be rerun; old obligation
counts and old fixed-membership results do not qualify this source.
***************************************************************************)

CONSTANTS CohortDomain, MemberDomain, Rank, Capacity, QueueCapacity,
          PrepareCapacity, MemberCapacity, ByteDomain
ConstantsOK ==
    /\ IsFiniteSet(CohortDomain) /\ IsFiniteSet(MemberDomain) /\ IsFiniteSet(ByteDomain)
    /\ CohortDomain # {} /\ MemberDomain # {} /\ ByteDomain # {}
    /\ Capacity \in Nat \ {0} /\ QueueCapacity \in Nat \ {0}
    /\ PrepareCapacity \in Nat \ {0} /\ MemberCapacity \in Nat \ {0}
    /\ Rank \in [CohortDomain -> Nat]
    /\ \A c, d \in CohortDomain : Rank[c] = Rank[d] => c = d
Earlier(c) == {d \in CohortDomain : Rank[d] < Rank[c]}
Input(t) == <<"Input", t>>
Fragment(t) == <<"Fragment", t>>
Batch(c) == <<"Batch", c>>
Inputs(ts) == {Input(t) : t \in ts}
Fragments(ts) == {Fragment(t) : t \in ts}
Batches(cs) == {Batch(c) : c \in cs}
Resources == Inputs(MemberDomain) \cup Fragments(MemberDomain) \cup Batches(CohortDomain)
Work == Fragments(MemberDomain) \cup Batches(CohortDomain)

VARIABLE s
vars == <<s>>
StateFields ==
    {"admitted", "collected", "delivered", "discarded", "pending", "prepared", "rejected",
     "groups", "buffers",
     "prepareCalls", "prepareBorrow", "sealed", "ready", "issued", "stored", "published",
     "retired", "excluded", "abandoned", "prepareFailed", "batchFailed", "validated", "projection",
     "batchCalls", "headCalls", "batchBorrow", "headBorrow", "owned", "accepted", "unknown",
     "absent", "authority", "exported", "ack",
     "closing", "online", "fenced", "halted", "unknownEpisode", "resolutionWrites"}

THEOREM FunctionExceptAtOther ==
    ASSUME NEW f,
        NEW changed \in DOMAIN f,
        NEW retained \in DOMAIN f,
        NEW value,
        changed # retained
    PROVE [f EXCEPT ![changed] = value][retained] = f[retained]
<1> QED OBVIOUS

THEOREM FunctionExceptAtSame ==
    ASSUME NEW f,
        NEW changed \in DOMAIN f,
        NEW value
    PROVE [f EXCEPT ![changed] = value][changed] = value
<1> QED OBVIOUS

THEOREM FunctionExceptPreservesDomain ==
    ASSUME NEW f,
        NEW changed \in DOMAIN f,
        NEW value
    PROVE DOMAIN [f EXCEPT ![changed] = value] = DOMAIN f
<1> QED OBVIOUS

Members(c) == s.groups[c]
BoundMembers == UNION {Members(c) : c \in s.issued}
CohortsOf(ts) == {c \in s.issued : Members(c) \cap ts # {}}
LiveMembers == s.admitted \ s.collected
Allocated == {r \in Resources : s.buffers[r] # {}}
UsedBytes == UNION {s.buffers[r] : r \in Resources}
Release(buffers, resources) ==
    [r \in Resources |-> IF r \in resources THEN {} ELSE buffers[r]]
Fresh(bytes) == bytes \subseteq ByteDomain \ UsedBytes /\ bytes # {}
DrainedFor(c) ==
    s.owned = {c} /\ s.pending = {} /\ s.prepareBorrow = {} /\ s.batchBorrow = {} /\ s.headBorrow = {}

THEOREM InputNotWork ==
    ASSUME NEW t
    PROVE Input(t) \notin Work
<1> QED BY DEF Input, Work, Fragments, Batches, Fragment, Batch

THEOREM FragmentMembership ==
    ASSUME NEW t,
        NEW ts,
        Fragment(t) \in Fragments(ts)
    PROVE t \in ts
<1> QED BY DEF Fragments, Fragment

THEOREM FragmentInputDisjoint ==
    ASSUME NEW left,
        NEW right
    PROVE Fragments(left) \cap Inputs(right) = {}
<1> QED BY DEF Fragments, Inputs, Fragment, Input

THEOREM FragmentsPreserveDisjointness ==
    ASSUME NEW left,
        NEW right,
        left \cap right = {}
    PROVE Fragments(left) \cap Fragments(right) = {}
<1> QED BY DEF Fragments, Fragment

THEOREM FragmentsPreserveSubset ==
    ASSUME NEW left,
        NEW right,
        left \subseteq right
    PROVE Fragments(left) \subseteq Fragments(right)
<1> QED BY DEF Fragments, Fragment

THEOREM BatchFragmentDisjoint ==
    ASSUME NEW batches,
        NEW members
    PROVE Batches(batches) \cap Fragments(members) = {}
<1> QED BY DEF Batches, Fragments, Batch, Fragment

InitialState ==
    [admitted |-> {}, collected |-> {}, delivered |-> {}, discarded |-> {}, pending |-> {},
     prepared |-> {}, rejected |-> {},
     groups |-> [c \in CohortDomain |-> {}],
     buffers |-> [r \in Resources |-> {}], prepareCalls |-> {}, prepareBorrow |-> {},
     sealed |-> {}, ready |-> {}, issued |-> {}, stored |-> {}, published |-> {}, retired |-> {},
     excluded |-> {}, abandoned |-> {}, prepareFailed |-> {}, batchFailed |-> {},
     validated |-> {}, projection |-> {},
     batchCalls |-> {}, headCalls |-> {},
     batchBorrow |-> {}, headBorrow |-> {}, owned |-> {},
     accepted |-> {}, unknown |-> {}, absent |-> {}, authority |-> {}, exported |-> {}, ack |-> {},
     closing |-> FALSE, online |-> TRUE, fenced |-> FALSE, halted |-> FALSE,
     unknownEpisode |-> FALSE, resolutionWrites |-> 0]

Init == s = InitialState

THEOREM InitialStateProjection ==
    /\ DOMAIN InitialState = StateFields
    /\ InitialState.admitted = {} /\ InitialState.collected = {} /\ InitialState.delivered = {}
    /\ InitialState.discarded = {}
    /\ InitialState.pending = {} /\ InitialState.prepared = {} /\ InitialState.rejected = {}
    /\ InitialState.groups = [c \in CohortDomain |-> {}]
    /\ InitialState.buffers = [r \in Resources |-> {}]
    /\ InitialState.prepareCalls = {} /\ InitialState.prepareBorrow = {}
    /\ InitialState.sealed = {} /\ InitialState.ready = {} /\ InitialState.issued = {}
    /\ InitialState.stored = {} /\ InitialState.published = {} /\ InitialState.retired = {}
    /\ InitialState.excluded = {} /\ InitialState.abandoned = {}
    /\ InitialState.prepareFailed = {} /\ InitialState.batchFailed = {}
    /\ InitialState.validated = {}
    /\ InitialState.projection = {}
    /\ InitialState.batchCalls = {} /\ InitialState.headCalls = {}
    /\ InitialState.batchBorrow = {} /\ InitialState.headBorrow = {} /\ InitialState.owned = {}
    /\ InitialState.accepted = {} /\ InitialState.unknown = {} /\ InitialState.absent = {}
    /\ InitialState.authority = {} /\ InitialState.exported = {} /\ InitialState.ack = {}
    /\ InitialState.closing = FALSE /\ InitialState.online = TRUE
    /\ InitialState.fenced = FALSE /\ InitialState.halted = FALSE
    /\ InitialState.unknownEpisode = FALSE /\ InitialState.resolutionWrites = 0
<1> QED BY DEF InitialState, StateFields

THEOREM InitStateShape ==
    ASSUME Init
    PROVE DOMAIN s = StateFields
<1> QED BY DEF Init, InitialState, StateFields

THEOREM InitMemberFields ==
    ASSUME Init
    PROVE /\ s.admitted = {} /\ s.collected = {} /\ s.delivered = {} /\ s.discarded = {}
          /\ s.pending = {}
          /\ s.prepared = {} /\ s.rejected = {}
<1> QED BY DEF Init, InitialState

THEOREM InitPreparationFields ==
    ASSUME Init
    PROVE /\ s.groups = [c \in CohortDomain |-> {}]
          /\ s.buffers = [r \in Resources |-> {}]
          /\ s.prepareCalls = {} /\ s.prepareBorrow = {}
<1> QED BY DEF Init, InitialState

THEOREM InitCohortFields ==
    ASSUME Init
    PROVE /\ s.sealed = {} /\ s.ready = {} /\ s.issued = {} /\ s.stored = {}
          /\ s.published = {} /\ s.retired = {} /\ s.excluded = {} /\ s.abandoned = {}
          /\ s.prepareFailed = {} /\ s.batchFailed = {}
          /\ s.validated = {} /\ s.projection = {}
<1> QED BY DEF Init, InitialState

THEOREM InitPublicationFields ==
    ASSUME Init
    PROVE /\ s.batchCalls = {} /\ s.headCalls = {}
          /\ s.batchBorrow = {} /\ s.headBorrow = {} /\ s.owned = {}
          /\ s.accepted = {} /\ s.unknown = {} /\ s.absent = {}
<1> QED BY DEF Init, InitialState

THEOREM InitAuthorityFields ==
    ASSUME Init
    PROVE /\ s.delivered = {} /\ s.authority = {} /\ s.exported = {} /\ s.ack = {}
<1> QED BY DEF Init, InitialState

THEOREM InitLifecycleFields ==
    ASSUME Init
    PROVE /\ s.closing = FALSE /\ s.online = TRUE /\ s.fenced = FALSE /\ s.halted = FALSE
          /\ s.unknownEpisode = FALSE /\ s.resolutionWrites = 0
<1> QED BY DEF Init, InitialState

THEOREM InitEmptyViews ==
    ASSUME Init
    PROVE /\ BoundMembers = {}
          /\ Allocated = {}
          /\ UsedBytes = {}
          /\ CohortsOf({}) = {}
<1> QED BY InitPreparationFields, InitCohortFields
    DEF BoundMembers, Members, Allocated, UsedBytes, CohortsOf, Resources

AdmitState(t, bytes) ==
    [s EXCEPT !.admitted = s.admitted \cup {t}, !.pending = s.pending \cup {t},
        !.buffers[Input(t)] = bytes]

Admit(t, bytes) ==
    /\ s.online /\ ~s.closing /\ ~s.halted /\ ~s.fenced
    /\ t \in MemberDomain \ s.admitted /\ Fresh(bytes) /\ Cardinality(LiveMembers) < QueueCapacity
    /\ s' = AdmitState(t, bytes)

THEOREM AdmitStateProjection ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ DOMAIN AdmitState(t, bytes) = StateFields
          /\ AdmitState(t, bytes).admitted = s.admitted \cup {t}
          /\ AdmitState(t, bytes).pending = s.pending \cup {t}
          /\ AdmitState(t, bytes).buffers = [s.buffers EXCEPT ![Input(t)] = bytes]
          /\ \A field \in StateFields \ {"admitted", "pending", "buffers"} :
               AdmitState(t, bytes)[field] = s[field]
<1> QED BY DEF AdmitState, StateFields

THEOREM AdmitStateFrame ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        NEW field \in DOMAIN s,
        field # "admitted",
        field # "pending",
        field # "buffers"
    PROVE AdmitState(t, bytes)[field] = s[field]
<1> QED BY DEF AdmitState

THEOREM AdmitStatePreservesMemberFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ AdmitState(t, bytes).collected = s.collected
          /\ AdmitState(t, bytes).delivered = s.delivered
          /\ AdmitState(t, bytes).discarded = s.discarded
          /\ AdmitState(t, bytes).prepared = s.prepared
          /\ AdmitState(t, bytes).rejected = s.rejected
<1> QED BY DEF AdmitState, StateFields

THEOREM AdmitStatePreservesPreparationFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ AdmitState(t, bytes).groups = s.groups
          /\ AdmitState(t, bytes).prepareCalls = s.prepareCalls
          /\ AdmitState(t, bytes).prepareBorrow = s.prepareBorrow
<1> QED BY DEF AdmitState, StateFields

THEOREM AdmitStatePreservesCohortFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ AdmitState(t, bytes).sealed = s.sealed
          /\ AdmitState(t, bytes).ready = s.ready
          /\ AdmitState(t, bytes).issued = s.issued
          /\ AdmitState(t, bytes).stored = s.stored
          /\ AdmitState(t, bytes).published = s.published
          /\ AdmitState(t, bytes).retired = s.retired
          /\ AdmitState(t, bytes).excluded = s.excluded
          /\ AdmitState(t, bytes).abandoned = s.abandoned
          /\ AdmitState(t, bytes).prepareFailed = s.prepareFailed
          /\ AdmitState(t, bytes).batchFailed = s.batchFailed
          /\ AdmitState(t, bytes).validated = s.validated
          /\ AdmitState(t, bytes).projection = s.projection
<1> QED BY DEF AdmitState, StateFields

THEOREM AdmitStatePreservesPublicationFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ AdmitState(t, bytes).batchCalls = s.batchCalls
          /\ AdmitState(t, bytes).headCalls = s.headCalls
          /\ AdmitState(t, bytes).batchBorrow = s.batchBorrow
          /\ AdmitState(t, bytes).headBorrow = s.headBorrow
          /\ AdmitState(t, bytes).owned = s.owned
          /\ AdmitState(t, bytes).accepted = s.accepted
          /\ AdmitState(t, bytes).unknown = s.unknown
          /\ AdmitState(t, bytes).absent = s.absent
<1> QED BY DEF AdmitState, StateFields

THEOREM AdmitStatePreservesAuthorityFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ AdmitState(t, bytes).authority = s.authority
          /\ AdmitState(t, bytes).exported = s.exported
          /\ AdmitState(t, bytes).ack = s.ack
<1> QED BY DEF AdmitState, StateFields

THEOREM AdmitStatePreservesLifecycleFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ AdmitState(t, bytes).closing = s.closing
          /\ AdmitState(t, bytes).online = s.online
          /\ AdmitState(t, bytes).fenced = s.fenced
          /\ AdmitState(t, bytes).halted = s.halted
          /\ AdmitState(t, bytes).unknownEpisode = s.unknownEpisode
          /\ AdmitState(t, bytes).resolutionWrites = s.resolutionWrites
<1> QED BY DEF AdmitState, StateFields

StartTxnPrepareState(t, bytes) ==
    [s EXCEPT !.prepareCalls = s.prepareCalls \cup {Fragment(t)},
        !.prepareBorrow = s.prepareBorrow \cup {Fragment(t)}, !.buffers[Fragment(t)] = bytes]

StartTxnPrepare(t, bytes) ==
    /\ s.online /\ ~s.halted /\ ~s.fenced /\ t \in s.pending
    /\ Fragment(t) \notin s.prepareCalls /\ Input(t) \in Allocated /\ Fresh(bytes)
    /\ Cardinality(s.prepareBorrow) < PrepareCapacity
    /\ s' = StartTxnPrepareState(t, bytes)

THEOREM StartTxnPrepareStateProjection ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ DOMAIN StartTxnPrepareState(t, bytes) = StateFields
          /\ StartTxnPrepareState(t, bytes).prepareCalls = s.prepareCalls \cup {Fragment(t)}
          /\ StartTxnPrepareState(t, bytes).prepareBorrow = s.prepareBorrow \cup {Fragment(t)}
          /\ StartTxnPrepareState(t, bytes).buffers =
               [s.buffers EXCEPT ![Fragment(t)] = bytes]
          /\ \A field \in StateFields \ {"prepareCalls", "prepareBorrow", "buffers"} :
               StartTxnPrepareState(t, bytes)[field] = s[field]
<1> QED BY DEF StartTxnPrepareState, StateFields

THEOREM StartTxnPrepareStatePreservesMemberFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ StartTxnPrepareState(t, bytes).admitted = s.admitted
          /\ StartTxnPrepareState(t, bytes).collected = s.collected
          /\ StartTxnPrepareState(t, bytes).delivered = s.delivered
          /\ StartTxnPrepareState(t, bytes).discarded = s.discarded
          /\ StartTxnPrepareState(t, bytes).pending = s.pending
          /\ StartTxnPrepareState(t, bytes).prepared = s.prepared
          /\ StartTxnPrepareState(t, bytes).rejected = s.rejected
<1> QED BY DEF StartTxnPrepareState, StateFields

THEOREM StartTxnPrepareStatePreservesCohortFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ StartTxnPrepareState(t, bytes).groups = s.groups
          /\ StartTxnPrepareState(t, bytes).sealed = s.sealed
          /\ StartTxnPrepareState(t, bytes).ready = s.ready
          /\ StartTxnPrepareState(t, bytes).issued = s.issued
          /\ StartTxnPrepareState(t, bytes).stored = s.stored
          /\ StartTxnPrepareState(t, bytes).published = s.published
          /\ StartTxnPrepareState(t, bytes).retired = s.retired
          /\ StartTxnPrepareState(t, bytes).excluded = s.excluded
          /\ StartTxnPrepareState(t, bytes).abandoned = s.abandoned
          /\ StartTxnPrepareState(t, bytes).prepareFailed = s.prepareFailed
          /\ StartTxnPrepareState(t, bytes).batchFailed = s.batchFailed
          /\ StartTxnPrepareState(t, bytes).validated = s.validated
          /\ StartTxnPrepareState(t, bytes).projection = s.projection
<1> QED BY DEF StartTxnPrepareState, StateFields

THEOREM StartTxnPrepareStatePreservesPublicationFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ StartTxnPrepareState(t, bytes).batchCalls = s.batchCalls
          /\ StartTxnPrepareState(t, bytes).headCalls = s.headCalls
          /\ StartTxnPrepareState(t, bytes).batchBorrow = s.batchBorrow
          /\ StartTxnPrepareState(t, bytes).headBorrow = s.headBorrow
          /\ StartTxnPrepareState(t, bytes).owned = s.owned
          /\ StartTxnPrepareState(t, bytes).accepted = s.accepted
          /\ StartTxnPrepareState(t, bytes).unknown = s.unknown
          /\ StartTxnPrepareState(t, bytes).absent = s.absent
<1> QED BY DEF StartTxnPrepareState, StateFields

THEOREM StartTxnPrepareStatePreservesAuthorityFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ StartTxnPrepareState(t, bytes).authority = s.authority
          /\ StartTxnPrepareState(t, bytes).exported = s.exported
          /\ StartTxnPrepareState(t, bytes).ack = s.ack
<1> QED BY DEF StartTxnPrepareState, StateFields

THEOREM StartTxnPrepareStatePreservesLifecycleFields ==
    ASSUME NEW t \in MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ StartTxnPrepareState(t, bytes).closing = s.closing
          /\ StartTxnPrepareState(t, bytes).online = s.online
          /\ StartTxnPrepareState(t, bytes).fenced = s.fenced
          /\ StartTxnPrepareState(t, bytes).halted = s.halted
          /\ StartTxnPrepareState(t, bytes).unknownEpisode = s.unknownEpisode
          /\ StartTxnPrepareState(t, bytes).resolutionWrites = s.resolutionWrites
<1> QED BY DEF StartTxnPrepareState, StateFields

ReleasedTxn(t, keep) == {Input(t)} \cup (IF keep THEN {} ELSE {Fragment(t)})

JoinTxnPrepareState(t, keep) ==
    [s EXCEPT !.prepareBorrow = s.prepareBorrow \ {Fragment(t)},
        !.prepared = IF keep THEN s.prepared \cup {t} ELSE s.prepared,
        !.pending = IF keep THEN s.pending ELSE s.pending \ {t},
        !.rejected = IF keep THEN s.rejected ELSE s.rejected \cup {t},
        !.buffers = Release(s.buffers, ReleasedTxn(t, keep))]

KeepTxnPrepare(t, success) == success /\ t \in s.pending

JoinTxnPrepare(t, success) ==
    /\ Fragment(t) \in s.prepareBorrow /\ success \in BOOLEAN
    /\ s' = JoinTxnPrepareState(t, KeepTxnPrepare(t, success))

THEOREM JoinTxnPrepareStateProjection ==
    ASSUME NEW t \in MemberDomain,
        NEW keep \in BOOLEAN,
        DOMAIN s = StateFields
    PROVE /\ DOMAIN JoinTxnPrepareState(t, keep) = StateFields
          /\ JoinTxnPrepareState(t, keep).prepareBorrow = s.prepareBorrow \ {Fragment(t)}
          /\ JoinTxnPrepareState(t, keep).prepared =
               (IF keep THEN s.prepared \cup {t} ELSE s.prepared)
          /\ JoinTxnPrepareState(t, keep).pending =
               (IF keep THEN s.pending ELSE s.pending \ {t})
          /\ JoinTxnPrepareState(t, keep).rejected =
               (IF keep THEN s.rejected ELSE s.rejected \cup {t})
          /\ JoinTxnPrepareState(t, keep).buffers =
               Release(s.buffers, ReleasedTxn(t, keep))
<1> QED BY DEF JoinTxnPrepareState, StateFields

THEOREM JoinTxnPrepareStatePreservesFixedMemberFields ==
    ASSUME NEW t \in MemberDomain,
        NEW keep \in BOOLEAN,
        DOMAIN s = StateFields
    PROVE /\ JoinTxnPrepareState(t, keep).admitted = s.admitted
          /\ JoinTxnPrepareState(t, keep).collected = s.collected
          /\ JoinTxnPrepareState(t, keep).delivered = s.delivered
          /\ JoinTxnPrepareState(t, keep).discarded = s.discarded
<1> QED BY DEF JoinTxnPrepareState, StateFields

THEOREM JoinTxnPrepareStatePreservesPreparationFields ==
    ASSUME NEW t \in MemberDomain,
        NEW keep \in BOOLEAN,
        DOMAIN s = StateFields
    PROVE /\ JoinTxnPrepareState(t, keep).groups = s.groups
          /\ JoinTxnPrepareState(t, keep).prepareCalls = s.prepareCalls
<1> QED BY DEF JoinTxnPrepareState, StateFields

THEOREM JoinTxnPrepareStatePreservesCohortFields ==
    ASSUME NEW t \in MemberDomain,
        NEW keep \in BOOLEAN,
        DOMAIN s = StateFields
    PROVE /\ JoinTxnPrepareState(t, keep).sealed = s.sealed
          /\ JoinTxnPrepareState(t, keep).ready = s.ready
          /\ JoinTxnPrepareState(t, keep).issued = s.issued
          /\ JoinTxnPrepareState(t, keep).stored = s.stored
          /\ JoinTxnPrepareState(t, keep).published = s.published
          /\ JoinTxnPrepareState(t, keep).retired = s.retired
          /\ JoinTxnPrepareState(t, keep).excluded = s.excluded
          /\ JoinTxnPrepareState(t, keep).abandoned = s.abandoned
          /\ JoinTxnPrepareState(t, keep).prepareFailed = s.prepareFailed
          /\ JoinTxnPrepareState(t, keep).batchFailed = s.batchFailed
          /\ JoinTxnPrepareState(t, keep).validated = s.validated
          /\ JoinTxnPrepareState(t, keep).projection = s.projection
<1> QED BY DEF JoinTxnPrepareState, StateFields

THEOREM JoinTxnPrepareStatePreservesPublicationFields ==
    ASSUME NEW t \in MemberDomain,
        NEW keep \in BOOLEAN,
        DOMAIN s = StateFields
    PROVE /\ JoinTxnPrepareState(t, keep).batchCalls = s.batchCalls
          /\ JoinTxnPrepareState(t, keep).headCalls = s.headCalls
          /\ JoinTxnPrepareState(t, keep).batchBorrow = s.batchBorrow
          /\ JoinTxnPrepareState(t, keep).headBorrow = s.headBorrow
          /\ JoinTxnPrepareState(t, keep).owned = s.owned
          /\ JoinTxnPrepareState(t, keep).accepted = s.accepted
          /\ JoinTxnPrepareState(t, keep).unknown = s.unknown
          /\ JoinTxnPrepareState(t, keep).absent = s.absent
<1> QED BY DEF JoinTxnPrepareState, StateFields

THEOREM JoinTxnPrepareStatePreservesAuthorityFields ==
    ASSUME NEW t \in MemberDomain,
        NEW keep \in BOOLEAN,
        DOMAIN s = StateFields
    PROVE /\ JoinTxnPrepareState(t, keep).authority = s.authority
          /\ JoinTxnPrepareState(t, keep).exported = s.exported
          /\ JoinTxnPrepareState(t, keep).ack = s.ack
<1> QED BY DEF JoinTxnPrepareState, StateFields

THEOREM JoinTxnPrepareStatePreservesLifecycleFields ==
    ASSUME NEW t \in MemberDomain,
        NEW keep \in BOOLEAN,
        DOMAIN s = StateFields
    PROVE /\ JoinTxnPrepareState(t, keep).closing = s.closing
          /\ JoinTxnPrepareState(t, keep).online = s.online
          /\ JoinTxnPrepareState(t, keep).fenced = s.fenced
          /\ JoinTxnPrepareState(t, keep).halted = s.halted
          /\ JoinTxnPrepareState(t, keep).unknownEpisode = s.unknownEpisode
          /\ JoinTxnPrepareState(t, keep).resolutionWrites = s.resolutionWrites
<1>1. JoinTxnPrepareState(t, keep).closing = s.closing
  BY DEF JoinTxnPrepareState, StateFields
<1>2. JoinTxnPrepareState(t, keep).online = s.online
  BY DEF JoinTxnPrepareState, StateFields
<1>3. JoinTxnPrepareState(t, keep).fenced = s.fenced
  BY DEF JoinTxnPrepareState, StateFields
<1>4. JoinTxnPrepareState(t, keep).halted = s.halted
  BY DEF JoinTxnPrepareState, StateFields
<1>5. JoinTxnPrepareState(t, keep).unknownEpisode = s.unknownEpisode
  BY DEF JoinTxnPrepareState, StateFields
<1>6. JoinTxnPrepareState(t, keep).resolutionWrites = s.resolutionWrites
  BY DEF JoinTxnPrepareState, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6

FreezeState(c, ts, bytes) ==
    [s EXCEPT !.pending = s.pending \ ts, !.groups[c] = ts, !.issued = s.issued \cup {c},
        !.owned = s.owned \cup {c}, !.buffers[Batch(c)] = bytes]
Freeze(c, ts, bytes) ==
    /\ s.online /\ ~s.halted /\ ~s.fenced /\ s.unknown = {}
    /\ c \in CohortDomain \ s.issued /\ Earlier(c) \subseteq s.issued
    /\ ts \subseteq s.pending \cap s.prepared /\ ts # {} /\ Cardinality(ts) <= MemberCapacity
    /\ Fragments(ts) \subseteq Allocated /\ Fresh(bytes) /\ Cardinality(s.owned) < Capacity
    /\ s' = FreezeState(c, ts, bytes)

FreezeChangedFields == {"pending", "groups", "issued", "owned", "buffers"}
FreezeFieldsPresent ==
    /\ "pending" \in DOMAIN s
    /\ "groups" \in DOMAIN s
    /\ "issued" \in DOMAIN s
    /\ "owned" \in DOMAIN s
    /\ "buffers" \in DOMAIN s

THEOREM StateShapeProvidesFreezeFields ==
    ASSUME DOMAIN s = StateFields
    PROVE FreezeFieldsPresent
<1>1. "pending" \in DOMAIN s
  BY DEF StateFields
<1>2. "groups" \in DOMAIN s
  BY DEF StateFields
<1>3. "issued" \in DOMAIN s
  BY DEF StateFields
<1>4. "owned" \in DOMAIN s
  BY DEF StateFields
<1>5. "buffers" \in DOMAIN s
  BY DEF StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5 DEF FreezeFieldsPresent

THEOREM FreezeStatePreservesOther ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        NEW field \in DOMAIN s \ FreezeChangedFields
    PROVE FreezeState(c, ts, bytes)[field] = s[field]
<1> QED BY DEF FreezeState, FreezeChangedFields

THEOREM FreezeStateChangedValues ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        FreezeFieldsPresent
    PROVE /\ FreezeState(c, ts, bytes).pending = s.pending \ ts
          /\ FreezeState(c, ts, bytes).groups = [s.groups EXCEPT ![c] = ts]
          /\ FreezeState(c, ts, bytes).issued = s.issued \cup {c}
          /\ FreezeState(c, ts, bytes).owned = s.owned \cup {c}
          /\ FreezeState(c, ts, bytes).buffers = [s.buffers EXCEPT ![Batch(c)] = bytes]
<1> QED BY DEF FreezeState, FreezeFieldsPresent

THEOREM FreezeStateGroupAt ==
    ASSUME NEW c \in CohortDomain,
        NEW d \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        FreezeFieldsPresent,
        s.groups \in [CohortDomain -> SUBSET MemberDomain]
    PROVE FreezeState(c, ts, bytes).groups[d] = IF d = c THEN ts ELSE s.groups[d]
<1> QED BY DEF FreezeState, FreezeFieldsPresent

THEOREM FreezeStatePreservesDomain ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE DOMAIN FreezeState(c, ts, bytes) = StateFields
<1> QED BY DEF FreezeState

THEOREM FreezeStatePreservesMemberFields ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ FreezeState(c, ts, bytes).admitted = s.admitted
          /\ FreezeState(c, ts, bytes).collected = s.collected
          /\ FreezeState(c, ts, bytes).delivered = s.delivered
          /\ FreezeState(c, ts, bytes).discarded = s.discarded
          /\ FreezeState(c, ts, bytes).prepared = s.prepared
          /\ FreezeState(c, ts, bytes).rejected = s.rejected
<1> QED BY DEF FreezeState, StateFields

THEOREM FreezeStatePreservesPreparationFields ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ FreezeState(c, ts, bytes).prepareCalls = s.prepareCalls
          /\ FreezeState(c, ts, bytes).prepareBorrow = s.prepareBorrow
<1> QED BY DEF FreezeState, StateFields

THEOREM FreezeStatePreservesCohortFields ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ FreezeState(c, ts, bytes).sealed = s.sealed
          /\ FreezeState(c, ts, bytes).ready = s.ready
          /\ FreezeState(c, ts, bytes).stored = s.stored
          /\ FreezeState(c, ts, bytes).published = s.published
          /\ FreezeState(c, ts, bytes).retired = s.retired
          /\ FreezeState(c, ts, bytes).excluded = s.excluded
          /\ FreezeState(c, ts, bytes).abandoned = s.abandoned
          /\ FreezeState(c, ts, bytes).prepareFailed = s.prepareFailed
          /\ FreezeState(c, ts, bytes).batchFailed = s.batchFailed
          /\ FreezeState(c, ts, bytes).validated = s.validated
          /\ FreezeState(c, ts, bytes).projection = s.projection
<1> QED BY DEF FreezeState, StateFields

THEOREM FreezeStatePreservesPublicationFields ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ FreezeState(c, ts, bytes).batchCalls = s.batchCalls
          /\ FreezeState(c, ts, bytes).headCalls = s.headCalls
          /\ FreezeState(c, ts, bytes).batchBorrow = s.batchBorrow
          /\ FreezeState(c, ts, bytes).headBorrow = s.headBorrow
          /\ FreezeState(c, ts, bytes).accepted = s.accepted
          /\ FreezeState(c, ts, bytes).unknown = s.unknown
          /\ FreezeState(c, ts, bytes).absent = s.absent
<1> QED BY DEF FreezeState, StateFields

THEOREM FreezeStatePreservesAuthorityFields ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ FreezeState(c, ts, bytes).authority = s.authority
          /\ FreezeState(c, ts, bytes).exported = s.exported
          /\ FreezeState(c, ts, bytes).ack = s.ack
<1> QED BY DEF FreezeState, StateFields

THEOREM FreezeStatePreservesLifecycleFields ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        DOMAIN s = StateFields
    PROVE /\ FreezeState(c, ts, bytes).closing = s.closing
          /\ FreezeState(c, ts, bytes).online = s.online
          /\ FreezeState(c, ts, bytes).halted = s.halted
          /\ FreezeState(c, ts, bytes).fenced = s.fenced
          /\ FreezeState(c, ts, bytes).unknownEpisode = s.unknownEpisode
          /\ FreezeState(c, ts, bytes).resolutionWrites = s.resolutionWrites
<1> QED BY DEF FreezeState, StateFields

StartBatchPrepare(c) ==
    /\ s.online /\ ~s.halted /\ ~s.fenced /\ c \in s.owned \ s.abandoned
    /\ Batch(c) \notin s.prepareCalls /\ Fragments(Members(c)) \subseteq Allocated
    /\ Cardinality(s.prepareBorrow) < PrepareCapacity
    /\ s' = [s EXCEPT !.prepareCalls = s.prepareCalls \cup {Batch(c)},
          !.prepareBorrow = s.prepareBorrow \cup {Batch(c)}]

THEOREM StartBatchPrepareProjection ==
    ASSUME NEW c \in CohortDomain,
        DOMAIN s = StateFields,
        StartBatchPrepare(c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.prepareCalls = s.prepareCalls \cup {Batch(c)}
          /\ s'.prepareBorrow = s.prepareBorrow \cup {Batch(c)}
          /\ \A field \in StateFields \ {"prepareCalls", "prepareBorrow"} :
               s'[field] = s[field]
<1> QED BY DEF StartBatchPrepare, StateFields

KeepBatchPrepare(c, success) == success /\ c \notin s.abandoned

JoinBatchPrepare(c, success) ==
    /\ Batch(c) \in s.prepareBorrow /\ success \in BOOLEAN
    /\ s' = [s EXCEPT !.prepareBorrow = s.prepareBorrow \ {Batch(c)},
         !.buffers = Release(s.buffers, Fragments(Members(c))),
         !.sealed = IF KeepBatchPrepare(c, success) THEN s.sealed \cup {c} ELSE s.sealed,
         !.ready = IF KeepBatchPrepare(c, success) THEN s.ready \cup {c} ELSE s.ready,
         !.prepareFailed = IF KeepBatchPrepare(c, success)
              THEN s.prepareFailed ELSE s.prepareFailed \cup {c}]

THEOREM JoinBatchPrepareProjection ==
    ASSUME NEW c \in CohortDomain,
        NEW success \in BOOLEAN,
        DOMAIN s = StateFields,
        JoinBatchPrepare(c, success)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.prepareBorrow = s.prepareBorrow \ {Batch(c)}
          /\ s'.buffers = Release(s.buffers, Fragments(Members(c)))
          /\ s'.sealed =
               (IF KeepBatchPrepare(c, success) THEN s.sealed \cup {c} ELSE s.sealed)
          /\ s'.ready =
               (IF KeepBatchPrepare(c, success) THEN s.ready \cup {c} ELSE s.ready)
          /\ s'.prepareFailed =
               (IF KeepBatchPrepare(c, success) THEN s.prepareFailed
                ELSE s.prepareFailed \cup {c})
          /\ \A field \in StateFields \
               {"prepareBorrow", "buffers", "sealed", "ready", "prepareFailed"} :
               s'[field] = s[field]
<1> QED BY DEF JoinBatchPrepare, StateFields

FailPreparedFront(c) ==
    /\ c \in s.owned \cap s.prepareFailed /\ Earlier(c) \subseteq s.retired
    /\ c \notin s.batchBorrow \cup s.headBorrow /\ Batch(c) \notin s.prepareBorrow
    /\ s' = [s EXCEPT !.abandoned = s.abandoned \cup {c}, !.halted = TRUE]

StartBatch(c) ==
    /\ s.online /\ ~s.halted /\ ~s.fenced /\ c \in s.ready
    /\ s' = [s EXCEPT !.ready = s.ready \ {c}, !.batchCalls = s.batchCalls \cup {c},
          !.batchBorrow = s.batchBorrow \cup {c}]

THEOREM StartBatchProjection ==
    ASSUME NEW c \in CohortDomain,
        DOMAIN s = StateFields,
        StartBatch(c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.ready = s.ready \ {c}
          /\ s'.batchCalls = s.batchCalls \cup {c}
          /\ s'.batchBorrow = s.batchBorrow \cup {c}
          /\ \A field \in StateFields \ {"ready", "batchCalls", "batchBorrow"} :
               s'[field] = s[field]
<1> QED BY DEF StartBatch, StateFields

JoinBatch(c, entered) ==
    /\ c \in s.batchBorrow /\ entered \in BOOLEAN
    /\ s' = [s EXCEPT !.batchBorrow = s.batchBorrow \ {c},
          !.stored = IF entered THEN s.stored \cup {c} ELSE s.stored,
          !.batchFailed = IF entered THEN s.batchFailed ELSE s.batchFailed \cup {c}]

THEOREM JoinBatchProjection ==
    ASSUME NEW c \in CohortDomain,
        NEW entered \in BOOLEAN,
        DOMAIN s = StateFields,
        JoinBatch(c, entered)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.batchBorrow = s.batchBorrow \ {c}
          /\ s'.stored = (IF entered THEN s.stored \cup {c} ELSE s.stored)
          /\ s'.batchFailed = (IF entered THEN s.batchFailed ELSE s.batchFailed \cup {c})
          /\ \A field \in StateFields \ {"batchBorrow", "stored", "batchFailed"} :
               s'[field] = s[field]
<1> QED BY DEF JoinBatch, StateFields

FailBatchFront(c) ==
    /\ c \in s.owned \cap s.batchFailed /\ Earlier(c) \subseteq s.retired
    /\ c \notin s.batchBorrow \cup s.headBorrow /\ Batch(c) \notin s.prepareBorrow
    /\ c \notin s.projection
    /\ s' = [s EXCEPT !.abandoned = s.abandoned \cup {c}, !.halted = TRUE]

ValidateFrontValidated(c, success) ==
    [s EXCEPT !.validated = IF success THEN s.validated \cup {c} ELSE s.validated]

ValidateFrontProjected(c, success) ==
    [ValidateFrontValidated(c, success) EXCEPT !.projection = IF success THEN {c} ELSE {}]

ValidateFrontPrefix(c, success) ==
    [ValidateFrontProjected(c, success) EXCEPT
     !.abandoned = IF success THEN s.abandoned ELSE s.abandoned \cup {c}]

ValidateFrontState(c, success) ==
    [ValidateFrontPrefix(c, success) EXCEPT !.halted = s.halted \/ ~success]

ValidateFront(c, success) ==
    /\ s.online /\ ~s.halted /\ ~s.fenced /\ success \in BOOLEAN
    /\ c \in (s.owned \cap s.stored) \ (s.headCalls \cup s.batchBorrow \cup s.abandoned)
    /\ Earlier(c) \subseteq s.retired /\ s.headBorrow = {} /\ s.projection = {}
    /\ s' = ValidateFrontState(c, success)

THEOREM ValidateFrontProjection ==
    ASSUME NEW c \in CohortDomain,
        NEW success \in BOOLEAN,
        DOMAIN s = StateFields,
        ValidateFront(c, success)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.validated = (IF success THEN s.validated \cup {c} ELSE s.validated)
          /\ s'.projection = (IF success THEN {c} ELSE {})
          /\ s'.abandoned = (IF success THEN s.abandoned ELSE s.abandoned \cup {c})
          /\ s'.halted = (s.halted \/ ~success)
          /\ \A field \in StateFields \ {"validated", "projection", "abandoned", "halted"} :
               s'[field] = s[field]
<1>0. /\ "validated" \in StateFields
       /\ "projection" \in StateFields
       /\ "abandoned" \in StateFields
       /\ "halted" \in StateFields
  BY DEF StateFields
<1>0a. DOMAIN ValidateFrontValidated(c, success) = StateFields
  BY <1>0, FunctionExceptPreservesDomain DEF ValidateFrontValidated
<1>0b. DOMAIN ValidateFrontProjected(c, success) = StateFields
  BY <1>0, <1>0a, FunctionExceptPreservesDomain DEF ValidateFrontProjected
<1>0c. DOMAIN ValidateFrontPrefix(c, success) = StateFields
  BY <1>0, <1>0b, FunctionExceptPreservesDomain DEF ValidateFrontPrefix
<1>0d. /\ "projection" # "validated"
        /\ "abandoned" # "validated"
        /\ "abandoned" # "projection"
        /\ "halted" # "validated"
        /\ "halted" # "projection"
        /\ "halted" # "abandoned"
  OBVIOUS
<1>1. DOMAIN s' = StateFields
  BY <1>0, <1>0c, FunctionExceptPreservesDomain
     DEF ValidateFront, ValidateFrontState
<1>2. s'.validated = IF success THEN s.validated \cup {c} ELSE s.validated
  <2>1. ValidateFrontValidated(c, success).validated =
           IF success THEN s.validated \cup {c} ELSE s.validated
    BY <1>0, FunctionExceptAtSame DEF ValidateFrontValidated
  <2>2. ValidateFrontProjected(c, success).validated =
           ValidateFrontValidated(c, success).validated
    BY <1>0, <1>0a, <1>0d, FunctionExceptAtOther DEF ValidateFrontProjected
  <2>3. ValidateFrontPrefix(c, success).validated =
           ValidateFrontProjected(c, success).validated
    BY <1>0, <1>0b, <1>0d, FunctionExceptAtOther DEF ValidateFrontPrefix
  <2>4. ValidateFrontState(c, success).validated =
           ValidateFrontPrefix(c, success).validated
    BY <1>0, <1>0c, <1>0d, FunctionExceptAtOther DEF ValidateFrontState
  <2> QED BY <2>1, <2>2, <2>3, <2>4 DEF ValidateFront
<1>3. s'.projection = IF success THEN {c} ELSE {}
  <2>1. ValidateFrontProjected(c, success).projection = IF success THEN {c} ELSE {}
    BY <1>0, <1>0a, FunctionExceptAtSame DEF ValidateFrontProjected
  <2>2. ValidateFrontPrefix(c, success).projection =
           ValidateFrontProjected(c, success).projection
    BY <1>0, <1>0b, <1>0d, FunctionExceptAtOther DEF ValidateFrontPrefix
  <2>3. ValidateFrontState(c, success).projection =
           ValidateFrontPrefix(c, success).projection
    BY <1>0, <1>0c, <1>0d, FunctionExceptAtOther DEF ValidateFrontState
  <2> QED BY <2>1, <2>2, <2>3 DEF ValidateFront
<1>4. s'.abandoned = IF success THEN s.abandoned ELSE s.abandoned \cup {c}
  <2>1. ValidateFrontPrefix(c, success).abandoned =
           IF success THEN s.abandoned ELSE s.abandoned \cup {c}
    BY <1>0, <1>0b, FunctionExceptAtSame DEF ValidateFrontPrefix
  <2>2. ValidateFrontState(c, success).abandoned =
           ValidateFrontPrefix(c, success).abandoned
    BY <1>0, <1>0c, <1>0d, FunctionExceptAtOther DEF ValidateFrontState
  <2> QED BY <2>1, <2>2 DEF ValidateFront
<1>5. s'.halted = (s.halted \/ ~success)
  <2>1. ValidateFrontState(c, success).halted = (s.halted \/ ~success)
    BY ONLY <1>0, <1>0c, FunctionExceptAtSame,
       [ValidateFrontPrefix(c, success) EXCEPT
        !["halted"] = s.halted \/ ~success]["halted"] = (s.halted \/ ~success)
       DEF ValidateFrontState
  <2> QED BY <2>1 DEF ValidateFront
<1>6. \A field \in StateFields \ {"validated", "projection", "abandoned", "halted"} :
         s'[field] = s[field]
  BY <1>0a, <1>0b, <1>0c, <1>0d, FunctionExceptAtOther
     DEF ValidateFront, ValidateFrontState, ValidateFrontPrefix, ValidateFrontProjected,
     ValidateFrontValidated, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6

StartHead(c) ==
    /\ s.online /\ ~s.halted /\ ~s.fenced /\ s.unknown = {} /\ s.headBorrow = {}
    /\ c \in (s.owned \cap s.stored \cap s.validated) \
              (s.headCalls \cup s.batchBorrow \cup s.abandoned)
    /\ s.projection = {c}
    /\ Earlier(c) \subseteq s.retired
    /\ s' = [s EXCEPT !.headCalls = s.headCalls \cup {c}, !.headBorrow = {c}]

THEOREM StartHeadProjection ==
    ASSUME NEW c \in CohortDomain,
        DOMAIN s = StateFields,
        StartHead(c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.headCalls = s.headCalls \cup {c}
          /\ s'.headBorrow = {c}
          /\ \A field \in StateFields \ {"headCalls", "headBorrow"} :
               s'[field] = s[field]
<1> QED BY DEF StartHead, StateFields

JoinHeadPrefix(c, entered, uncertain) ==
    [s EXCEPT !.headBorrow = {},
         !.projection = IF entered /\ ~uncertain THEN s.projection ELSE {},
         !.published = IF entered THEN s.published \cup {c} ELSE s.published,
         !.accepted = IF entered /\ ~uncertain THEN s.accepted \cup {c} ELSE s.accepted,
         !.unknown = IF uncertain THEN s.unknown \cup {c} ELSE s.unknown,
         !.authority = IF uncertain THEN s.authority \cup Members(c) ELSE s.authority,
         !.absent = IF ~entered /\ ~uncertain THEN s.absent \cup {c} ELSE s.absent,
         !.abandoned = IF ~entered /\ ~uncertain THEN s.abandoned \cup {c} ELSE s.abandoned]

THEOREM JoinHeadPrefixFrame ==
    ASSUME NEW c \in CohortDomain,
        NEW entered \in BOOLEAN,
        NEW uncertain \in BOOLEAN,
        DOMAIN s = StateFields
    PROVE \A field \in
              StateFields \ {"headBorrow", "projection", "published", "accepted", "unknown",
                             "authority", "absent", "abandoned"} :
              JoinHeadPrefix(c, entered, uncertain)[field] = s[field]
<1> QED BY DEF JoinHeadPrefix, StateFields

JoinHeadEpisode(c, entered, uncertain) ==
    [JoinHeadPrefix(c, entered, uncertain) EXCEPT
     !.unknownEpisode = s.unknownEpisode \/ uncertain]

JoinHeadHalted(c, entered, uncertain) ==
    [JoinHeadEpisode(c, entered, uncertain) EXCEPT
     !.halted = s.halted \/ uncertain \/ ~entered]

JoinHeadState(c, entered, uncertain) ==
    [JoinHeadHalted(c, entered, uncertain) EXCEPT
     !.fenced = s.fenced \/ (~entered /\ ~uncertain)]

JoinHead(c, entered, uncertain) ==
    /\ c \in s.headBorrow /\ entered \in BOOLEAN /\ uncertain \in BOOLEAN
    /\ s' = JoinHeadState(c, entered, uncertain)

THEOREM JoinHeadProjection ==
    ASSUME NEW c \in CohortDomain,
        NEW entered \in BOOLEAN,
        NEW uncertain \in BOOLEAN,
        DOMAIN s = StateFields,
        JoinHead(c, entered, uncertain)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.headBorrow = {}
          /\ s'.projection = (IF entered /\ ~uncertain THEN s.projection ELSE {})
          /\ s'.published = (IF entered THEN s.published \cup {c} ELSE s.published)
          /\ s'.accepted =
               (IF entered /\ ~uncertain THEN s.accepted \cup {c} ELSE s.accepted)
          /\ s'.unknown = (IF uncertain THEN s.unknown \cup {c} ELSE s.unknown)
          /\ s'.authority =
               (IF uncertain THEN s.authority \cup Members(c) ELSE s.authority)
          /\ s'.absent =
               (IF ~entered /\ ~uncertain THEN s.absent \cup {c} ELSE s.absent)
          /\ s'.abandoned =
               (IF ~entered /\ ~uncertain THEN s.abandoned \cup {c} ELSE s.abandoned)
          /\ s'.unknownEpisode = (s.unknownEpisode \/ uncertain)
          /\ s'.halted = (s.halted \/ uncertain \/ ~entered)
          /\ s'.fenced = (s.fenced \/ (~entered /\ ~uncertain))
          /\ \A field \in StateFields \
               {"headBorrow", "projection", "published", "accepted", "unknown",
                "authority", "absent", "abandoned", "unknownEpisode", "halted", "fenced"} :
               s'[field] = s[field]
<1>0. /\ DOMAIN JoinHeadPrefix(c, entered, uncertain) = StateFields
       /\ "unknownEpisode" \in DOMAIN JoinHeadPrefix(c, entered, uncertain)
  BY DEF JoinHeadPrefix, StateFields
<1>0a. /\ DOMAIN JoinHeadEpisode(c, entered, uncertain) = StateFields
        /\ "halted" \in DOMAIN JoinHeadEpisode(c, entered, uncertain)
  BY <1>0, FunctionExceptPreservesDomain DEF JoinHeadEpisode, StateFields
<1>0b. /\ DOMAIN JoinHeadHalted(c, entered, uncertain) = StateFields
        /\ "fenced" \in DOMAIN JoinHeadHalted(c, entered, uncertain)
  BY <1>0a, FunctionExceptPreservesDomain DEF JoinHeadHalted, StateFields
<1>0c. /\ \A field \in
             {"headBorrow", "projection", "published", "accepted", "unknown",
              "authority", "absent", "abandoned"} :
             "unknownEpisode" # field /\ "halted" # field /\ "fenced" # field
        /\ "halted" # "unknownEpisode"
        /\ "fenced" # "unknownEpisode"
        /\ "fenced" # "halted"
  OBVIOUS
<1>1. DOMAIN s' = StateFields
  BY <1>0b, FunctionExceptPreservesDomain DEF JoinHead, JoinHeadState
<1>2. s'.headBorrow = {}
  BY <1>0, <1>0a, <1>0b, <1>0c, FunctionExceptAtOther
     DEF JoinHead, JoinHeadState, JoinHeadHalted, JoinHeadEpisode, JoinHeadPrefix, StateFields
<1>3. s'.projection = IF entered /\ ~uncertain THEN s.projection ELSE {}
  BY <1>0, <1>0a, <1>0b, <1>0c, FunctionExceptAtOther
     DEF JoinHead, JoinHeadState, JoinHeadHalted, JoinHeadEpisode, JoinHeadPrefix, StateFields
<1>4. s'.published = IF entered THEN s.published \cup {c} ELSE s.published
  BY <1>0, <1>0a, <1>0b, <1>0c, FunctionExceptAtOther
     DEF JoinHead, JoinHeadState, JoinHeadHalted, JoinHeadEpisode, JoinHeadPrefix, StateFields
<1>5. s'.accepted = IF entered /\ ~uncertain THEN s.accepted \cup {c} ELSE s.accepted
  BY <1>0, <1>0a, <1>0b, <1>0c, FunctionExceptAtOther
     DEF JoinHead, JoinHeadState, JoinHeadHalted, JoinHeadEpisode, JoinHeadPrefix, StateFields
<1>6. s'.unknown = IF uncertain THEN s.unknown \cup {c} ELSE s.unknown
  BY <1>0, <1>0a, <1>0b, <1>0c, FunctionExceptAtOther
     DEF JoinHead, JoinHeadState, JoinHeadHalted, JoinHeadEpisode, JoinHeadPrefix, StateFields
<1>7. s'.authority = IF uncertain THEN s.authority \cup Members(c) ELSE s.authority
  BY <1>0, <1>0a, <1>0b, <1>0c, FunctionExceptAtOther
     DEF JoinHead, JoinHeadState, JoinHeadHalted, JoinHeadEpisode, JoinHeadPrefix, StateFields
<1>8. s'.absent = IF ~entered /\ ~uncertain THEN s.absent \cup {c} ELSE s.absent
  BY <1>0, <1>0a, <1>0b, <1>0c, FunctionExceptAtOther
     DEF JoinHead, JoinHeadState, JoinHeadHalted, JoinHeadEpisode, JoinHeadPrefix, StateFields
<1>9. s'.abandoned = IF ~entered /\ ~uncertain THEN s.abandoned \cup {c}
                    ELSE s.abandoned
  BY <1>0, <1>0a, <1>0b, <1>0c, FunctionExceptAtOther
     DEF JoinHead, JoinHeadState, JoinHeadHalted, JoinHeadEpisode, JoinHeadPrefix, StateFields
<1>10. s'.unknownEpisode = (s.unknownEpisode \/ uncertain)
  <2>1. JoinHeadEpisode(c, entered, uncertain).unknownEpisode =
           (s.unknownEpisode \/ uncertain)
    BY ONLY <1>0, FunctionExceptAtSame,
       [JoinHeadPrefix(c, entered, uncertain) EXCEPT
        !["unknownEpisode"] = s.unknownEpisode \/ uncertain]["unknownEpisode"] =
          (s.unknownEpisode \/ uncertain)
       DEF JoinHeadEpisode
  <2>2. JoinHeadHalted(c, entered, uncertain).unknownEpisode =
           JoinHeadEpisode(c, entered, uncertain).unknownEpisode
    BY <1>0a, <1>0c, FunctionExceptAtOther DEF JoinHeadHalted, StateFields
  <2>3. JoinHeadState(c, entered, uncertain).unknownEpisode =
           JoinHeadHalted(c, entered, uncertain).unknownEpisode
    BY <1>0b, <1>0c, FunctionExceptAtOther DEF JoinHeadState, StateFields
  <2> QED BY <2>1, <2>2, <2>3 DEF JoinHead
<1>11. s'.halted = (s.halted \/ uncertain \/ ~entered)
  <2>1. JoinHeadHalted(c, entered, uncertain).halted =
           (s.halted \/ uncertain \/ ~entered)
    BY ONLY <1>0a, FunctionExceptAtSame,
       [JoinHeadEpisode(c, entered, uncertain) EXCEPT
        !["halted"] = s.halted \/ uncertain \/ ~entered]["halted"] =
          (s.halted \/ uncertain \/ ~entered)
       DEF JoinHeadHalted
  <2>2. JoinHeadState(c, entered, uncertain).halted =
           JoinHeadHalted(c, entered, uncertain).halted
    BY <1>0b, <1>0c, FunctionExceptAtOther DEF JoinHeadState, StateFields
  <2> QED BY <2>1, <2>2 DEF JoinHead
<1>12. s'.fenced = (s.fenced \/ (~entered /\ ~uncertain))
  <2>1. JoinHeadState(c, entered, uncertain).fenced =
           (s.fenced \/ (~entered /\ ~uncertain))
    BY ONLY <1>0b, FunctionExceptAtSame,
       [JoinHeadHalted(c, entered, uncertain) EXCEPT
        !["fenced"] = s.fenced \/ (~entered /\ ~uncertain)]["fenced"] =
          (s.fenced \/ (~entered /\ ~uncertain))
       DEF JoinHeadState
  <2> QED BY <2>1 DEF JoinHead
<1>13. \A field \in StateFields \
              {"headBorrow", "projection", "published", "accepted", "unknown",
               "authority", "absent", "abandoned", "unknownEpisode", "halted", "fenced"} :
          s'[field] = s[field]
  <2> SUFFICES ASSUME NEW field \in StateFields \
            {"headBorrow", "projection", "published", "accepted", "unknown",
             "authority", "absent", "abandoned", "unknownEpisode", "halted", "fenced"}
        PROVE s'[field] = s[field]
    OBVIOUS
  <2>1. /\ field \in
               StateFields \ {"headBorrow", "projection", "published", "accepted", "unknown",
                              "authority", "absent", "abandoned"}
         /\ field # "unknownEpisode" /\ field # "halted" /\ field # "fenced"
    OBVIOUS
  <2>2. JoinHeadPrefix(c, entered, uncertain)[field] = s[field]
    BY <2>1, JoinHeadPrefixFrame
  <2>3. JoinHeadEpisode(c, entered, uncertain)[field] =
           JoinHeadPrefix(c, entered, uncertain)[field]
    BY ONLY <1>0, <2>1, FunctionExceptAtOther,
       [JoinHeadPrefix(c, entered, uncertain) EXCEPT
        !["unknownEpisode"] = s.unknownEpisode \/ uncertain][field] =
          JoinHeadPrefix(c, entered, uncertain)[field]
       DEF JoinHeadEpisode
  <2>4. JoinHeadHalted(c, entered, uncertain)[field] =
           JoinHeadEpisode(c, entered, uncertain)[field]
    BY ONLY <1>0a, <2>1, FunctionExceptAtOther,
       [JoinHeadEpisode(c, entered, uncertain) EXCEPT
        !["halted"] = s.halted \/ uncertain \/ ~entered][field] =
          JoinHeadEpisode(c, entered, uncertain)[field]
       DEF JoinHeadHalted
  <2>5. JoinHeadState(c, entered, uncertain)[field] =
           JoinHeadHalted(c, entered, uncertain)[field]
    BY ONLY <1>0b, <2>1, FunctionExceptAtOther,
       [JoinHeadHalted(c, entered, uncertain) EXCEPT
        !["fenced"] = s.fenced \/ (~entered /\ ~uncertain)][field] =
          JoinHeadHalted(c, entered, uncertain)[field]
       DEF JoinHeadState
  <2> QED BY <2>2, <2>3, <2>4, <2>5 DEF JoinHead
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9,
    <1>10, <1>11, <1>12, <1>13

RetirePrefix(c) ==
    [s EXCEPT !.accepted = s.accepted \ {c}, !.owned = s.owned \ {c},
         !.retired = s.retired \cup {c},
         !.projection = {},
         !.ack = s.ack \cup Members(c)]

THEOREM RetirePrefixFrame ==
    ASSUME NEW c \in CohortDomain,
        DOMAIN s = StateFields
    PROVE \A field \in
              StateFields \ {"accepted", "owned", "retired", "projection", "ack"} :
              RetirePrefix(c)[field] = s[field]
<1> QED BY DEF RetirePrefix, StateFields

RetireFenced(c, localFailure) ==
    [RetirePrefix(c) EXCEPT !.fenced = s.fenced \/ localFailure]

RetireState(c, localFailure) ==
    [RetireFenced(c, localFailure) EXCEPT !.halted = s.halted \/ localFailure]

Retire(c, localFailure) ==
    /\ c \in s.accepted \cap s.published /\ localFailure \in BOOLEAN
    /\ s' = RetireState(c, localFailure)

THEOREM RetireProjection ==
    ASSUME NEW c \in CohortDomain,
        NEW localFailure \in BOOLEAN,
        DOMAIN s = StateFields,
        Retire(c, localFailure)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.accepted = s.accepted \ {c}
          /\ s'.owned = s.owned \ {c}
          /\ s'.retired = s.retired \cup {c}
          /\ s'.projection = {}
          /\ s'.ack = s.ack \cup Members(c)
          /\ s'.fenced = (s.fenced \/ localFailure)
          /\ s'.halted = (s.halted \/ localFailure)
          /\ \A field \in StateFields \
               {"accepted", "owned", "retired", "projection", "ack", "fenced", "halted"} :
               s'[field] = s[field]
<1>0. /\ DOMAIN RetirePrefix(c) = StateFields
       /\ "fenced" \in DOMAIN RetirePrefix(c)
  BY DEF RetirePrefix, StateFields
<1>0a. /\ DOMAIN RetireFenced(c, localFailure) = StateFields
        /\ "halted" \in DOMAIN RetireFenced(c, localFailure)
  BY <1>0, FunctionExceptPreservesDomain DEF RetireFenced, StateFields
<1>0b. /\ \A field \in {"accepted", "owned", "retired", "projection", "ack"} :
             "fenced" # field /\ "halted" # field
        /\ "halted" # "fenced"
  OBVIOUS
<1>1. DOMAIN s' = StateFields
  BY <1>0a, FunctionExceptPreservesDomain DEF Retire, RetireState
<1>2. s'.accepted = s.accepted \ {c}
  BY <1>0, <1>0a, <1>0b, FunctionExceptAtOther
     DEF Retire, RetireState, RetireFenced, RetirePrefix, StateFields
<1>3. s'.owned = s.owned \ {c}
  BY <1>0, <1>0a, <1>0b, FunctionExceptAtOther
     DEF Retire, RetireState, RetireFenced, RetirePrefix, StateFields
<1>4. s'.retired = s.retired \cup {c}
  BY <1>0, <1>0a, <1>0b, FunctionExceptAtOther
     DEF Retire, RetireState, RetireFenced, RetirePrefix, StateFields
<1>5. s'.projection = {}
  BY <1>0, <1>0a, <1>0b, FunctionExceptAtOther
     DEF Retire, RetireState, RetireFenced, RetirePrefix, StateFields
<1>6. s'.ack = s.ack \cup Members(c)
  BY <1>0, <1>0a, <1>0b, FunctionExceptAtOther
     DEF Retire, RetireState, RetireFenced, RetirePrefix, StateFields
<1>7. s'.fenced = (s.fenced \/ localFailure)
  <2>1. RetireFenced(c, localFailure).fenced = (s.fenced \/ localFailure)
    BY ONLY <1>0, FunctionExceptAtSame,
       [RetirePrefix(c) EXCEPT !["fenced"] = s.fenced \/ localFailure]["fenced"] =
         (s.fenced \/ localFailure)
       DEF RetireFenced
  <2>2. RetireState(c, localFailure).fenced = RetireFenced(c, localFailure).fenced
    BY <1>0a, <1>0b, FunctionExceptAtOther DEF RetireState, StateFields
  <2> QED BY <2>1, <2>2 DEF Retire
<1>8. s'.halted = (s.halted \/ localFailure)
  <2>1. RetireState(c, localFailure).halted = (s.halted \/ localFailure)
    BY ONLY <1>0a, FunctionExceptAtSame,
       [RetireFenced(c, localFailure) EXCEPT !["halted"] = s.halted \/ localFailure]["halted"] =
         (s.halted \/ localFailure)
       DEF RetireState
  <2> QED BY <2>1 DEF Retire
<1>9. \A field \in StateFields \
              {"accepted", "owned", "retired", "projection", "ack", "fenced", "halted"} :
          s'[field] = s[field]
  <2> SUFFICES ASSUME NEW field \in StateFields \
            {"accepted", "owned", "retired", "projection", "ack", "fenced", "halted"}
        PROVE s'[field] = s[field]
    OBVIOUS
  <2>1. /\ field \in StateFields \ {"accepted", "owned", "retired", "projection", "ack"}
         /\ field # "fenced" /\ field # "halted"
    OBVIOUS
  <2>2. RetirePrefix(c)[field] = s[field]
    BY <2>1, RetirePrefixFrame
  <2>3. RetireFenced(c, localFailure)[field] = RetirePrefix(c)[field]
    BY ONLY <1>0, <2>1, FunctionExceptAtOther,
       [RetirePrefix(c) EXCEPT !["fenced"] = s.fenced \/ localFailure][field] =
         RetirePrefix(c)[field]
       DEF RetireFenced
  <2>4. RetireState(c, localFailure)[field] = RetireFenced(c, localFailure)[field]
    BY ONLY <1>0a, <2>1, FunctionExceptAtOther,
       [RetireFenced(c, localFailure) EXCEPT
        !["halted"] = s.halted \/ localFailure][field] = RetireFenced(c, localFailure)[field]
       DEF RetireState
  <2> QED BY <2>2, <2>3, <2>4 DEF Retire
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9

PendingBorrowed == {t \in s.pending : Fragment(t) \in s.prepareBorrow}
PendingReleased ==
    Inputs(s.pending \ PendingBorrowed) \cup Fragments(s.pending \ PendingBorrowed)
AbandonPending ==
    /\ s.halted \/ s.fenced
    /\ s' = [s EXCEPT !.pending = {}, !.rejected = s.rejected \cup s.pending,
          !.buffers = Release(s.buffers, PendingReleased)]

THEOREM AbandonPendingProjection ==
    ASSUME DOMAIN s = StateFields, AbandonPending
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.pending = {}
          /\ s'.rejected = s.rejected \cup s.pending
          /\ s'.buffers = Release(s.buffers, PendingReleased)
          /\ \A field \in StateFields \ {"pending", "rejected", "buffers"} :
               s'[field] = s[field]
<1> QED BY DEF AbandonPending, StateFields

MarkAbandoned(c) ==
    /\ c \in s.owned /\ (c \notin s.headCalls \/ c \in s.absent)
    /\ s.halted \/ s.fenced \/ Earlier(c) \cap s.excluded # {}
    /\ c \notin s.projection
    /\ s' = [s EXCEPT !.abandoned = s.abandoned \cup {c}, !.ready = s.ready \ {c},
          !.halted = TRUE]
DrainAbandoned(c) ==
    /\ c \in s.owned \cap s.abandoned
    /\ c \notin s.batchBorrow \cup s.headBorrow /\ Batch(c) \notin s.prepareBorrow
    /\ c \notin s.projection
    /\ c \notin s.headCalls \/ c \in s.absent
    /\ s' = [s EXCEPT !.owned = s.owned \ {c}, !.unknown = s.unknown \ {c},
          !.excluded = s.excluded \cup {c}, !.ready = s.ready \ {c},
          !.prepareFailed = s.prepareFailed \ {c}, !.batchFailed = s.batchFailed \ {c},
          !.buffers = Release(s.buffers, Fragments(Members(c)))]

THEOREM DrainAbandonedProjection ==
    ASSUME NEW c \in CohortDomain,
        DOMAIN s = StateFields,
        DrainAbandoned(c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.owned = s.owned \ {c}
          /\ s'.unknown = s.unknown \ {c}
          /\ s'.excluded = s.excluded \cup {c}
          /\ s'.ready = s.ready \ {c}
          /\ s'.prepareFailed = s.prepareFailed \ {c}
          /\ s'.batchFailed = s.batchFailed \ {c}
          /\ s'.buffers = Release(s.buffers, Fragments(Members(c)))
          /\ \A field \in StateFields \
               {"owned", "unknown", "excluded", "ready", "prepareFailed",
                "batchFailed", "buffers"} : s'[field] = s[field]
<1> QED BY DEF DrainAbandoned, StateFields
ResolveFront(t, c) ==
    /\ s.online /\ t \in s.authority \cap s.delivered \cap Members(c) \cap s.collected
    /\ s.admitted = s.collected
    /\ c \in s.unknown \cap s.published /\ DrainedFor(c)
    /\ s' = [s EXCEPT !.unknown = s.unknown \ {c}, !.owned = s.owned \ {c},
          !.retired = s.retired \cup {c}, !.ack = s.ack \cup {t},
          !.authority = s.authority \ {t}]
ResolveDetached(t, c) ==
    /\ s.online /\ t \in s.authority \cap s.delivered \cap Members(c) \cap s.collected
    /\ c \in s.retired
    /\ s.admitted = s.collected
    /\ s' = [s EXCEPT !.ack = s.ack \cup {t}, !.authority = s.authority \ {t}]
\* Exact read-only observation may conclude absence before or after detach/reopen.
ConcludeAbsent(t, c) ==
    /\ s.online /\ t \in s.authority \cap s.delivered \cap Members(c) \cap s.collected
    /\ c \in (s.headCalls \ s.published) \ s.absent
    /\ (c \in s.unknown /\ DrainedFor(c) \/ c \notin s.owned)
    /\ s.admitted = s.collected
    /\ s' = [s EXCEPT !.absent = s.absent \cup {c}, !.authority = s.authority \ {t},
          !.fenced = TRUE, !.halted = TRUE]
ResolveRejected(t, c) ==
    /\ s.online /\ t \in s.authority \cap s.delivered \cap Members(c) \cap s.collected
    /\ c \in s.absent /\ s.admitted = s.collected
    /\ s' = [s EXCEPT !.authority = @ \ {t}]
DetachUnknown(c) ==
    /\ s.closing /\ c \in s.unknown /\ DrainedFor(c)
    /\ s' = [s EXCEPT !.owned = s.owned \ {c}, !.unknown = s.unknown \ {c}]

THEOREM MarkAbandonedProjection ==
    ASSUME NEW c \in CohortDomain, DOMAIN s = StateFields, MarkAbandoned(c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.abandoned = s.abandoned \cup {c}
          /\ s'.ready = s.ready \ {c}
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"abandoned", "ready", "halted"} :
               s'[field] = s[field]
<1> QED BY DEF MarkAbandoned, StateFields

THEOREM FailPreparedFrontProjection ==
    ASSUME NEW c \in CohortDomain, DOMAIN s = StateFields, FailPreparedFront(c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.abandoned = s.abandoned \cup {c}
          /\ s'.ready = s.ready
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"abandoned", "halted"} :
               s'[field] = s[field]
<1> QED BY DEF FailPreparedFront, StateFields

THEOREM FailBatchFrontProjection ==
    ASSUME NEW c \in CohortDomain, DOMAIN s = StateFields, FailBatchFront(c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.abandoned = s.abandoned \cup {c}
          /\ s'.ready = s.ready
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"abandoned", "halted"} :
               s'[field] = s[field]
<1> QED BY DEF FailBatchFront, StateFields

THEOREM AuthorityDropProjection ==
    ASSUME NEW t \in MemberDomain,
        DOMAIN s = StateFields,
        s' = [s EXCEPT !.authority = s.authority \ {t}]
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.authority = s.authority \ {t}
          /\ \A field \in StateFields \ {"authority"} : s'[field] = s[field]
<1> QED BY DEF StateFields

THEOREM ResolveAuthorityProjection ==
    ASSUME NEW t \in MemberDomain,
        DOMAIN s = StateFields,
        s' = [s EXCEPT !.ack = s.ack \cup {t}, !.authority = s.authority \ {t}]
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.ack = s.ack \cup {t}
          /\ s'.authority = s.authority \ {t}
          /\ \A field \in StateFields \ {"ack", "authority"} : s'[field] = s[field]
<1> QED BY DEF StateFields

THEOREM ConcludeAbsentProjection ==
    ASSUME NEW t \in MemberDomain,
        NEW c \in CohortDomain,
        DOMAIN s = StateFields,
        ConcludeAbsent(t, c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.absent = s.absent \cup {c}
          /\ s'.authority = s.authority \ {t}
          /\ s'.fenced = TRUE
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"absent", "authority", "fenced", "halted"} :
               s'[field] = s[field]
<1> QED BY DEF ConcludeAbsent, StateFields

THEOREM DetachUnknownProjection ==
    ASSUME NEW c \in CohortDomain,
        DOMAIN s = StateFields,
        DetachUnknown(c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.owned = s.owned \ {c}
          /\ s'.unknown = s.unknown \ {c}
          /\ \A field \in StateFields \ {"owned", "unknown"} : s'[field] = s[field]
<1> QED BY DEF DetachUnknown, StateFields

THEOREM ResolveFrontProjection ==
    ASSUME NEW t \in MemberDomain,
        NEW c \in CohortDomain,
        DOMAIN s = StateFields,
        ResolveFront(t, c)
    PROVE /\ DOMAIN s' = StateFields
          /\ s'.unknown = s.unknown \ {c}
          /\ s'.owned = s.owned \ {c}
          /\ s'.retired = s.retired \cup {c}
          /\ s'.ack = s.ack \cup {t}
          /\ s'.authority = s.authority \ {t}
          /\ \A field \in StateFields \
               {"unknown", "owned", "retired", "ack", "authority"} :
               s'[field] = s[field]
<1> QED BY DEF ResolveFront, StateFields

RequestCancellation == UNCHANGED s
CollectTerminal(t) ==
    /\ t \in s.admitted \ s.collected
    /\ t \in s.ack \cup s.rejected \cup s.authority \cup UNION {Members(c) : c \in s.excluded}
    /\ Fragment(t) \notin s.prepareBorrow
    /\ CohortsOf({t}) \cap (s.batchBorrow \cup s.headBorrow) = {}
    /\ Batches(CohortsOf({t})) \cap s.prepareBorrow = {}
    /\ s' = [s EXCEPT !.collected = @ \cup {t}]
DeliverReceipt(t) ==
    /\ t \in s.collected \ (s.delivered \cup s.discarded)
    /\ t \in s.ack \cup s.rejected \cup s.authority \cup UNION {Members(c) : c \in s.excluded}
    /\ s' = [s EXCEPT !.delivered = @ \cup {t}]
BeginClose == s' = [s EXCEPT !.closing = TRUE]
Export(t) ==
    /\ t \in s.authority \cap s.delivered
    /\ s' = [s EXCEPT !.exported = @ \cup {t}]
Import(t) ==
    /\ s.online /\ t \in s.exported
    /\ s' = [s EXCEPT !.authority = @ \cup {t}]
Drop(t) ==
    /\ t \in s.authority \cap s.delivered
    /\ s' = [s EXCEPT !.authority = @ \ {t}]
DiscardCollected(t) ==
    /\ t \in s.collected \ (s.delivered \cup s.discarded)
    /\ t \in s.ack \cup s.rejected \cup s.authority \cup UNION {Members(c) : c \in s.excluded}
    /\ s' = [s EXCEPT !.authority = s.authority \ {t},
          !.discarded = s.discarded \cup {t}]
Collect(c) ==
    /\ c \notin s.owned \cup CohortsOf(s.authority \cup s.exported)
    /\ Batch(c) \notin s.prepareBorrow /\ c \notin s.batchBorrow \cup s.headBorrow
    /\ s' = [s EXCEPT !.buffers[Batch(c)] = {}]
Close ==
    /\ s.closing /\ s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {}
    /\ s.batchBorrow = {} /\ s.headBorrow = {}
    /\ s.admitted = s.collected
    /\ s' = [s EXCEPT !.online = FALSE]
CrashAfterReturn ==
    /\ s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\ s.batchBorrow = {} /\ s.headBorrow = {}
    /\ s.admitted = s.collected
    /\ s.authority \subseteq s.delivered
    /\ s' = [s EXCEPT !.online = FALSE, !.closing = TRUE, !.halted = TRUE, !.authority = {}]
Reopen ==
    /\ ~s.online
    /\ s' = [s EXCEPT !.online = TRUE, !.retired = s.published, !.halted = TRUE]

Next ==
    \/ \E t \in MemberDomain, bytes \in SUBSET ByteDomain : Admit(t, bytes) \/ StartTxnPrepare(t, bytes)
    \/ \E c \in CohortDomain, ts \in SUBSET MemberDomain, bytes \in SUBSET ByteDomain : Freeze(c, ts, bytes)
    \/ \E t \in MemberDomain, success \in BOOLEAN : JoinTxnPrepare(t, success)
    \/ \E c \in CohortDomain, success \in BOOLEAN :
         JoinBatchPrepare(c, success) \/ JoinBatch(c, success) \/ ValidateFront(c, success) \/
         Retire(c, success)
    \/ \E c \in CohortDomain, entered, uncertain \in BOOLEAN : JoinHead(c, entered, uncertain)
    \/ \E c \in CohortDomain : StartBatchPrepare(c) \/ StartBatch(c) \/ StartHead(c) \/
         FailPreparedFront(c) \/ FailBatchFront(c) \/ MarkAbandoned(c) \/ DrainAbandoned(c) \/
         DetachUnknown(c) \/ Collect(c)
    \/ \E t \in MemberDomain, c \in CohortDomain : ResolveFront(t, c) \/ ResolveDetached(t, c) \/
         ConcludeAbsent(t, c) \/ ResolveRejected(t, c)
    \/ \E t \in MemberDomain : CollectTerminal(t) \/ DeliverReceipt(t) \/ Export(t) \/ Import(t) \/
         Drop(t) \/ DiscardCollected(t)
    \/ AbandonPending \/ RequestCancellation \/ BeginClose \/ Close \/ CrashAfterReturn \/ Reopen
Spec == Init /\ [][Next]_vars

StateShape == DOMAIN s = StateFields
MemberStateTypes ==
    /\ s.admitted \subseteq MemberDomain /\ s.pending \subseteq MemberDomain
    /\ s.collected \subseteq s.admitted
    /\ s.delivered \subseteq s.collected
    /\ s.discarded \subseteq s.collected
    /\ s.prepared \subseteq MemberDomain /\ s.rejected \subseteq MemberDomain
PreparationMapTypes ==
    /\ s.groups \in [CohortDomain -> SUBSET MemberDomain]
    /\ s.buffers \in [Resources -> SUBSET ByteDomain]
    /\ s.prepareCalls \subseteq Work /\ s.prepareBorrow \subseteq Work
CohortStateTypes ==
    /\ s.sealed \subseteq CohortDomain /\ s.ready \subseteq CohortDomain
    /\ s.issued \subseteq CohortDomain /\ s.stored \subseteq CohortDomain
    /\ s.published \subseteq CohortDomain /\ s.retired \subseteq CohortDomain
    /\ s.excluded \subseteq CohortDomain /\ s.abandoned \subseteq CohortDomain
    /\ s.prepareFailed \subseteq CohortDomain /\ s.batchFailed \subseteq CohortDomain
    /\ s.validated \subseteq CohortDomain
    /\ s.projection \subseteq CohortDomain
PublicationStateTypes ==
    /\ s.batchCalls \subseteq CohortDomain /\ s.headCalls \subseteq CohortDomain
    /\ s.batchBorrow \subseteq CohortDomain /\ s.headBorrow \subseteq CohortDomain
    /\ s.owned \subseteq CohortDomain /\ s.accepted \subseteq CohortDomain
    /\ s.unknown \subseteq CohortDomain /\ s.absent \subseteq CohortDomain
AuthorityStateTypes ==
    /\ s.authority \subseteq MemberDomain /\ s.exported \subseteq MemberDomain /\ s.ack \subseteq MemberDomain
LifecycleStateTypes ==
    /\ s.closing \in BOOLEAN /\ s.online \in BOOLEAN /\ s.halted \in BOOLEAN /\ s.fenced \in BOOLEAN
    /\ s.unknownEpisode \in BOOLEAN /\ s.resolutionWrites \in Nat
TypeOK == StateShape /\ MemberStateTypes /\ PreparationMapTypes /\ CohortStateTypes /\
          PublicationStateTypes /\ AuthorityStateTypes /\ LifecycleStateTypes

AdmissionMembership == s.pending \cup s.prepared \cup s.rejected \subseteq s.admitted
BoundMembership ==
    /\ BoundMembers \subseteq s.prepared /\ s.pending \cap BoundMembers = {}
GroupPartition ==
    /\ \A c \in CohortDomain : (c \in s.issued <=> Members(c) # {})
    /\ \A c, d \in CohortDomain : c # d => Members(c) \cap Members(d) = {}
    /\ \A c \in s.issued : Cardinality(Members(c)) <= MemberCapacity
AuthorityMembership ==
    /\ s.authority \cup s.exported \cup s.ack \subseteq BoundMembers
    /\ s.rejected \cap BoundMembers = {}
TerminalMembership ==
    /\ s.rejected \cap s.pending = {}
    /\ s.collected \cap s.pending = {}
    /\ s.delivered \subseteq s.collected
    /\ s.discarded \subseteq s.collected
    /\ s.delivered \cap s.discarded = {}
    /\ CohortsOf(s.collected) \subseteq s.headCalls \cup s.excluded
    /\ CohortsOf(s.collected) \cap (s.batchBorrow \cup s.headBorrow) = {}
    /\ Batches(CohortsOf(s.collected)) \cap s.prepareBorrow = {}
MembershipSafety == AdmissionMembership /\ BoundMembership /\ GroupPartition /\
                    AuthorityMembership /\ TerminalMembership

THEOREM FreezeBoundMembersValue ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        StateShape,
        PreparationMapTypes,
        CohortStateTypes,
        GroupPartition,
        Freeze(c, ts, bytes)
    PROVE BoundMembers' = BoundMembers \cup ts
<1>0. FreezeFieldsPresent
  BY StateShapeProvidesFreezeFields DEF StateShape
<1>1. /\ s'.groups = [s.groups EXCEPT ![c] = ts]
       /\ s'.issued = s.issued \cup {c}
  BY FreezeStateChangedValues, <1>0 DEF Freeze
<1>1a. \A d \in CohortDomain : s'.groups[d] = IF d = c THEN ts ELSE s.groups[d]
  BY FreezeStateGroupAt, <1>0 DEF Freeze, PreparationMapTypes
<1>2. BoundMembers' \subseteq BoundMembers \cup ts
  <2> SUFFICES ASSUME NEW t \in BoundMembers'
               PROVE t \in BoundMembers \cup ts
    OBVIOUS
  <2>1. PICK d \in s'.issued : t \in s'.groups[d]
    BY DEF BoundMembers, Members
  <2>2. CASE d = c
    BY <1>1a, <2>1, <2>2
  <2>3. CASE d # c
    <3>0. d \in CohortDomain
      BY <1>1, <2>1, <2>3 DEF CohortStateTypes
    <3>1. d \in s.issued
      BY <1>1, <2>1, <2>3
    <3>2. s'.groups[d] = s.groups[d]
      BY <1>1a, <2>1, <2>3, <3>0
    <3>3. t \in BoundMembers
      BY <2>1, <3>1, <3>2 DEF BoundMembers, Members
    <3> QED BY <3>3
  <2> QED BY <2>2, <2>3
<1>3. BoundMembers \cup ts \subseteq BoundMembers'
  <2> SUFFICES ASSUME NEW t \in BoundMembers \cup ts
               PROVE t \in BoundMembers'
    OBVIOUS
  <2>1. CASE t \in BoundMembers
    <3>1. PICK d \in s.issued : t \in s.groups[d]
      BY <2>1 DEF BoundMembers, Members
    <3>1a. d \in CohortDomain
      BY <3>1 DEF CohortStateTypes
    <3>2. d \in s'.issued /\ d # c
      BY <1>1, <2>1, <3>1 DEF Freeze
    <3>3. s'.groups[d] = s.groups[d]
      BY <1>1a, <2>1, <3>1a, <3>2
    <3> QED BY <3>1, <3>2, <3>3 DEF BoundMembers, Members
  <2>2. CASE t \in ts
    BY <1>1, <1>1a, <2>2 DEF BoundMembers, Members
  <2> QED BY <2>1, <2>2
<1> QED BY <1>2, <1>3

THEOREM FreezeCollectedCohortsValue ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        StateShape,
        PreparationMapTypes,
        CohortStateTypes,
        GroupPartition,
        TerminalMembership,
        Freeze(c, ts, bytes)
    PROVE (CohortsOf(s.collected))' = CohortsOf(s.collected)
<1>0. FreezeFieldsPresent
  BY StateShapeProvidesFreezeFields DEF StateShape
<1>1. s'.collected = s.collected
  BY FreezeStatePreservesMemberFields, <1>0 DEF Freeze, StateShape
<1>1a. s'.issued = s.issued \cup {c}
  BY FreezeStateChangedValues, <1>0 DEF Freeze
<1>1b. \A d \in CohortDomain : s'.groups[d] = IF d = c THEN ts ELSE s.groups[d]
  BY FreezeStateGroupAt, <1>0 DEF Freeze, PreparationMapTypes
<1>2. ts \cap s.collected = {}
  BY DEF Freeze, TerminalMembership
<1>3. c \notin s.issued /\ Members(c) = {}
  BY DEF Freeze, GroupPartition, Members
<1>4. (CohortsOf(s.collected))' \subseteq CohortsOf(s.collected)
  BY <1>1, <1>1a, <1>1b, <1>2, <1>3
     DEF CohortStateTypes, CohortsOf, Members
<1>5. CohortsOf(s.collected) \subseteq (CohortsOf(s.collected))'
  BY <1>1, <1>1a, <1>1b, <1>3 DEF CohortStateTypes, CohortsOf, Members
<1> QED BY ONLY <1>4, <1>5 DEF CohortsOf

PublicationOrder ==
    /\ s.retired \subseteq s.published /\ s.published \subseteq s.headCalls
    /\ s.headCalls \subseteq s.validated /\ s.validated \subseteq s.stored
    /\ s.stored \subseteq s.batchCalls
    /\ s.batchCalls \subseteq s.sealed /\ s.sealed \subseteq s.issued
PublicationExclusion ==
    /\ s.excluded \subseteq s.issued /\ s.excluded \cap s.owned = {}
    /\ s.excluded \cap s.published = {} /\ s.absent \cap s.published = {}
    /\ s.abandoned \cap s.published = {}
PublicationPredecessorOrder == \A c \in s.headCalls : Earlier(c) \subseteq s.retired
PublicationAcknowledgement == CohortsOf(s.ack) \subseteq s.published
PublicationSafety == PublicationOrder /\ PublicationExclusion /\
                     PublicationPredecessorOrder /\ PublicationAcknowledgement
Ownership ==
    /\ s.owned \subseteq s.issued
    /\ Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated
    /\ s.ready \subseteq (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned)
    /\ s.batchBorrow \cup s.headBorrow \subseteq s.owned
    /\ s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls
    /\ s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {}
    /\ s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow
    /\ s.unknown \subseteq (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted)
    /\ s.absent \subseteq s.headCalls \ s.headBorrow
    /\ s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls)
    /\ Batches(s.prepareFailed) \subseteq s.prepareCalls \ s.prepareBorrow
    /\ s.batchFailed \subseteq
         (s.owned \cap s.batchCalls) \ (s.batchBorrow \cup s.stored \cup s.headCalls)
    /\ s.projection \subseteq (s.owned \cap s.validated) \ s.abandoned
    /\ s.headBorrow \cup s.accepted \subseteq s.projection
    /\ (s.unknown \cup s.absent) \cap s.projection = {}
    /\ s.headBorrow # {} => s.unknown = {}
    /\ ~s.online => s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
                     s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected
PreparationOwnership ==
    /\ s.prepareBorrow \subseteq s.prepareCalls \cap Allocated
    /\ \A t \in MemberDomain :
         Fragment(t) \in s.prepareBorrow =>
           Input(t) \in Allocated /\ t \in s.admitted \ BoundMembers
    /\ \A c \in CohortDomain :
         Batch(c) \in s.prepareBorrow => c \in s.owned /\ Fragments(Members(c)) \subseteq Allocated
    /\ \A t \in s.prepared : Fragment(t) \in s.prepareCalls \ s.prepareBorrow
    /\ \A t \in s.prepared : Input(t) \notin Allocated
    /\ \A c \in s.sealed : Batch(c) \in s.prepareCalls \ s.prepareBorrow
    /\ \A t \in MemberDomain : Input(t) \in Allocated => t \in s.pending \/ Fragment(t) \in s.prepareBorrow
ResourceBounds ==
    /\ Cardinality(LiveMembers) <= QueueCapacity /\ Cardinality(s.owned) <= Capacity
    /\ Cardinality(s.ready) <= Capacity /\ Cardinality(s.headBorrow) <= 1
    /\ Cardinality(s.projection) <= 1
    /\ Cardinality(s.prepareBorrow) <= PrepareCapacity
    /\ Cardinality(UsedBytes) <= Cardinality(ByteDomain)
    /\ \A left, right \in Resources : left # right => s.buffers[left] \cap s.buffers[right] = {}
AuthoritySafety ==
    /\ CohortsOf(s.authority \cup s.exported) \subseteq s.headCalls \ s.headBorrow
    /\ s.headBorrow \cap s.abandoned = {}
    /\ s.unknownEpisode => s.halted
    /\ s.exported \subseteq s.delivered /\ s.delivered \subseteq s.collected
    /\ s.authority \cap s.discarded = {}
    /\ s.resolutionWrites = 0
Safety == TypeOK /\ MembershipSafety /\ PublicationSafety /\ Ownership /\
          PreparationOwnership /\ ResourceBounds /\ AuthoritySafety

(***************************************************************************
Project the inductive invariant without unfolding unrelated components in
every transition leaf.  These projections keep strict SMT obligations small
while preserving the single Safety theorem and its complete conjunction.
***************************************************************************)
THEOREM SafetyTypeOK ==
    ASSUME Safety
    PROVE TypeOK
<1> QED BY DEF Safety

THEOREM SafetyMembership ==
    ASSUME Safety
    PROVE MembershipSafety
<1> QED BY DEF Safety

THEOREM SafetyPublication ==
    ASSUME Safety
    PROVE PublicationSafety
<1> QED BY DEF Safety

THEOREM SafetyOwnership ==
    ASSUME Safety
    PROVE Ownership
<1> QED BY DEF Safety

THEOREM SafetyPreparationOwnership ==
    ASSUME Safety
    PROVE PreparationOwnership
<1> QED BY DEF Safety

THEOREM SafetyResourceBounds ==
    ASSUME Safety
    PROVE ResourceBounds
<1> QED BY DEF Safety

THEOREM SafetyAuthority ==
    ASSUME Safety
    PROVE AuthoritySafety
<1> QED BY DEF Safety

THEOREM MarkUnpublishedPreserves ==
    ASSUME NEW c \in CohortDomain,
        ConstantsOK,
        Safety,
        c \notin s.published,
        c \notin s.projection,
        DOMAIN s' = StateFields,
        s'.abandoned = s.abandoned \cup {c},
        s'.ready = s.ready \ {c},
        s'.halted = TRUE,
        \A field \in StateFields \ {"abandoned", "ready", "halted"} :
            s'[field] = s[field]
    PROVE Safety'
<1>0. c \notin s.headBorrow
  BY SafetyOwnership DEF Ownership
<1>1. TypeOK'
  BY SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
     PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  BY SafetyMembership
     DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
     AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
     Batches, StateFields
<1>3. PublicationSafety'
  BY SafetyPublication
     DEF PublicationSafety, PublicationOrder, PublicationExclusion,
     PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
     StateFields
<1>4. Ownership'
  BY <1>0, SafetyOwnership, FS_Subset
     DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
<1>5. PreparationOwnership'
  BY SafetyPreparationOwnership
     DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
<1>6. ResourceBounds'
  BY SafetyResourceBounds, SafetyTypeOK, FS_Subset, FS_CardinalityType
     DEF ResourceBounds, TypeOK, CohortStateTypes, UsedBytes, LiveMembers, StateFields,
     ConstantsOK
<1>7. AuthoritySafety'
  BY <1>0, SafetyAuthority
     DEF AuthoritySafety, CohortsOf, Members, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM AuthorityDropPreserves ==
    ASSUME NEW t \in MemberDomain,
        ConstantsOK,
        Safety,
        DOMAIN s' = StateFields,
        s'.authority = s.authority \ {t},
        \A field \in StateFields \ {"authority"} : s'[field] = s[field]
    PROVE Safety'
<1>1. TypeOK'
  BY SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
     PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  BY SafetyMembership, FS_Subset
     DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
     AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
     Batches, StateFields
<1>3. PublicationSafety'
  BY SafetyPublication
     DEF PublicationSafety, PublicationOrder, PublicationExclusion,
     PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
     StateFields
<1>4. Ownership'
  BY SafetyOwnership, FS_Subset
     DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
<1>5. PreparationOwnership'
  BY SafetyPreparationOwnership
     DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
<1>6. ResourceBounds'
  BY SafetyResourceBounds
     DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
<1>7. AuthoritySafety'
  BY SafetyAuthority, FS_Subset
     DEF AuthoritySafety, CohortsOf, Members, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM ResolveAuthorityPreserves ==
    ASSUME NEW t \in MemberDomain,
        NEW c \in CohortDomain,
        ConstantsOK,
        Safety,
        t \in BoundMembers,
        c \in s.published,
        DOMAIN s' = StateFields,
        s'.ack = s.ack \cup {t},
        s'.authority = s.authority \ {t},
        (CohortsOf(s.ack))' \subseteq CohortsOf(s.ack) \cup {c},
        \A field \in StateFields \ {"ack", "authority"} : s'[field] = s[field]
    PROVE Safety'
<1>1. TypeOK'
  BY SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
     PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  BY SafetyMembership, FS_Subset
     DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
     AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
     Batches, StateFields
<1>3. PublicationSafety'
  BY SafetyPublication, FS_Subset
     DEF PublicationSafety, PublicationOrder, PublicationExclusion,
     PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
     StateFields
<1>4. Ownership'
  BY SafetyOwnership, FS_Subset
     DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
<1>5. PreparationOwnership'
  BY SafetyPreparationOwnership
     DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
<1>6. ResourceBounds'
  BY SafetyResourceBounds
     DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
<1>7. AuthoritySafety'
  BY SafetyAuthority, FS_Subset
     DEF AuthoritySafety, CohortsOf, Members, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM ConcludeAuthorityAbsentPreserves ==
    ASSUME NEW t \in MemberDomain,
        NEW c \in CohortDomain,
        ConstantsOK,
        Safety,
        c \in s.headCalls \ s.headBorrow,
        c \notin s.published,
        c \notin s.projection,
        DOMAIN s' = StateFields,
        s'.absent = s.absent \cup {c},
        s'.authority = s.authority \ {t},
        s'.fenced = TRUE,
        s'.halted = TRUE,
        \A field \in StateFields \ {"absent", "authority", "fenced", "halted"} :
            s'[field] = s[field]
    PROVE Safety'
<1>1. TypeOK'
  BY SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
     PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  BY SafetyMembership, FS_Subset
     DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
     AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
     Batches, StateFields
<1>3. PublicationSafety'
  BY SafetyPublication, FS_Subset
     DEF PublicationSafety, PublicationOrder, PublicationExclusion,
     PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
     StateFields
<1>4. Ownership'
  BY SafetyOwnership, FS_Subset
     DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
<1>5. PreparationOwnership'
  BY SafetyPreparationOwnership
     DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
<1>6. ResourceBounds'
  BY SafetyResourceBounds
     DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
<1>7. AuthoritySafety'
  BY SafetyAuthority, FS_Subset
     DEF AuthoritySafety, CohortsOf, Members, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM DetachUnknownPreserves ==
    ASSUME NEW c \in CohortDomain,
        ConstantsOK,
        Safety,
        c \in s.unknown,
        DrainedFor(c),
        DOMAIN s' = StateFields,
        s'.owned = s.owned \ {c},
        s'.unknown = s.unknown \ {c},
        \A field \in StateFields \ {"owned", "unknown"} : s'[field] = s[field]
    PROVE Safety'
<1>1. TypeOK'
  BY SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
     PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  BY SafetyMembership
     DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
     AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
     Batches, StateFields
<1>3. PublicationSafety'
  BY SafetyPublication
     DEF PublicationSafety, PublicationOrder, PublicationExclusion,
     PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
     StateFields
<1>4. Ownership'
  <2>1. s'.owned = {}
    BY DEF DrainedFor
  <2>2. s.unknown = {c}
    BY SafetyOwnership DEF Ownership, DrainedFor
  <2>3. s'.unknown = {}
    BY <2>2
  <2>4. c \in s.headCalls
    BY SafetyOwnership DEF Ownership
  <2>5. c \in s.batchCalls
    BY <2>4, SafetyPublication DEF PublicationSafety, PublicationOrder
  <2>6. s.ready = {}
    BY <2>5, SafetyOwnership DEF Ownership, DrainedFor
  <2>7. s.accepted = {}
    BY <2>2, SafetyOwnership DEF Ownership, DrainedFor
  <2>8. s.prepareFailed = {}
    BY <2>5, SafetyOwnership DEF Ownership, DrainedFor
  <2>9. s.batchFailed = {}
    BY <2>4, SafetyOwnership DEF Ownership, DrainedFor
  <2>10. s.projection = {}
    BY <2>2, SafetyOwnership DEF Ownership, DrainedFor
  <2> QED BY <2>1, <2>3, <2>6, <2>7, <2>8, <2>9, <2>10,
       SafetyOwnership, FS_Subset
     DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields,
     DrainedFor
<1>5. PreparationOwnership'
  BY SafetyPreparationOwnership
     DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields,
     DrainedFor
<1>6. ResourceBounds'
  BY SafetyResourceBounds, SafetyTypeOK, FS_Subset, FS_CardinalityType
     DEF ResourceBounds, TypeOK, PublicationStateTypes, UsedBytes, LiveMembers,
     StateFields, ConstantsOK, DrainedFor
<1>7. AuthoritySafety'
  BY SafetyAuthority
     DEF AuthoritySafety, CohortsOf, Members, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM ResolveFrontPreserves ==
    ASSUME NEW t \in MemberDomain,
        NEW c \in CohortDomain,
        ConstantsOK,
        Safety,
        t \in BoundMembers,
        c \in s.unknown \cap s.published,
        DrainedFor(c),
        DOMAIN s' = StateFields,
        s'.unknown = s.unknown \ {c},
        s'.owned = s.owned \ {c},
        s'.retired = s.retired \cup {c},
        s'.ack = s.ack \cup {t},
        s'.authority = s.authority \ {t},
        (CohortsOf(s.ack))' \subseteq CohortsOf(s.ack) \cup {c},
        \A field \in StateFields \
             {"unknown", "owned", "retired", "ack", "authority"} :
             s'[field] = s[field]
    PROVE Safety'
<1>1. TypeOK'
  BY SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
     PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  BY SafetyMembership, FS_Subset
     DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
     AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
     Batches, StateFields
<1>3. PublicationSafety'
  BY SafetyPublication, FS_Subset
     DEF PublicationSafety, PublicationOrder, PublicationExclusion,
     PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
     StateFields
<1>4. Ownership'
  <2>1. s'.owned = {}
    BY DEF DrainedFor
  <2>2. s.unknown = {c}
    BY SafetyOwnership DEF Ownership, DrainedFor
  <2>3. s'.unknown = {}
    BY <2>2
  <2>4. c \in s.headCalls
    BY SafetyOwnership DEF Ownership
  <2>5. c \in s.batchCalls
    BY <2>4, SafetyPublication DEF PublicationSafety, PublicationOrder
  <2>6. s.ready = {}
    BY <2>5, SafetyOwnership DEF Ownership, DrainedFor
  <2>7. s.accepted = {}
    BY <2>2, SafetyOwnership DEF Ownership, DrainedFor
  <2>8. s.prepareFailed = {}
    BY <2>5, SafetyOwnership DEF Ownership, DrainedFor
  <2>9. s.batchFailed = {}
    BY <2>4, SafetyOwnership DEF Ownership, DrainedFor
  <2>10. s.projection = {}
    BY <2>2, SafetyOwnership DEF Ownership, DrainedFor
  <2> QED BY <2>1, <2>3, <2>6, <2>7, <2>8, <2>9, <2>10,
       SafetyOwnership, FS_Subset
     DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields,
     DrainedFor
<1>5. PreparationOwnership'
  BY SafetyPreparationOwnership
     DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields,
     DrainedFor
<1>6. ResourceBounds'
  BY SafetyResourceBounds, SafetyTypeOK, FS_Subset, FS_CardinalityType
     DEF ResourceBounds, TypeOK, PublicationStateTypes, UsedBytes, LiveMembers,
     StateFields, ConstantsOK, DrainedFor
<1>7. AuthoritySafety'
  BY SafetyAuthority, FS_Subset
     DEF AuthoritySafety, CohortsOf, Members, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM ReleaseBufferFacts ==
    ASSUME NEW released \in SUBSET Resources,
        PreparationMapTypes,
        ResourceBounds,
        s'.buffers = Release(s.buffers, released)
    PROVE /\ s'.buffers \in [Resources -> SUBSET ByteDomain]
          /\ Allocated' = Allocated \ released
          /\ UsedBytes' \subseteq UsedBytes
          /\ \A left, right \in Resources :
               left # right => s'.buffers[left] \cap s'.buffers[right] = {}
<1>1. s'.buffers \in [Resources -> SUBSET ByteDomain]
  BY DEF PreparationMapTypes, Release
<1>2. Allocated' = Allocated \ released
  <2>1. Allocated' \subseteq Allocated \ released
    <3> SUFFICES ASSUME NEW r \in Allocated'
                 PROVE r \in Allocated \ released
      OBVIOUS
    <3>1. /\ r \in Resources
           /\ s'.buffers[r] # {}
      BY DEF Allocated
    <3>2. /\ r \notin released
           /\ s'.buffers[r] = s.buffers[r]
      BY <3>1 DEF Release
    <3> QED BY <3>1, <3>2 DEF Allocated
  <2>2. Allocated \ released \subseteq Allocated'
    <3> SUFFICES ASSUME NEW r \in Allocated \ released
                 PROVE r \in Allocated'
      OBVIOUS
    <3>1. /\ r \in Resources
           /\ s.buffers[r] # {}
           /\ r \notin released
      BY DEF Allocated
    <3>2. s'.buffers[r] = s.buffers[r]
      BY <3>1 DEF Release
    <3> QED BY <3>1, <3>2 DEF Allocated
  <2> QED BY <2>1, <2>2
<1>3. UsedBytes' \subseteq UsedBytes
  <2> SUFFICES ASSUME NEW byte \in UsedBytes'
               PROVE byte \in UsedBytes
    OBVIOUS
  <2>1. PICK r \in Resources : byte \in s'.buffers[r]
    BY DEF UsedBytes
  <2>2. /\ r \notin released
         /\ s'.buffers[r] = s.buffers[r]
    BY <2>1 DEF Release
  <2> QED BY <2>1, <2>2 DEF UsedBytes
<1>4. \A left, right \in Resources :
         left # right => s'.buffers[left] \cap s'.buffers[right] = {}
  <2> SUFFICES ASSUME NEW left \in Resources,
                       NEW right \in Resources,
                       left # right
               PROVE s'.buffers[left] \cap s'.buffers[right] = {}
    OBVIOUS
  <2>1. CASE left \in released \/ right \in released
    BY <2>1 DEF Release
  <2>2. CASE left \notin released /\ right \notin released
    BY <2>2, ResourceBounds DEF ResourceBounds, Release
  <2> QED BY <2>1, <2>2
<1> QED BY <1>1, <1>2, <1>3, <1>4

THEOREM AbandonPendingPreserves ==
    ASSUME ConstantsOK, Safety, AbandonPending
    PROVE Safety'
<1>0a. PendingReleased \in SUBSET Resources
  BY SafetyTypeOK
     DEF TypeOK, MemberStateTypes, PendingReleased, PendingBorrowed,
         Inputs, Fragments, Resources
<1>0b. /\ DOMAIN s' = StateFields
        /\ s'.pending = {}
        /\ s'.rejected = s.rejected \cup s.pending
        /\ s'.buffers = Release(s.buffers, PendingReleased)
        /\ \A field \in StateFields \ {"pending", "rejected", "buffers"} :
             s'[field] = s[field]
  BY AbandonPending, SafetyTypeOK, AbandonPendingProjection DEF TypeOK, StateShape
<1>0c. /\ s'.buffers \in [Resources -> SUBSET ByteDomain]
        /\ Allocated' = Allocated \ PendingReleased
        /\ UsedBytes' \subseteq UsedBytes
        /\ \A left, right \in Resources :
             left # right => s'.buffers[left] \cap s'.buffers[right] = {}
  BY <1>0a, <1>0b, SafetyTypeOK, SafetyResourceBounds, ReleaseBufferFacts
     DEF TypeOK, PreparationMapTypes
<1>0d. /\ BoundMembers' = BoundMembers
        /\ LiveMembers' = LiveMembers
        /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
        /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
        /\ (CohortsOf(s.authority \cup s.exported))' =
             CohortsOf(s.authority \cup s.exported)
        /\ \A c \in CohortDomain : Members(c)' = Members(c)
  BY <1>0b DEF StateFields, BoundMembers, LiveMembers, CohortsOf, Members
<1>0e. s.prepareBorrow \cap PendingReleased = {}
  <2>1. s.prepareBorrow \cap Inputs(s.pending \ PendingBorrowed) = {}
    <3> SUFFICES ASSUME NEW r \in s.prepareBorrow \cap
                                 Inputs(s.pending \ PendingBorrowed)
                 PROVE FALSE
      OBVIOUS
    <3>1. PICK t \in s.pending \ PendingBorrowed : r = Input(t)
      BY DEF Inputs
    <3>2. r \in Work
      BY SafetyTypeOK DEF TypeOK, PreparationMapTypes
    <3>3. Input(t) \notin Work
      BY InputNotWork
    <3> QED BY <3>1, <3>2, <3>3
  <2>2. s.prepareBorrow \cap Fragments(s.pending \ PendingBorrowed) = {}
    <3> SUFFICES ASSUME NEW r \in s.prepareBorrow \cap
                                 Fragments(s.pending \ PendingBorrowed)
                 PROVE FALSE
      OBVIOUS
    <3>1. PICK t \in s.pending \ PendingBorrowed : r = Fragment(t)
      BY DEF Fragments
    <3>2. t \in PendingBorrowed
      BY <3>1 DEF PendingBorrowed
    <3> QED BY <3>1, <3>2
  <2> QED BY <2>1, <2>2 DEF PendingReleased
<1>0f. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \cap
           PendingReleased = {}
  BY DEF Batches, PendingReleased, Inputs, Fragments, Input, Fragment, Batch
<1>0g. \A t \in MemberDomain :
         Fragment(t) \in s.prepareBorrow => Input(t) \notin PendingReleased
  BY DEF PendingReleased, PendingBorrowed, Inputs, Fragments, Input, Fragment
<1>0h. \A d \in CohortDomain :
         Batch(d) \in s.prepareBorrow =>
           Fragments(Members(d)) \cap PendingReleased = {}
  <2> SUFFICES ASSUME NEW d \in CohortDomain,
                       Batch(d) \in s.prepareBorrow
               PROVE Fragments(Members(d)) \cap PendingReleased = {}
    OBVIOUS
  <2>1. d \in s.owned
    BY SafetyPreparationOwnership DEF PreparationOwnership
  <2>2. d \in s.issued
    BY <2>1, SafetyOwnership DEF Ownership
  <2>3. Members(d) \subseteq BoundMembers
    BY <2>2 DEF BoundMembers
  <2>4. Members(d) \cap (s.pending \ PendingBorrowed) = {}
    BY <2>3, SafetyMembership DEF MembershipSafety, BoundMembership
  <2>5. Fragments(Members(d)) \cap Inputs(s.pending \ PendingBorrowed) = {}
    BY FragmentInputDisjoint
  <2>6. Fragments(Members(d)) \cap Fragments(s.pending \ PendingBorrowed) = {}
    BY <2>4, FragmentsPreserveDisjointness
  <2> QED BY <2>5, <2>6 DEF PendingReleased
<1>0i. \A t \in MemberDomain :
         Input(t) \in Allocated' => Fragment(t) \in s.prepareBorrow
  BY <1>0c, SafetyPreparationOwnership
     DEF PreparationOwnership, PendingReleased, PendingBorrowed, Inputs,
         Fragments, Input, Fragment
<1>1. TypeOK'
  BY <1>0b, <1>0c, SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
         PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  <2>1. AdmissionMembership'
    BY <1>0b, SafetyMembership, FS_Subset
       DEF MembershipSafety, AdmissionMembership, StateFields
  <2>2. BoundMembership'
    BY <1>0b, <1>0d, SafetyMembership
       DEF MembershipSafety, BoundMembership, StateFields
  <2>3. GroupPartition'
    <3>1. (\A c \in CohortDomain : c \in s.issued <=> Members(c) # {})'
      BY <1>0b, <1>0d, SafetyMembership
         DEF MembershipSafety, GroupPartition, StateFields
    <3>2. (\A c, d \in CohortDomain :
             c # d => Members(c) \cap Members(d) = {})'
      BY <1>0d, SafetyMembership DEF MembershipSafety, GroupPartition
    <3>3. (\A c \in s.issued : Cardinality(Members(c)) <= MemberCapacity)'
      <4> SUFFICES ASSUME NEW c \in s'.issued
                   PROVE Cardinality(Members(c)') <= MemberCapacity
        OBVIOUS
      <4>1. c \in s.issued
        BY <1>0b DEF StateFields
      <4>2. c \in CohortDomain
        BY <4>1, SafetyTypeOK DEF TypeOK, CohortStateTypes
      <4>3. Members(c)' = Members(c)
        BY <1>0d, <4>2
      <4> QED BY <4>1, <4>3, SafetyMembership
         DEF MembershipSafety, GroupPartition
    <3> QED BY <3>1, <3>2, <3>3 DEF GroupPartition
  <2>4. AuthorityMembership'
    BY <1>0b, <1>0d, SafetyMembership, FS_Subset
       DEF MembershipSafety, BoundMembership, AuthorityMembership, StateFields
  <2>5. TerminalMembership'
    BY <1>0b, <1>0d, SafetyMembership
       DEF MembershipSafety, TerminalMembership, StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5 DEF MembershipSafety
<1>3. PublicationSafety'
  BY <1>0b, <1>0d, SafetyPublication
     DEF PublicationSafety, PublicationOrder, PublicationExclusion,
         PublicationPredecessorOrder, PublicationAcknowledgement, StateFields
<1>4. Ownership'
  BY <1>0b, <1>0c, <1>0d, <1>0f, SafetyOwnership, FS_Subset
     DEF Ownership, StateFields
<1>5. PreparationOwnership'
  BY <1>0b, <1>0c, <1>0d, <1>0e, <1>0g, <1>0h, <1>0i,
     SafetyPreparationOwnership, FS_Subset
     DEF PreparationOwnership, StateFields
<1>6. ResourceBounds'
  <2>1. Cardinality(LiveMembers') <= QueueCapacity
    BY <1>0d, SafetyResourceBounds DEF ResourceBounds
  <2>2. Cardinality(s'.owned) <= Capacity
    BY <1>0b, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>3. Cardinality(s'.ready) <= Capacity
    BY <1>0b, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>4. Cardinality(s'.headBorrow) <= 1
    BY <1>0b, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>5. Cardinality(s'.projection) <= 1
    BY <1>0b, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>6. Cardinality(s'.prepareBorrow) <= PrepareCapacity
    BY <1>0b, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>7. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
    <3>1. IsFiniteSet(ByteDomain)
      BY DEF ConstantsOK
    <3>2. IsFiniteSet(UsedBytes)
      BY <1>0c, <3>1, SafetyTypeOK, FS_Subset
         DEF TypeOK, PreparationMapTypes, UsedBytes, Resources
    <3>3. Cardinality(UsedBytes') <= Cardinality(UsedBytes)
      BY <1>0c, <3>2, FS_Subset
    <3>4. Cardinality(UsedBytes) <= Cardinality(ByteDomain)
      BY SafetyResourceBounds DEF ResourceBounds
    <3>5. /\ Cardinality(UsedBytes') \in Nat
            /\ Cardinality(UsedBytes) \in Nat
            /\ Cardinality(ByteDomain) \in Nat
      BY <1>0c, <3>1, <3>2, FS_Subset, FS_CardinalityType
    <3> QED BY <3>3, <3>4, <3>5
  <2>8. \A left, right \in Resources :
         left # right => s'.buffers[left] \cap s'.buffers[right] = {}
    BY <1>0c
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8
     DEF ResourceBounds
<1>7. AuthoritySafety'
  BY <1>0b, <1>0d, SafetyAuthority DEF AuthoritySafety, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM DrainAbandonedPreserves ==
    ASSUME NEW c \in CohortDomain,
        ConstantsOK,
        Safety,
        DrainAbandoned(c)
    PROVE Safety'
<1>0a. Fragments(Members(c)) \in SUBSET Resources
  <2>1. Members(c) \subseteq MemberDomain
    BY SafetyTypeOK DEF TypeOK, PreparationMapTypes, Members
  <2>2. Fragments(Members(c)) \subseteq Fragments(MemberDomain)
    BY <2>1, FragmentsPreserveSubset
  <2> QED BY <2>2 DEF Resources
<1>0b. /\ DOMAIN s' = StateFields
        /\ s'.owned = s.owned \ {c}
        /\ s'.unknown = s.unknown \ {c}
        /\ s'.excluded = s.excluded \cup {c}
        /\ s'.ready = s.ready \ {c}
        /\ s'.prepareFailed = s.prepareFailed \ {c}
        /\ s'.batchFailed = s.batchFailed \ {c}
        /\ s'.buffers = Release(s.buffers, Fragments(Members(c)))
        /\ \A field \in StateFields \
             {"owned", "unknown", "excluded", "ready", "prepareFailed",
              "batchFailed", "buffers"} : s'[field] = s[field]
  BY DrainAbandoned(c), SafetyTypeOK, DrainAbandonedProjection DEF TypeOK, StateShape
<1>0c. /\ s'.buffers \in [Resources -> SUBSET ByteDomain]
        /\ Allocated' = Allocated \ Fragments(Members(c))
        /\ UsedBytes' \subseteq UsedBytes
        /\ \A left, right \in Resources :
             left # right => s'.buffers[left] \cap s'.buffers[right] = {}
  BY <1>0a, <1>0b, SafetyTypeOK, SafetyResourceBounds, ReleaseBufferFacts
     DEF TypeOK, PreparationMapTypes
<1>0d. /\ BoundMembers' = BoundMembers
        /\ LiveMembers' = LiveMembers
        /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
        /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
        /\ (CohortsOf(s.authority \cup s.exported))' =
             CohortsOf(s.authority \cup s.exported)
        /\ \A d \in CohortDomain : Members(d)' = Members(d)
  BY <1>0b DEF StateFields, BoundMembers, LiveMembers, CohortsOf, Members
<1>0e. /\ c \in s.owned \cap s.abandoned
        /\ c \in s.issued
        /\ c \notin s.published
        /\ c \notin s.batchBorrow \cup s.headBorrow
        /\ Batch(c) \notin s.prepareBorrow
        /\ c \notin s.projection
        /\ (c \notin s.headCalls \/ c \in s.absent)
  <2>1. c \in s.owned \cap s.abandoned
    BY ONLY DrainAbandoned(c) DEF DrainAbandoned
  <2>2. c \notin s.batchBorrow \cup s.headBorrow
    BY ONLY DrainAbandoned(c) DEF DrainAbandoned
  <2>3. Batch(c) \notin s.prepareBorrow
    BY ONLY DrainAbandoned(c) DEF DrainAbandoned
  <2>4. c \notin s.projection
    BY ONLY DrainAbandoned(c) DEF DrainAbandoned
  <2>5. c \notin s.headCalls \/ c \in s.absent
    BY ONLY DrainAbandoned(c) DEF DrainAbandoned
  <2>6. c \in s.issued
    BY <2>1, SafetyOwnership DEF Ownership
  <2>7. c \notin s.published
    BY <2>1, SafetyPublication DEF PublicationSafety, PublicationExclusion
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7
<1>0f. s.online
  BY <1>0e, SafetyOwnership DEF Ownership
<1>0g. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \cap
           Fragments(Members(c)) = {}
  BY BatchFragmentDisjoint
<1>0h. s.prepareBorrow \cap Fragments(Members(c)) = {}
  <2> SUFFICES ASSUME NEW r \in s.prepareBorrow \cap Fragments(Members(c))
               PROVE FALSE
    OBVIOUS
  <2>1. r \in Work
    BY SafetyTypeOK DEF TypeOK, PreparationMapTypes
  <2>2. CASE r \in Batches(CohortDomain)
    BY <2>2, BatchFragmentDisjoint
  <2>3. CASE r \in Fragments(MemberDomain)
    <3>1. PICK t \in MemberDomain : r = Fragment(t)
      BY <2>3 DEF Fragments
    <3>2. t \in Members(c)
      BY <3>1, FragmentMembership
    <3>3. t \in BoundMembers
      BY <1>0e, <3>2 DEF BoundMembers
    <3>4. t \notin BoundMembers
      BY <3>1, SafetyPreparationOwnership DEF PreparationOwnership
    <3> QED BY <3>3, <3>4
  <2> QED BY <2>1, <2>2, <2>3 DEF Work
<1>0i. \A d \in CohortDomain :
         Batch(d) \in s.prepareBorrow =>
           Fragments(Members(d)) \cap Fragments(Members(c)) = {}
  <2> SUFFICES ASSUME NEW d \in CohortDomain,
                       Batch(d) \in s.prepareBorrow
               PROVE Fragments(Members(d)) \cap Fragments(Members(c)) = {}
    OBVIOUS
  <2>1. /\ d \in s.owned
          /\ d \in s.issued
    BY SafetyPreparationOwnership, SafetyOwnership
       DEF PreparationOwnership, Ownership
  <2>2. d # c
    BY <1>0e, <2>1
  <2>3. Members(d) \cap Members(c) = {}
    BY <2>2, SafetyMembership DEF MembershipSafety, GroupPartition
  <2> QED BY <2>3, FragmentsPreserveDisjointness
<1>0j. \A t \in MemberDomain : Input(t) \notin Fragments(Members(c))
  BY DEF Inputs, Fragments, Input, Fragment
<1>0k. \A t \in MemberDomain :
         Input(t) \in Allocated' =>
           t \in s'.pending \/ Fragment(t) \in s'.prepareBorrow
  BY <1>0b, <1>0c, SafetyPreparationOwnership
     DEF PreparationOwnership, StateFields
<1>0l. c \notin s.accepted
  BY <1>0e, SafetyOwnership DEF Ownership
<1>0m. s.projection \subseteq s.owned \ {c}
  BY <1>0e, SafetyOwnership DEF Ownership
<1>1. TypeOK'
  BY <1>0b, <1>0c, SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
         PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  <2>1. AdmissionMembership'
    BY <1>0b, SafetyMembership DEF MembershipSafety, AdmissionMembership, StateFields
  <2>2. BoundMembership'
    BY <1>0b, <1>0d, SafetyMembership
       DEF MembershipSafety, BoundMembership, StateFields
  <2>3. GroupPartition'
    <3>1. (\A d \in CohortDomain : d \in s.issued <=> Members(d) # {})'
      BY <1>0b, <1>0d, SafetyMembership
         DEF MembershipSafety, GroupPartition, StateFields
    <3>2. (\A d, e \in CohortDomain :
             d # e => Members(d) \cap Members(e) = {})'
      BY <1>0d, SafetyMembership DEF MembershipSafety, GroupPartition
    <3>3. (\A d \in s.issued : Cardinality(Members(d)) <= MemberCapacity)'
      <4> SUFFICES ASSUME NEW d \in s'.issued
                   PROVE Cardinality(Members(d)') <= MemberCapacity
        OBVIOUS
      <4>1. d \in s.issued
        BY <1>0b DEF StateFields
      <4>2. d \in CohortDomain
        BY <4>1, SafetyTypeOK DEF TypeOK, CohortStateTypes
      <4>3. Members(d)' = Members(d)
        BY <1>0d, <4>2
      <4> QED BY <4>1, <4>3, SafetyMembership
         DEF MembershipSafety, GroupPartition
    <3> QED BY <3>1, <3>2, <3>3 DEF GroupPartition
  <2>4. AuthorityMembership'
    BY <1>0b, <1>0d, SafetyMembership
       DEF MembershipSafety, AuthorityMembership, StateFields
  <2>5. TerminalMembership'
    BY <1>0b, <1>0d, SafetyMembership, FS_AddElement, FS_Subset
       DEF MembershipSafety, TerminalMembership, StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5 DEF MembershipSafety
<1>3. PublicationSafety'
  <2>1. PublicationOrder'
    BY <1>0b, SafetyPublication, FS_RemoveElement, FS_Subset
       DEF PublicationSafety, PublicationOrder, StateFields
  <2>2. PublicationExclusion'
    <3>1. (s.excluded \subseteq s.issued)'
      BY <1>0b, <1>0e, SafetyPublication, FS_AddElement, FS_Subset
         DEF PublicationSafety, PublicationExclusion, StateFields
    <3>2. (s.excluded \cap s.owned = {})'
      BY <1>0b, <1>0e, SafetyPublication, FS_AddElement, FS_RemoveElement
         DEF PublicationSafety, PublicationExclusion, StateFields
    <3>3. (s.excluded \cap s.published = {})'
      BY <1>0b, <1>0e, SafetyPublication, FS_AddElement
         DEF PublicationSafety, PublicationExclusion, StateFields
    <3>4. (s.absent \cap s.published = {})'
      BY <1>0b, SafetyPublication DEF PublicationSafety, PublicationExclusion, StateFields
    <3>5. (s.abandoned \cap s.published = {})'
      BY <1>0b, SafetyPublication DEF PublicationSafety, PublicationExclusion, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5 DEF PublicationExclusion
  <2>3. PublicationPredecessorOrder'
    BY <1>0b, SafetyPublication
       DEF PublicationSafety, PublicationPredecessorOrder, StateFields
  <2>4. PublicationAcknowledgement'
    BY <1>0b, <1>0d, SafetyPublication, FS_RemoveElement, FS_Subset
       DEF PublicationSafety, PublicationAcknowledgement, StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4 DEF PublicationSafety
<1>4. Ownership'
  <2>1. (s.owned \subseteq s.issued)'
    BY <1>0b, SafetyOwnership, FS_RemoveElement, FS_Subset DEF Ownership, StateFields
  <2>2. (Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
             \subseteq Allocated)'
    <3>1. (Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)))' \subseteq
             Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
      BY <1>0b, <1>0d DEF StateFields, Batches
    <3>2. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated
      BY SafetyOwnership DEF Ownership
    <3> QED BY <1>0c, <1>0g, <3>1, <3>2
  <2>3. (s.ready \subseteq
             (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned))'
    BY <1>0b, SafetyOwnership, FS_RemoveElement, FS_Subset DEF Ownership, StateFields
  <2>4. (s.batchBorrow \cup s.headBorrow \subseteq s.owned)'
    BY <1>0b, <1>0e, SafetyOwnership, FS_RemoveElement, FS_Subset
       DEF Ownership, StateFields
  <2>5. /\ (s.batchBorrow \subseteq s.batchCalls)'
          /\ (s.headBorrow \subseteq s.headCalls)'
    BY <1>0b, SafetyOwnership DEF Ownership, StateFields
  <2>6. /\ (s.batchBorrow \cap s.stored = {})'
          /\ (s.headBorrow \cap s.published = {})'
    BY <1>0b, SafetyOwnership DEF Ownership, StateFields
  <2>7. (s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow)'
    BY <1>0b, <1>0l, SafetyOwnership, FS_RemoveElement, FS_Subset
       DEF Ownership, StateFields
  <2>8. (s.unknown \subseteq
             (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted))'
    BY <1>0b, <1>0e, SafetyOwnership, FS_RemoveElement, FS_Subset
       DEF Ownership, StateFields
  <2>9. (s.absent \subseteq s.headCalls \ s.headBorrow)'
    BY <1>0b, SafetyOwnership DEF Ownership, StateFields
  <2>10. (s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls))'
    BY <1>0b, SafetyOwnership, FS_RemoveElement, FS_Subset DEF Ownership, StateFields
  <2>11. (Batches(s.prepareFailed) \subseteq
              s.prepareCalls \ s.prepareBorrow)'
    BY <1>0b, SafetyOwnership, FS_RemoveElement, FS_Subset
       DEF Ownership, StateFields, Batches
  <2>12. (s.batchFailed \subseteq
              (s.owned \cap s.batchCalls) \
                (s.batchBorrow \cup s.stored \cup s.headCalls))'
    BY <1>0b, SafetyOwnership, FS_RemoveElement, FS_Subset DEF Ownership, StateFields
  <2>13. (s.projection \subseteq
              (s.owned \cap s.validated) \ s.abandoned)'
    <3>1. /\ s'.projection = s.projection
            /\ s'.owned = s.owned \ {c}
            /\ s'.validated = s.validated
            /\ s'.abandoned = s.abandoned
      BY <1>0b DEF StateFields
    <3> QED BY <1>0m, <3>1, SafetyOwnership DEF Ownership
  <2>14. (s.headBorrow \cup s.accepted \subseteq s.projection)'
    BY <1>0b, SafetyOwnership DEF Ownership, StateFields
  <2>15. ((s.unknown \cup s.absent) \cap s.projection = {})'
    BY <1>0b, SafetyOwnership DEF Ownership, StateFields
  <2>16. (s.headBorrow # {} => s.unknown = {})'
    BY <1>0b, SafetyOwnership DEF Ownership, StateFields
  <2>17. (~s.online =>
              s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
              s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected)'
    BY <1>0b, <1>0f DEF StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9,
             <2>10, <2>11, <2>12, <2>13, <2>14, <2>15, <2>16, <2>17
     DEF Ownership
<1>5. PreparationOwnership'
  <2>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
    BY <1>0b, <1>0c, <1>0h, SafetyPreparationOwnership
       DEF PreparationOwnership, StateFields
  <2>2. (\A t \in MemberDomain :
             Fragment(t) \in s.prepareBorrow =>
               Input(t) \in Allocated /\ t \in s.admitted \ BoundMembers)'
    BY <1>0b, <1>0c, <1>0d, <1>0j, SafetyPreparationOwnership
       DEF PreparationOwnership, StateFields
  <2>3. (\A d \in CohortDomain :
             Batch(d) \in s.prepareBorrow =>
               d \in s.owned /\ Fragments(Members(d)) \subseteq Allocated)'
    BY <1>0b, <1>0c, <1>0d, <1>0e, <1>0i, SafetyPreparationOwnership
       DEF PreparationOwnership, StateFields
  <2>4. (\A t \in s.prepared :
             Fragment(t) \in s.prepareCalls \ s.prepareBorrow)'
    BY <1>0b, SafetyPreparationOwnership DEF PreparationOwnership, StateFields
  <2>5. (\A t \in s.prepared : Input(t) \notin Allocated)'
    BY <1>0b, <1>0c, SafetyPreparationOwnership, FS_RemoveElement, FS_Subset
       DEF PreparationOwnership, StateFields
  <2>6. (\A d \in s.sealed : Batch(d) \in s.prepareCalls \ s.prepareBorrow)'
    BY <1>0b, SafetyPreparationOwnership DEF PreparationOwnership, StateFields
  <2>7. \A t \in MemberDomain :
           Input(t) \in Allocated' =>
             t \in s'.pending \/ Fragment(t) \in s'.prepareBorrow
    BY <1>0k
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF PreparationOwnership
<1>6. ResourceBounds'
  <2>1. Cardinality(LiveMembers') <= QueueCapacity
    BY <1>0d, SafetyResourceBounds DEF ResourceBounds
  <2>2. Cardinality(s'.owned) <= Capacity
    <3>1. IsFiniteSet(s.owned)
      <4>1. s.owned \subseteq CohortDomain
        BY SafetyTypeOK DEF TypeOK, PublicationStateTypes
      <4>2. IsFiniteSet(CohortDomain)
        BY DEF ConstantsOK
      <4> QED BY <4>1, <4>2, FS_Subset
    <3>2. Cardinality(s'.owned) <= Cardinality(s.owned)
      <4>1. Cardinality(s.owned) \in Nat
        BY <3>1, FS_CardinalityType
      <4>2. Cardinality(s'.owned) =
               IF c \in s.owned THEN Cardinality(s.owned) - 1 ELSE Cardinality(s.owned)
        BY <1>0b, <3>1, FS_RemoveElement DEF StateFields
      <4> QED BY <4>1, <4>2
    <3>3. Cardinality(s.owned) \in Nat
      BY <3>1, FS_CardinalityType
    <3>4. Capacity \in Nat
      BY DEF ConstantsOK
    <3>5. Cardinality(s.owned) <= Capacity
      BY SafetyResourceBounds DEF ResourceBounds
    <3>6. IsFiniteSet(s'.owned)
      BY <1>0b, <3>1, FS_RemoveElement DEF StateFields
    <3>7. Cardinality(s'.owned) \in Nat
      BY <3>6, FS_CardinalityType
    <3> QED BY ONLY <3>2, <3>3, <3>4, <3>5, <3>7
  <2>3. Cardinality(s'.ready) <= Capacity
    <3>1. IsFiniteSet(s.ready)
      <4>1. s.ready \subseteq CohortDomain
        BY SafetyTypeOK DEF TypeOK, CohortStateTypes
      <4>2. IsFiniteSet(CohortDomain)
        BY DEF ConstantsOK
      <4> QED BY <4>1, <4>2, FS_Subset
    <3>2. Cardinality(s'.ready) <= Cardinality(s.ready)
      <4>1. Cardinality(s.ready) \in Nat
        BY <3>1, FS_CardinalityType
      <4>2. Cardinality(s'.ready) =
               IF c \in s.ready THEN Cardinality(s.ready) - 1 ELSE Cardinality(s.ready)
        BY <1>0b, <3>1, FS_RemoveElement DEF StateFields
      <4> QED BY <4>1, <4>2
    <3>3. Cardinality(s.ready) \in Nat
      BY <3>1, FS_CardinalityType
    <3>4. Capacity \in Nat
      BY DEF ConstantsOK
    <3>5. Cardinality(s.ready) <= Capacity
      BY SafetyResourceBounds DEF ResourceBounds
    <3>6. IsFiniteSet(s'.ready)
      BY <1>0b, <3>1, FS_RemoveElement DEF StateFields
    <3>7. Cardinality(s'.ready) \in Nat
      BY <3>6, FS_CardinalityType
    <3> QED BY ONLY <3>2, <3>3, <3>4, <3>5, <3>7
  <2>4. Cardinality(s'.headBorrow) <= 1
    BY <1>0b, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>5. Cardinality(s'.projection) <= 1
    BY <1>0b, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>6. Cardinality(s'.prepareBorrow) <= PrepareCapacity
    BY <1>0b, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>7. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
    <3>1. IsFiniteSet(ByteDomain)
      BY DEF ConstantsOK
    <3>2. IsFiniteSet(UsedBytes)
      BY <1>0c, <3>1, SafetyTypeOK, FS_Subset
         DEF TypeOK, PreparationMapTypes, UsedBytes, Resources
    <3>3. Cardinality(UsedBytes') <= Cardinality(UsedBytes)
      BY <1>0c, <3>2, FS_Subset
    <3>4. Cardinality(UsedBytes) <= Cardinality(ByteDomain)
      BY SafetyResourceBounds DEF ResourceBounds
    <3>5. /\ Cardinality(UsedBytes') \in Nat
            /\ Cardinality(UsedBytes) \in Nat
            /\ Cardinality(ByteDomain) \in Nat
      BY <1>0c, <3>1, <3>2, FS_Subset, FS_CardinalityType
    <3> QED BY <3>3, <3>4, <3>5
  <2>8. \A left, right \in Resources :
         left # right => s'.buffers[left] \cap s'.buffers[right] = {}
    BY <1>0c
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8
     DEF ResourceBounds
<1>7. AuthoritySafety'
  <2>1. (CohortsOf(s.authority \cup s.exported) \subseteq
             s.headCalls \ s.headBorrow)'
    BY <1>0b, <1>0d, SafetyAuthority DEF AuthoritySafety, StateFields
  <2>2. (s.headBorrow \cap s.abandoned = {})'
    BY <1>0b, SafetyAuthority DEF AuthoritySafety, StateFields
  <2>3. (s.unknownEpisode => s.halted)'
    BY <1>0b, SafetyAuthority DEF AuthoritySafety, StateFields
  <2>4. /\ (s.exported \subseteq s.delivered)'
          /\ (s.delivered \subseteq s.collected)'
    BY <1>0b, SafetyAuthority DEF AuthoritySafety, StateFields
  <2>5. (s.authority \cap s.discarded = {})'
    BY <1>0b, SafetyAuthority DEF AuthoritySafety, StateFields
  <2>6. (s.resolutionWrites = 0)'
    BY <1>0b, SafetyAuthority DEF AuthoritySafety, StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6 DEF AuthoritySafety
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM TypeOKStuttering ==
    ASSUME s' = s, TypeOK
    PROVE TypeOK'
<1>0. s' = s
  OBVIOUS
<1>1. StateShape'
  BY <1>0 DEF TypeOK, StateShape
<1>2. MemberStateTypes'
  BY <1>0 DEF TypeOK, MemberStateTypes
<1>3. PreparationMapTypes'
  BY <1>0 DEF TypeOK, PreparationMapTypes
<1>4. CohortStateTypes'
  BY <1>0 DEF TypeOK, CohortStateTypes
<1>5. PublicationStateTypes'
  BY <1>0 DEF TypeOK, PublicationStateTypes
<1>6. AuthorityStateTypes'
  BY <1>0 DEF TypeOK, AuthorityStateTypes
<1>7. LifecycleStateTypes'
  BY <1>0 DEF TypeOK, LifecycleStateTypes
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF TypeOK

THEOREM MembershipSafetyStuttering ==
    ASSUME s' = s, MembershipSafety
    PROVE MembershipSafety'
<1>0. s' = s
  OBVIOUS
<1>1. AdmissionMembership'
  BY <1>0 DEF MembershipSafety, AdmissionMembership
<1>2. BoundMembership'
  BY <1>0 DEF MembershipSafety, BoundMembership, BoundMembers, Members
<1>3. GroupPartition'
  BY <1>0 DEF MembershipSafety, GroupPartition, Members
<1>4. AuthorityMembership'
  BY <1>0 DEF MembershipSafety, AuthorityMembership, BoundMembers, Members
<1>5. TerminalMembership'
  BY <1>0 DEF MembershipSafety, TerminalMembership, CohortsOf, Members, Batches
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5 DEF MembershipSafety

THEOREM PublicationSafetyStuttering ==
    ASSUME s' = s, PublicationSafety
    PROVE PublicationSafety'
<1>0. s' = s
  OBVIOUS
<1>1. PublicationOrder'
  BY <1>0 DEF PublicationSafety, PublicationOrder
<1>2. PublicationExclusion'
  BY <1>0 DEF PublicationSafety, PublicationExclusion
<1>3. PublicationPredecessorOrder'
  BY <1>0 DEF PublicationSafety, PublicationPredecessorOrder
<1>4. PublicationAcknowledgement'
  BY <1>0 DEF PublicationSafety, PublicationAcknowledgement, CohortsOf, Members
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF PublicationSafety

THEOREM OwnershipStuttering ==
    ASSUME s' = s, Ownership
    PROVE Ownership'
<1>0. s' = s
  OBVIOUS
<1>1. (s.owned \subseteq s.issued)'
  BY <1>0 DEF Ownership
<1>2. (Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated)'
  <2>1. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated
    BY DEF Ownership
  <2>2. /\ s'.owned = s.owned
          /\ s'.authority = s.authority
          /\ s'.exported = s.exported
    BY <1>0
  <2>3. CohortsOf(s.authority \cup s.exported)' =
           CohortsOf(s.authority \cup s.exported)
    BY <1>0 DEF CohortsOf, Members
  <2>4. Allocated' = Allocated
    BY <1>0 DEF Allocated
  <2> QED BY <2>1, <2>2, <2>3, <2>4
<1>3. (s.ready \subseteq (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned))'
  BY <1>0 DEF Ownership
<1>4. (s.batchBorrow \cup s.headBorrow \subseteq s.owned)'
  BY <1>0 DEF Ownership
<1>5. (s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls)'
  BY <1>0 DEF Ownership
<1>6. (s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {})'
  BY <1>0 DEF Ownership
<1>7. (s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow)'
  BY <1>0 DEF Ownership
<1>8. (s.unknown \subseteq (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted))'
  BY <1>0 DEF Ownership
<1>9. (s.absent \subseteq s.headCalls \ s.headBorrow)'
  BY <1>0 DEF Ownership
<1>9a. (s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls))'
  BY <1>0 DEF Ownership
<1>9ab. (Batches(s.prepareFailed) \subseteq s.prepareCalls \ s.prepareBorrow)'
  BY <1>0 DEF Ownership, Batches
<1>9aa. (s.batchFailed \subseteq
          (s.owned \cap s.batchCalls) \ (s.batchBorrow \cup s.stored \cup s.headCalls))'
  BY <1>0 DEF Ownership
<1>9b. (s.projection \subseteq (s.owned \cap s.validated) \ s.abandoned)'
  BY <1>0 DEF Ownership
<1>9c. (s.headBorrow \cup s.accepted \subseteq s.projection)'
  BY <1>0 DEF Ownership
<1>9d. ((s.unknown \cup s.absent) \cap s.projection = {})'
  BY <1>0 DEF Ownership
<1>10. (s.headBorrow # {} => s.unknown = {})'
  BY <1>0 DEF Ownership
<1>11. (~s.online => s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
          s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected)'
  BY <1>0 DEF Ownership
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9,
    <1>9a, <1>9ab, <1>9aa, <1>9b, <1>9c, <1>9d, <1>10, <1>11 DEF Ownership

THEOREM PreparationOwnershipStuttering ==
    ASSUME s' = s, PreparationOwnership
    PROVE PreparationOwnership'
<1>0. s' = s
  OBVIOUS
<1>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
  BY <1>0 DEF PreparationOwnership, Allocated
<1>2. (\A t \in MemberDomain : Fragment(t) \in s.prepareBorrow =>
          Input(t) \in Allocated /\ t \in s.admitted \ BoundMembers)'
  BY <1>0 DEF PreparationOwnership, Allocated, BoundMembers, Members
<1>3. (\A c \in CohortDomain : Batch(c) \in s.prepareBorrow =>
          c \in s.owned /\ Fragments(Members(c)) \subseteq Allocated)'
  BY <1>0 DEF PreparationOwnership, Members, Allocated
<1>4. (\A t \in s.prepared : Fragment(t) \in s.prepareCalls \ s.prepareBorrow)'
  BY <1>0 DEF PreparationOwnership
<1>5. (\A t \in s.prepared : Input(t) \notin Allocated)'
  BY <1>0 DEF PreparationOwnership, Allocated
<1>6. (\A c \in s.sealed : Batch(c) \in s.prepareCalls \ s.prepareBorrow)'
  BY <1>0 DEF PreparationOwnership
<1>7. (\A t \in MemberDomain : Input(t) \in Allocated =>
          t \in s.pending \/ Fragment(t) \in s.prepareBorrow)'
  BY <1>0 DEF PreparationOwnership, Allocated
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF PreparationOwnership

THEOREM ResourceBoundsStuttering ==
    ASSUME s' = s, ResourceBounds
    PROVE ResourceBounds'
<1>0. s' = s
  OBVIOUS
<1>1. (Cardinality(LiveMembers) <= QueueCapacity)'
  BY <1>0 DEF ResourceBounds, LiveMembers
<1>2. (Cardinality(s.owned) <= Capacity)'
  BY <1>0 DEF ResourceBounds
<1>3. (Cardinality(s.ready) <= Capacity)'
  BY <1>0 DEF ResourceBounds
<1>4. (Cardinality(s.headBorrow) <= 1)'
  BY <1>0 DEF ResourceBounds
<1>4a. (Cardinality(s.projection) <= 1)'
  BY <1>0 DEF ResourceBounds
<1>5. (Cardinality(s.prepareBorrow) <= PrepareCapacity)'
  BY <1>0 DEF ResourceBounds
<1>6. (Cardinality(UsedBytes) <= Cardinality(ByteDomain))'
  BY <1>0 DEF ResourceBounds, UsedBytes
<1>7. (\A left, right \in Resources : left # right =>
          s.buffers[left] \cap s.buffers[right] = {})'
  BY <1>0 DEF ResourceBounds
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>4a, <1>5, <1>6, <1>7 DEF ResourceBounds

THEOREM AuthoritySafetyStuttering ==
    ASSUME s' = s, AuthoritySafety
    PROVE AuthoritySafety'
<1>0. s' = s
  OBVIOUS
<1>1. (CohortsOf(s.authority \cup s.exported) \subseteq
          s.headCalls \ s.headBorrow)'
  BY <1>0 DEF AuthoritySafety, CohortsOf, Members
<1>2. (s.headBorrow \cap s.abandoned = {})'
  BY <1>0 DEF AuthoritySafety
<1>3. (s.unknownEpisode => s.halted)'
  BY <1>0 DEF AuthoritySafety
<1>4. (s.exported \subseteq s.delivered)'
  BY <1>0 DEF AuthoritySafety
<1>4a. (s.delivered \subseteq s.collected)'
  BY <1>0 DEF AuthoritySafety
<1>4b. (s.authority \cap s.discarded = {})'
  BY <1>0 DEF AuthoritySafety
<1>5. (s.resolutionWrites = 0)'
  BY <1>0 DEF AuthoritySafety
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>4a, <1>4b, <1>5 DEF AuthoritySafety

THEOREM SafetyStuttering ==
    ASSUME s' = s, Safety
    PROVE Safety'
<1>1. TypeOK'
  BY SafetyTypeOK, TypeOKStuttering
<1>2. MembershipSafety'
  BY SafetyMembership, MembershipSafetyStuttering
<1>3. PublicationSafety'
  BY SafetyPublication, PublicationSafetyStuttering
<1>4. Ownership'
  BY SafetyOwnership, OwnershipStuttering
<1>5. PreparationOwnership'
  BY SafetyPreparationOwnership, PreparationOwnershipStuttering
<1>6. ResourceBounds'
  BY SafetyResourceBounds, ResourceBoundsStuttering
<1>7. AuthoritySafety'
  BY SafetyAuthority, AuthoritySafetyStuttering
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM LifecycleFramePreserves ==
    ASSUME ConstantsOK,
        Safety,
        DOMAIN s' = StateFields,
        \A field \in StateFields \
            {"online", "closing", "halted", "retired", "authority"} :
            s'[field] = s[field],
        s'.online \in BOOLEAN,
        s'.closing \in BOOLEAN,
        s'.halted \in BOOLEAN,
        s.halted => s'.halted,
        s.retired \subseteq s'.retired,
        s'.retired \subseteq s.published,
        s'.authority \subseteq s.authority,
        ~s'.online =>
            s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
            s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected
    PROVE Safety'
<1>0. (CohortsOf(s.authority \cup s.exported))' \subseteq
          CohortsOf(s.authority \cup s.exported)
  BY DEF CohortsOf, Members, StateFields
<1>1. TypeOK'
  BY SafetyTypeOK, FS_Subset
     DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
         PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
<1>2. MembershipSafety'
  BY SafetyMembership, FS_Subset
     DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
         AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
         Batches, StateFields
<1>3. PublicationSafety'
  BY SafetyPublication, FS_Subset
     DEF PublicationSafety, PublicationOrder, PublicationExclusion,
         PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
         StateFields
<1>4. Ownership'
  BY <1>0, SafetyOwnership, FS_Subset
     DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
<1>5. PreparationOwnership'
  BY SafetyPreparationOwnership
     DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
<1>6. ResourceBounds'
  BY SafetyResourceBounds
     DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
<1>7. AuthoritySafety'
  BY <1>0, SafetyAuthority, FS_Subset
     DEF AuthoritySafety, CohortsOf, Members, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

(***************************************************************************
These are proof obligations, not discharged results. Credit and dynamic-group
lemmas make the extension's proof boundary explicit; no imported ghost axiom,
OMITTED proof, or assumed safety preservation is used.
***************************************************************************)
THEOREM CreditContainment ==
    ASSUME ConstantsOK, TypeOK
    PROVE UsedBytes \subseteq ByteDomain
<1> QED BY DEF ConstantsOK, TypeOK, PreparationMapTypes, UsedBytes, Resources

THEOREM CreditCapacity ==
    ASSUME ConstantsOK, TypeOK
    PROVE Cardinality(UsedBytes) <= Cardinality(ByteDomain)
<1> QED BY CreditContainment, FS_Subset DEF ConstantsOK

THEOREM DynamicGroupUniqueness ==
    ASSUME Safety
    PROVE \A t \in BoundMembers : \E c \in s.issued :
        t \in Members(c) /\ \A d \in s.issued : t \in Members(d) => d = c
<1> SUFFICES ASSUME NEW t \in BoundMembers
             PROVE \E c \in s.issued :
                 t \in Members(c) /\ \A d \in s.issued : t \in Members(d) => d = c
  OBVIOUS
<1>0. GroupPartition
  BY SafetyMembership DEF MembershipSafety
<1>1. \E c \in s.issued : t \in Members(c)
  BY DEF BoundMembers
<1>2. PICK c \in s.issued : t \in Members(c)
  BY <1>1
<1>3. \A d \in s.issued : t \in Members(d) => d = c
  <2> SUFFICES ASSUME NEW d \in s.issued, t \in Members(d)
               PROVE d = c
    OBVIOUS
  <2>0. c \in CohortDomain /\ d \in CohortDomain
    BY <1>2 DEF Safety, TypeOK, CohortStateTypes
  <2>1. d # c => Members(d) \cap Members(c) = {}
    BY <1>0, <2>0 DEF GroupPartition
  <2> QED BY <1>2, <2>1
<1> QED BY <1>2, <1>3

THEOREM FrozenGroupStable ==
    ASSUME ConstantsOK, Safety, Next
    PROVE \A c \in s.issued : s'.groups[c] = s.groups[c]
<1> SUFFICES ASSUME NEW d \in s.issued
             PROVE s'.groups[d] = s.groups[d]
  OBVIOUS
<1>0. StateShape /\ PreparationMapTypes /\ CohortStateTypes
  BY SafetyTypeOK DEF TypeOK
<1>0a. d \in CohortDomain
  BY <1>0 DEF CohortStateTypes
<1>1. CASE \E c \in CohortDomain, ts \in SUBSET MemberDomain, bytes \in SUBSET ByteDomain :
              Freeze(c, ts, bytes)
  <2>0. PICK c \in CohortDomain, ts \in SUBSET MemberDomain, bytes \in SUBSET ByteDomain :
             Freeze(c, ts, bytes)
    BY <1>1
  <2>1. c \notin s.issued
    BY <2>0 DEF Freeze
  <2>2. d # c
    BY <2>1
  <2>3. FreezeFieldsPresent
    BY <1>0, StateShapeProvidesFreezeFields DEF StateShape
  <2>4. \A e \in CohortDomain : s'.groups[e] = IF e = c THEN ts ELSE s.groups[e]
    BY FreezeStateGroupAt, <1>0, <2>0, <2>3 DEF Freeze, PreparationMapTypes
  <2> QED BY <1>0a, <2>2, <2>4
<1>2. CASE \E t \in MemberDomain, bytes \in SUBSET ByteDomain :
              Admit(t, bytes) \/ StartTxnPrepare(t, bytes)
  <2>1. CASE \E t \in MemberDomain, bytes \in SUBSET ByteDomain : Admit(t, bytes)
    <3>0. PICK t \in MemberDomain, bytes \in SUBSET ByteDomain : Admit(t, bytes)
      BY <2>1
    <3>1. s' = AdmitState(t, bytes)
      BY <3>0 DEF Admit
    <3> QED BY <1>0, <3>0, <3>1, AdmitStatePreservesPreparationFields DEF StateShape
  <2>2. CASE \E t \in MemberDomain, bytes \in SUBSET ByteDomain : StartTxnPrepare(t, bytes)
    <3>0. PICK t \in MemberDomain, bytes \in SUBSET ByteDomain : StartTxnPrepare(t, bytes)
      BY <2>2
    <3>1. s' = StartTxnPrepareState(t, bytes)
      BY <3>0 DEF StartTxnPrepare
    <3> QED BY <1>0, <3>0, <3>1, StartTxnPrepareStatePreservesCohortFields DEF StateShape
  <2> QED BY <1>2, <2>1, <2>2
<1>3. CASE \E t \in MemberDomain, success \in BOOLEAN : JoinTxnPrepare(t, success)
  <2>0. PICK t \in MemberDomain, success \in BOOLEAN : JoinTxnPrepare(t, success)
    BY <1>3
  <2>1. KeepTxnPrepare(t, success) \in BOOLEAN
    BY <2>0 DEF JoinTxnPrepare, KeepTxnPrepare
  <2>2. s' = JoinTxnPrepareState(t, KeepTxnPrepare(t, success))
    BY <2>0 DEF JoinTxnPrepare
  <2>3. s'.groups = s.groups
    BY <1>0, <2>1, <2>2, JoinTxnPrepareStatePreservesPreparationFields DEF StateShape
  <2> QED BY <2>3
<1>4. CASE \E c \in CohortDomain, success \in BOOLEAN :
              JoinBatchPrepare(c, success) \/ JoinBatch(c, success) \/
              ValidateFront(c, success) \/ Retire(c, success)
  <2>1. CASE \E c \in CohortDomain, success \in BOOLEAN : JoinBatchPrepare(c, success)
    BY <1>0, <2>1, FunctionExceptAtOther
       DEF JoinBatchPrepare, Release, StateShape, StateFields
  <2>2. CASE \E c \in CohortDomain, success \in BOOLEAN : JoinBatch(c, success)
    BY <1>0, <2>2, FunctionExceptAtOther DEF JoinBatch, StateShape, StateFields
  <2>3. CASE \E c \in CohortDomain, success \in BOOLEAN : ValidateFront(c, success)
    BY <1>0, <2>3, ValidateFrontProjection DEF StateShape, StateFields
  <2>4. CASE \E c \in CohortDomain, success \in BOOLEAN : Retire(c, success)
    BY <1>0, <2>4, RetireProjection DEF StateShape, StateFields
  <2> QED BY <1>4, <2>1, <2>2, <2>3, <2>4
<1>5. CASE \E c \in CohortDomain, entered, uncertain \in BOOLEAN :
              JoinHead(c, entered, uncertain)
  BY <1>0, <1>5, JoinHeadProjection DEF StateShape, StateFields
<1>6. CASE \E c \in CohortDomain : StartBatchPrepare(c) \/ StartBatch(c) \/ StartHead(c) \/
              FailPreparedFront(c) \/ FailBatchFront(c) \/ MarkAbandoned(c) \/
              DrainAbandoned(c) \/ DetachUnknown(c) \/ Collect(c)
  <2>1. CASE \E c \in CohortDomain : StartBatchPrepare(c)
    BY <1>0, <2>1, FunctionExceptAtOther DEF StartBatchPrepare, StateShape, StateFields
  <2>2. CASE \E c \in CohortDomain : StartBatch(c)
    BY <1>0, <2>2, FunctionExceptAtOther DEF StartBatch, StateShape, StateFields
  <2>3. CASE \E c \in CohortDomain : StartHead(c)
    BY <1>0, <2>3, FunctionExceptAtOther DEF StartHead, StateShape, StateFields
  <2>4. CASE \E c \in CohortDomain : FailPreparedFront(c)
    BY <1>0, <2>4, FunctionExceptAtOther DEF FailPreparedFront, StateShape, StateFields
  <2>5. CASE \E c \in CohortDomain : FailBatchFront(c)
    BY <1>0, <2>5, FunctionExceptAtOther DEF FailBatchFront, StateShape, StateFields
  <2>6. CASE \E c \in CohortDomain : MarkAbandoned(c)
    BY <1>0, <2>6, FunctionExceptAtOther DEF MarkAbandoned, StateShape, StateFields
  <2>7. CASE \E c \in CohortDomain : DrainAbandoned(c)
    BY <1>0, <2>7, FunctionExceptAtOther
       DEF DrainAbandoned, Release, StateShape, StateFields
  <2>8. CASE \E c \in CohortDomain : DetachUnknown(c)
    BY <1>0, <2>8, FunctionExceptAtOther DEF DetachUnknown, StateShape, StateFields
  <2>9. CASE \E c \in CohortDomain : Collect(c)
    BY <1>0, <2>9, FunctionExceptAtOther DEF Collect, StateShape, StateFields
  <2> QED BY <1>6, <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9
<1>7. CASE \E t \in MemberDomain, c \in CohortDomain :
              ResolveFront(t, c) \/ ResolveDetached(t, c) \/ ConcludeAbsent(t, c) \/
              ResolveRejected(t, c)
  <2>1. CASE \E t \in MemberDomain, c \in CohortDomain : ResolveFront(t, c)
    BY <1>0, <2>1, FunctionExceptAtOther DEF ResolveFront, StateShape, StateFields
  <2>2. CASE \E t \in MemberDomain, c \in CohortDomain : ResolveDetached(t, c)
    BY <1>0, <2>2, FunctionExceptAtOther DEF ResolveDetached, StateShape, StateFields
  <2>3. CASE \E t \in MemberDomain, c \in CohortDomain : ConcludeAbsent(t, c)
    BY <1>0, <2>3, FunctionExceptAtOther DEF ConcludeAbsent, StateShape, StateFields
  <2>4. CASE \E t \in MemberDomain, c \in CohortDomain : ResolveRejected(t, c)
    BY <1>0, <2>4, FunctionExceptAtOther DEF ResolveRejected, StateShape, StateFields
  <2> QED BY <1>7, <2>1, <2>2, <2>3, <2>4
<1>8. CASE \E t \in MemberDomain : CollectTerminal(t) \/ DeliverReceipt(t) \/ Export(t) \/
              Import(t) \/ Drop(t) \/ DiscardCollected(t)
  <2>1. CASE \E t \in MemberDomain : CollectTerminal(t)
    BY <1>0, <2>1, FunctionExceptAtOther DEF CollectTerminal, StateShape, StateFields
  <2>2. CASE \E t \in MemberDomain : DeliverReceipt(t)
    BY <1>0, <2>2, FunctionExceptAtOther DEF DeliverReceipt, StateShape, StateFields
  <2>3. CASE \E t \in MemberDomain : Export(t)
    BY <1>0, <2>3, FunctionExceptAtOther DEF Export, StateShape, StateFields
  <2>4. CASE \E t \in MemberDomain : Import(t)
    BY <1>0, <2>4, FunctionExceptAtOther DEF Import, StateShape, StateFields
  <2>5. CASE \E t \in MemberDomain : Drop(t)
    BY <1>0, <2>5, FunctionExceptAtOther DEF Drop, StateShape, StateFields
  <2>6. CASE \E t \in MemberDomain : DiscardCollected(t)
    BY <1>0, <2>6, FunctionExceptAtOther DEF DiscardCollected, StateShape, StateFields
  <2> QED BY <1>8, <2>1, <2>2, <2>3, <2>4, <2>5, <2>6
<1>9. CASE AbandonPending \/ RequestCancellation \/ BeginClose \/ Close \/ CrashAfterReturn \/ Reopen
  <2>1. CASE AbandonPending
    BY <1>0, <2>1, FunctionExceptAtOther DEF AbandonPending, Release, StateShape, StateFields
  <2>2. CASE RequestCancellation
    BY <2>2 DEF RequestCancellation
  <2>3. CASE BeginClose
    BY <1>0, <2>3, FunctionExceptAtOther DEF BeginClose, StateShape, StateFields
  <2>4. CASE Close
    BY <1>0, <2>4, FunctionExceptAtOther DEF Close, StateShape, StateFields
  <2>5. CASE CrashAfterReturn
    BY <1>0, <2>5, FunctionExceptAtOther DEF CrashAfterReturn, StateShape, StateFields
  <2>6. CASE Reopen
    BY <1>0, <2>6, FunctionExceptAtOther DEF Reopen, StateShape, StateFields
  <2> QED BY <1>9, <2>1, <2>2, <2>3, <2>4, <2>5, <2>6
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9 DEF Next

THEOREM InitSafety ==
    ASSUME ConstantsOK, Init
    PROVE Safety
<1>0. DOMAIN s = StateFields
  BY InitStateShape
<1>0a. /\ s.admitted = {} /\ s.collected = {} /\ s.delivered = {} /\ s.discarded = {}
         /\ s.pending = {}
         /\ s.prepared = {} /\ s.rejected = {}
  BY InitMemberFields
<1>0b. /\ s.groups = [c \in CohortDomain |-> {}]
         /\ s.buffers = [r \in Resources |-> {}]
         /\ s.prepareCalls = {} /\ s.prepareBorrow = {}
  BY InitPreparationFields
<1>0c. /\ s.sealed = {} /\ s.ready = {} /\ s.issued = {} /\ s.stored = {}
         /\ s.published = {} /\ s.retired = {} /\ s.excluded = {} /\ s.abandoned = {}
         /\ s.prepareFailed = {} /\ s.batchFailed = {}
         /\ s.validated = {} /\ s.projection = {}
  BY InitCohortFields
<1>0d. /\ s.batchCalls = {} /\ s.headCalls = {}
         /\ s.batchBorrow = {} /\ s.headBorrow = {} /\ s.owned = {}
         /\ s.accepted = {} /\ s.unknown = {} /\ s.absent = {}
  BY InitPublicationFields
<1>0e. /\ s.delivered = {} /\ s.authority = {} /\ s.exported = {} /\ s.ack = {}
  BY InitAuthorityFields
<1>0f. /\ s.closing = FALSE /\ s.online = TRUE /\ s.fenced = FALSE /\ s.halted = FALSE
         /\ s.unknownEpisode = FALSE /\ s.resolutionWrites = 0
  BY InitLifecycleFields
<1>0g. /\ BoundMembers = {} /\ Allocated = {} /\ UsedBytes = {} /\ CohortsOf({}) = {}
  BY InitEmptyViews
<1>1. TypeOK
  <2>1. StateShape
    BY <1>0 DEF StateShape
  <2>2. MemberStateTypes
    BY <1>0a DEF MemberStateTypes
  <2>3. PreparationMapTypes
    BY <1>0b DEF PreparationMapTypes, Work
  <2>4. CohortStateTypes
    BY <1>0c DEF CohortStateTypes
  <2>5. PublicationStateTypes
    BY <1>0d DEF PublicationStateTypes
  <2>6. AuthorityStateTypes
    BY <1>0e DEF AuthorityStateTypes
  <2>7. LifecycleStateTypes
    BY <1>0f DEF LifecycleStateTypes
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF TypeOK
<1>2. MembershipSafety
  <2>1. AdmissionMembership
    BY <1>0a DEF AdmissionMembership
  <2>2. BoundMembership
    BY <1>0a, <1>0g DEF BoundMembership
  <2>3. GroupPartition
    BY <1>0b, <1>0c DEF GroupPartition, Members
  <2>4. AuthorityMembership
    BY <1>0a, <1>0e, <1>0g DEF AuthorityMembership
  <2>5. TerminalMembership
    BY <1>0a, <1>0g DEF TerminalMembership, CohortsOf, Members, Batches
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5 DEF MembershipSafety
<1>3. PublicationSafety
  <2>1. PublicationOrder
    BY <1>0c, <1>0d DEF PublicationOrder
  <2>2. PublicationExclusion
    BY <1>0c, <1>0d DEF PublicationExclusion
  <2>3. PublicationPredecessorOrder
    BY <1>0d DEF PublicationPredecessorOrder
  <2>4. PublicationAcknowledgement
    BY <1>0d, <1>0e, <1>0g DEF PublicationAcknowledgement
  <2> QED BY <2>1, <2>2, <2>3, <2>4 DEF PublicationSafety
<1>4. Ownership
  <2>1. s.owned \subseteq s.issued
    BY <1>0c, <1>0d
  <2>1a. s.authority \cup s.exported = {}
    BY <1>0e
  <2>1b. CohortsOf(s.authority \cup s.exported) = {}
    BY <1>0g, <2>1a
  <2>1c. s.owned \cup CohortsOf(s.authority \cup s.exported) = {}
    BY <1>0d, <2>1b
  <2>1d. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) = {}
    BY <2>1c DEF Batches
  <2>2. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated
    BY <1>0g, <2>1d
  <2>3. s.ready \subseteq (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned)
    BY <1>0c, <1>0d
  <2>4. s.batchBorrow \cup s.headBorrow \subseteq s.owned
    BY <1>0d
  <2>5. s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls
    BY <1>0d
  <2>6. s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {}
    BY <1>0c, <1>0d
  <2>7. s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow
    BY <1>0c, <1>0d
  <2>8. s.unknown \subseteq (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted)
    BY <1>0d
  <2>9. s.absent \subseteq s.headCalls \ s.headBorrow
    BY <1>0d
  <2>9a. s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls)
    BY <1>0c, <1>0d
  <2>9ab. Batches(s.prepareFailed) \subseteq s.prepareCalls \ s.prepareBorrow
    BY <1>0b, <1>0c DEF Batches
  <2>9aa. s.batchFailed \subseteq
        (s.owned \cap s.batchCalls) \ (s.batchBorrow \cup s.stored \cup s.headCalls)
    BY <1>0c, <1>0d
  <2>9b. s.projection \subseteq (s.owned \cap s.validated) \ s.abandoned
    BY <1>0c, <1>0d
  <2>9c. s.headBorrow \cup s.accepted \subseteq s.projection
    BY <1>0c, <1>0d
  <2>9d. (s.unknown \cup s.absent) \cap s.projection = {}
    BY <1>0c, <1>0d
  <2>10. s.headBorrow # {} => s.unknown = {}
    BY <1>0d
  <2>11. ~s.online => s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
            s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected
    BY <1>0a, <1>0b, <1>0d, <1>0f
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9,
      <2>9a, <2>9ab, <2>9aa, <2>9b, <2>9c, <2>9d, <2>10, <2>11 DEF Ownership
<1>5. PreparationOwnership
  <2>1. s.prepareBorrow \subseteq s.prepareCalls \cap Allocated
    BY <1>0b, <1>0g
  <2>2. \A t \in MemberDomain : Fragment(t) \in s.prepareBorrow =>
            Input(t) \in Allocated /\ t \in s.admitted \ BoundMembers
    BY <1>0b
  <2>3. \A c \in CohortDomain : Batch(c) \in s.prepareBorrow =>
            c \in s.owned /\ Fragments(Members(c)) \subseteq Allocated
    BY <1>0b
  <2>4. \A t \in s.prepared : Fragment(t) \in s.prepareCalls \ s.prepareBorrow
    BY <1>0a, <1>0b
  <2>5. \A t \in s.prepared : Input(t) \notin Allocated
    BY <1>0a
  <2>6. \A c \in s.sealed : Batch(c) \in s.prepareCalls \ s.prepareBorrow
    BY <1>0b, <1>0c
  <2>7. \A t \in MemberDomain : Input(t) \in Allocated =>
            t \in s.pending \/ Fragment(t) \in s.prepareBorrow
    BY <1>0a, <1>0b, <1>0g
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF PreparationOwnership
<1>6. ResourceBounds
  <2>1. Cardinality(LiveMembers) <= QueueCapacity
    BY <1>0a, FS_EmptySet DEF ConstantsOK, LiveMembers
  <2>2. Cardinality(s.owned) <= Capacity
    BY <1>0d, FS_EmptySet DEF ConstantsOK
  <2>3. Cardinality(s.ready) <= Capacity
    BY <1>0c, FS_EmptySet DEF ConstantsOK
  <2>4. Cardinality(s.headBorrow) <= 1
    BY <1>0d, FS_EmptySet
  <2>4a. Cardinality(s.projection) <= 1
    BY <1>0c, FS_EmptySet
  <2>5. Cardinality(s.prepareBorrow) <= PrepareCapacity
    BY <1>0b, FS_EmptySet DEF ConstantsOK
  <2>6. Cardinality(UsedBytes) <= Cardinality(ByteDomain)
    BY <1>0g, FS_EmptySet, FS_Subset DEF ConstantsOK
  <2>7. \A left, right \in Resources : left # right =>
            s.buffers[left] \cap s.buffers[right] = {}
    BY <1>0b
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>4a, <2>5, <2>6, <2>7
      DEF ResourceBounds
<1>7. AuthoritySafety
  <2>1. CohortsOf(s.authority \cup s.exported) \subseteq s.headCalls \ s.headBorrow
    BY <1>0d, <1>0e, <1>0g
  <2>2. s.headBorrow \cap s.abandoned = {}
    BY <1>0c, <1>0d
  <2>3. s.unknownEpisode => s.halted
    BY <1>0f
  <2>4. s.exported \subseteq s.delivered
    BY <1>0a, <1>0e
  <2>4a. s.delivered \subseteq s.collected
    BY <1>0a, <1>0e
  <2>4b. s.authority \cap s.discarded = {}
    BY <1>0a, <1>0e
  <2>5. s.resolutionWrites = 0
    BY <1>0f
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>4a, <2>4b, <2>5 DEF AuthoritySafety
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM AdmissionPreparationPreserves ==
    ASSUME ConstantsOK, Safety,
        (\E t \in MemberDomain, bytes \in SUBSET ByteDomain :
            Admit(t, bytes) \/ StartTxnPrepare(t, bytes)) \/
        (\E t \in MemberDomain, success \in BOOLEAN : JoinTxnPrepare(t, success))
    PROVE Safety'
<1>1. CASE \E t \in MemberDomain, bytes \in SUBSET ByteDomain : Admit(t, bytes)
  <2>0. PICK t \in MemberDomain, bytes \in SUBSET ByteDomain : Admit(t, bytes)
    BY <1>1
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0aa. s' = AdmitState(t, bytes)
    BY <2>0 DEF Admit
  <2>0b. /\ DOMAIN AdmitState(t, bytes) = StateFields
           /\ AdmitState(t, bytes).admitted = s.admitted \cup {t}
           /\ AdmitState(t, bytes).pending = s.pending \cup {t}
           /\ AdmitState(t, bytes).buffers = [s.buffers EXCEPT ![Input(t)] = bytes]
           /\ \A field \in StateFields \ {"admitted", "pending", "buffers"} :
                AdmitState(t, bytes)[field] = s[field]
    BY AdmitStateProjection, <2>0a
  <2>0c. /\ s'.collected = s.collected
           /\ s'.delivered = s.delivered
           /\ s'.discarded = s.discarded
           /\ s'.prepared = s.prepared
           /\ s'.rejected = s.rejected
    BY <2>0aa, <2>0a, AdmitStatePreservesMemberFields
  <2>0d. /\ s'.groups = s.groups
           /\ s'.prepareCalls = s.prepareCalls
           /\ s'.prepareBorrow = s.prepareBorrow
    BY <2>0aa, <2>0a, AdmitStatePreservesPreparationFields
  <2>0e. /\ s'.sealed = s.sealed
           /\ s'.ready = s.ready
           /\ s'.issued = s.issued
           /\ s'.stored = s.stored
           /\ s'.published = s.published
           /\ s'.retired = s.retired
           /\ s'.excluded = s.excluded
           /\ s'.abandoned = s.abandoned
           /\ s'.prepareFailed = s.prepareFailed
           /\ s'.batchFailed = s.batchFailed
           /\ s'.validated = s.validated
           /\ s'.projection = s.projection
    BY <2>0aa, <2>0a, AdmitStatePreservesCohortFields
  <2>0f. /\ s'.batchCalls = s.batchCalls
           /\ s'.headCalls = s.headCalls
           /\ s'.batchBorrow = s.batchBorrow
           /\ s'.headBorrow = s.headBorrow
           /\ s'.owned = s.owned
           /\ s'.accepted = s.accepted
           /\ s'.unknown = s.unknown
           /\ s'.absent = s.absent
    BY <2>0aa, <2>0a, AdmitStatePreservesPublicationFields
  <2>0g. /\ s'.authority = s.authority
           /\ s'.exported = s.exported
           /\ s'.ack = s.ack
    BY <2>0aa, <2>0a, AdmitStatePreservesAuthorityFields
  <2>0h. /\ s'.closing = s.closing
           /\ s'.online = s.online
           /\ s'.fenced = s.fenced
           /\ s'.halted = s.halted
           /\ s'.unknownEpisode = s.unknownEpisode
           /\ s'.resolutionWrites = s.resolutionWrites
    BY <2>0aa, <2>0a, AdmitStatePreservesLifecycleFields
  <2>0i. /\ s'.admitted = s.admitted \cup {t}
           /\ s'.pending = s.pending \cup {t}
           /\ s'.buffers = [s.buffers EXCEPT ![Input(t)] = bytes]
    BY <2>0aa, <2>0b
  <2>0j. t \notin s.admitted
    BY <2>0 DEF Admit
  <2>0k. /\ t \notin s.prepared /\ t \notin s.rejected
           /\ t \notin s.collected /\ t \notin BoundMembers
    BY <2>0j, SafetyTypeOK, SafetyMembership
        DEF TypeOK, MemberStateTypes, MembershipSafety, AdmissionMembership, BoundMembership
  <2>0l. BoundMembers' = BoundMembers
    BY <2>0d, <2>0e DEF BoundMembers, Members
  <2>0m. CohortsOf(s.ack)' = CohortsOf(s.ack)
    BY <2>0d, <2>0e, <2>0g DEF CohortsOf, Members
  <2>0n. CohortsOf(s.authority \cup s.exported)' =
             CohortsOf(s.authority \cup s.exported)
    BY <2>0d, <2>0e, <2>0g DEF CohortsOf, Members
  <2>0o. \A r \in Resources :
           s'.buffers[r] = IF r = Input(t) THEN bytes ELSE s.buffers[r]
    BY <2>0i, SafetyTypeOK DEF TypeOK, PreparationMapTypes
  <2>0p. bytes # {}
    BY <2>0 DEF Admit, Fresh
  <2>0q. Input(t) \in Allocated'
    BY <2>0o, <2>0p DEF Allocated, Resources, Inputs, Input
  <2>0r. Allocated \subseteq Allocated'
    <3> SUFFICES ASSUME NEW r \in Allocated
                 PROVE r \in Allocated'
      OBVIOUS
    <3>1. r \in Resources /\ s.buffers[r] # {}
      BY DEF Allocated
    <3>2. CASE r = Input(t)
      BY <2>0q, <3>2
    <3>3. CASE r # Input(t)
      BY <2>0o, <3>1, <3>3 DEF Allocated
    <3> QED BY <3>2, <3>3
  <2>0s. \A u \in MemberDomain : u # t =>
           (Input(u) \in Allocated' <=> Input(u) \in Allocated)
    <3> SUFFICES ASSUME NEW u \in MemberDomain, u # t
                 PROVE Input(u) \in Allocated' <=> Input(u) \in Allocated
      OBVIOUS
    <3>1. Input(u) \in Resources /\ Input(u) # Input(t)
      BY DEF Resources, Inputs, Input
    <3> QED BY <2>0o, <3>1 DEF Allocated
  <2>0t. LiveMembers' = LiveMembers \cup {t}
    BY <2>0c, <2>0i, <2>0k DEF LiveMembers
  <2>0u. t \notin LiveMembers
    BY <2>0j DEF LiveMembers
  <2>1. TypeOK'
    <3>1. StateShape'
      BY <2>0aa, <2>0b DEF StateShape
    <3>1a. MemberStateTypes
      BY SafetyTypeOK DEF TypeOK
    <3>2. MemberStateTypes'
      <4>0. /\ s'.collected = s.collected
              /\ s'.delivered = s.delivered
              /\ s'.discarded = s.discarded
              /\ s'.prepared = s.prepared
              /\ s'.rejected = s.rejected
        BY <2>0c
      <4>1. s'.admitted \subseteq MemberDomain
        BY <2>0, <2>0aa, <2>0b, <3>1a DEF Admit, MemberStateTypes
      <4>2. s'.pending \subseteq MemberDomain
        BY <2>0, <2>0aa, <2>0b, <3>1a DEF Admit, MemberStateTypes
      <4>3. s'.collected \subseteq s'.admitted
        BY <2>0aa, <2>0b, <4>0, <3>1a DEF MemberStateTypes
      <4>3a. s'.delivered \subseteq s'.collected
        BY <4>0, <3>1a DEF MemberStateTypes
      <4>3b. s'.discarded \subseteq s'.collected
        BY <4>0, <3>1a DEF MemberStateTypes
      <4>4. s'.prepared \subseteq MemberDomain
        BY <4>0, <3>1a DEF MemberStateTypes
      <4>5. s'.rejected \subseteq MemberDomain
        BY <4>0, <3>1a DEF MemberStateTypes
      <4> QED BY <4>1, <4>2, <4>3, <4>3a, <4>3b, <4>4, <4>5 DEF MemberStateTypes
    <3>2a. PreparationMapTypes
      BY SafetyTypeOK DEF TypeOK
    <3>3. PreparationMapTypes'
      <4>0. /\ s'.groups = s.groups
              /\ s'.prepareCalls = s.prepareCalls
              /\ s'.prepareBorrow = s.prepareBorrow
        BY <2>0d
      <4>1. Input(t) \in Resources
        BY DEF Resources, Inputs, Input
      <4>2. s'.buffers = [s.buffers EXCEPT ![Input(t)] = bytes]
        BY <2>0aa, <2>0b
      <4>3. s'.buffers \in [Resources -> SUBSET ByteDomain]
        BY <2>0, <3>2a, <4>1, <4>2 DEF PreparationMapTypes
      <4> QED BY <3>2a, <4>0, <4>3 DEF PreparationMapTypes
    <3>3a. CohortStateTypes
      BY SafetyTypeOK DEF TypeOK
    <3>4. CohortStateTypes'
      <4>0. /\ s'.sealed = s.sealed
              /\ s'.ready = s.ready
              /\ s'.issued = s.issued
              /\ s'.stored = s.stored
              /\ s'.published = s.published
              /\ s'.retired = s.retired
              /\ s'.excluded = s.excluded
              /\ s'.abandoned = s.abandoned
              /\ s'.prepareFailed = s.prepareFailed
              /\ s'.batchFailed = s.batchFailed
              /\ s'.validated = s.validated
              /\ s'.projection = s.projection
        BY <2>0e
      <4> QED BY <3>3a, <4>0 DEF CohortStateTypes
    <3>4a. PublicationStateTypes
      BY SafetyTypeOK DEF TypeOK
    <3>5. PublicationStateTypes'
      <4>0. /\ s'.batchCalls = s.batchCalls
              /\ s'.headCalls = s.headCalls
              /\ s'.batchBorrow = s.batchBorrow
              /\ s'.headBorrow = s.headBorrow
              /\ s'.owned = s.owned
              /\ s'.accepted = s.accepted
              /\ s'.unknown = s.unknown
              /\ s'.absent = s.absent
        BY <2>0f
      <4> QED BY <3>4a, <4>0 DEF PublicationStateTypes
    <3>5a. AuthorityStateTypes
      BY SafetyTypeOK DEF TypeOK
    <3>6. AuthorityStateTypes'
      <4>0. /\ s'.authority = s.authority
              /\ s'.exported = s.exported
              /\ s'.ack = s.ack
        BY <2>0g
      <4> QED BY <3>5a, <4>0 DEF AuthorityStateTypes
    <3>6a. LifecycleStateTypes
      BY SafetyTypeOK DEF TypeOK
    <3>7. LifecycleStateTypes'
      <4>0. /\ s'.closing = s.closing
              /\ s'.online = s.online
              /\ s'.fenced = s.fenced
              /\ s'.halted = s.halted
              /\ s'.unknownEpisode = s.unknownEpisode
              /\ s'.resolutionWrites = s.resolutionWrites
        BY <2>0h
      <4> QED BY <3>6a, <4>0 DEF LifecycleStateTypes
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>0. MembershipSafety
      BY SafetyMembership
    <3>0a. BoundMembers' = BoundMembers
      BY <2>0l
    <3>1. AdmissionMembership'
      BY <2>0, <2>0aa, <2>0b, <2>0c, <3>0
          DEF Admit, MembershipSafety, AdmissionMembership
    <3>2. BoundMembership'
      <4>1. BoundMembers' \subseteq s'.prepared
        BY <2>0c, <2>0l, <3>0 DEF MembershipSafety, BoundMembership
      <4>2. s'.pending \cap BoundMembers' = {}
        BY <2>0i, <2>0k, <2>0l, <3>0 DEF MembershipSafety, BoundMembership
      <4> QED BY <4>1, <4>2 DEF BoundMembership
    <3>3. GroupPartition'
      BY <2>0d, <2>0e, <3>0 DEF MembershipSafety, GroupPartition, Members
    <3>4. AuthorityMembership'
      BY <2>0c, <2>0g, <3>0, <3>0a DEF MembershipSafety, AuthorityMembership
    <3>5. TerminalMembership'
      <4>1. s'.rejected \cap s'.pending = {}
        BY <2>0c, <2>0i, <2>0k, <3>0 DEF MembershipSafety, TerminalMembership
      <4>2. s'.collected \cap s'.pending = {}
        BY <2>0c, <2>0i, <2>0k, <3>0 DEF MembershipSafety, TerminalMembership
      <4>3. s'.delivered \subseteq s'.collected
        BY <2>0c, <3>0 DEF MembershipSafety, TerminalMembership
      <4>4. s'.discarded \subseteq s'.collected
        BY <2>0c, <3>0 DEF MembershipSafety, TerminalMembership
      <4>5. s'.delivered \cap s'.discarded = {}
        BY <2>0c, <3>0 DEF MembershipSafety, TerminalMembership
      <4>6. (CohortsOf(s.collected) \subseteq s.headCalls \cup s.excluded)'
        BY <2>0c, <2>0d, <2>0e, <2>0f, <3>0
            DEF MembershipSafety, TerminalMembership, CohortsOf, Members
      <4>7. (CohortsOf(s.collected) \cap (s.batchBorrow \cup s.headBorrow) = {})'
        BY <2>0c, <2>0d, <2>0e, <2>0f, <3>0
            DEF MembershipSafety, TerminalMembership, CohortsOf, Members
      <4>8. (Batches(CohortsOf(s.collected)) \cap s.prepareBorrow = {})'
        BY <2>0c, <2>0d, <2>0e, <3>0
            DEF MembershipSafety, TerminalMembership, CohortsOf, Members, Batches
      <4> QED BY <4>1, <4>2, <4>3, <4>4, <4>5, <4>6, <4>7, <4>8
          DEF TerminalMembership, CohortsOf, Members, Batches
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>0. PublicationSafety
      BY SafetyPublication
    <3>1. PublicationOrder'
      BY <2>0e, <2>0f, <3>0 DEF PublicationSafety, PublicationOrder
    <3>2. PublicationExclusion'
      BY <2>0e, <2>0f, <3>0 DEF PublicationSafety, PublicationExclusion
    <3>3. PublicationPredecessorOrder'
      BY <2>0e, <2>0f, <3>0
          DEF PublicationSafety, PublicationPredecessorOrder, Earlier
    <3>4. PublicationAcknowledgement'
      BY <2>0e, <2>0m, <3>0
          DEF PublicationSafety, PublicationAcknowledgement
    <3> QED BY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY SafetyOwnership
    <3>1. (s.owned \subseteq s.issued)'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>2. (Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated)'
      BY <2>0f, <2>0n, <2>0r, <3>0, FS_Subset DEF Ownership
    <3>3. (s.ready \subseteq
             (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned))'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>4. (s.batchBorrow \cup s.headBorrow \subseteq s.owned)'
      BY <2>0f, <3>0 DEF Ownership
    <3>5. (s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls)'
      BY <2>0f, <3>0 DEF Ownership
    <3>6. (s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {})'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>7. (s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow)'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>8. (s.unknown \subseteq
             (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted))'
      BY <2>0f, <3>0 DEF Ownership
    <3>9. (s.absent \subseteq s.headCalls \ s.headBorrow)'
      BY <2>0f, <3>0 DEF Ownership
    <3>9a. (s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls))'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>9ab. (Batches(s.prepareFailed) \subseteq s.prepareCalls \ s.prepareBorrow)'
      BY <2>0d, <2>0e, <3>0 DEF Ownership, Batches
    <3>9aa. (s.batchFailed \subseteq
          (s.owned \cap s.batchCalls) \ (s.batchBorrow \cup s.stored \cup s.headCalls))'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>9b. (s.projection \subseteq (s.owned \cap s.validated) \ s.abandoned)'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>9c. (s.headBorrow \cup s.accepted \subseteq s.projection)'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>9d. ((s.unknown \cup s.absent) \cap s.projection = {})'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>10. (s.headBorrow # {} => s.unknown = {})'
      BY <2>0f, <3>0 DEF Ownership
    <3>11. (~s.online => s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
             s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected)'
      BY <2>0, <2>0h DEF Admit
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7, <3>8, <3>9,
        <3>9a, <3>9ab, <3>9aa, <3>9b, <3>9c, <3>9d, <3>10, <3>11 DEF Ownership
  <2>5. PreparationOwnership'
    <3>0. PreparationOwnership
      BY SafetyPreparationOwnership
    <3>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
      BY <2>0d, <2>0r, <3>0, FS_Subset DEF PreparationOwnership
    <3>2. (\A u \in MemberDomain : Fragment(u) \in s.prepareBorrow =>
             Input(u) \in Allocated /\ u \in s.admitted \ BoundMembers)'
      BY <2>0d, <2>0i, <2>0l, <2>0r, <3>0, FS_Subset DEF PreparationOwnership
    <3>3. (\A c \in CohortDomain : Batch(c) \in s.prepareBorrow =>
             c \in s.owned /\ Fragments(Members(c)) \subseteq Allocated)'
      BY <2>0d, <2>0f, <2>0r, <3>0, FS_Subset DEF PreparationOwnership, Members
    <3>4. (\A u \in s.prepared : Fragment(u) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0c, <2>0d, <3>0 DEF PreparationOwnership
    <3>5. (\A u \in s.prepared : Input(u) \notin Allocated)'
      <4> SUFFICES ASSUME NEW u \in s'.prepared
                   PROVE Input(u) \notin Allocated'
        OBVIOUS
      <4>1. u \in s.prepared /\ u # t
        BY <2>0c, <2>0k
      <4>1a. u \in MemberDomain
        BY SafetyTypeOK, <4>1 DEF TypeOK, MemberStateTypes
      <4>2. Input(u) \notin Allocated
        BY <3>0, <4>1 DEF PreparationOwnership
      <4>3. Input(u) \in Allocated' <=> Input(u) \in Allocated
        BY <2>0s, <4>1, <4>1a
      <4> QED BY <4>2, <4>3
    <3>6. (\A c \in s.sealed : Batch(c) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0d, <2>0e, <3>0 DEF PreparationOwnership
    <3>7. (\A u \in MemberDomain : Input(u) \in Allocated =>
             u \in s.pending \/ Fragment(u) \in s.prepareBorrow)'
      <4> SUFFICES ASSUME NEW u \in MemberDomain, Input(u) \in Allocated'
                   PROVE u \in s'.pending \/ Fragment(u) \in s'.prepareBorrow
        OBVIOUS
      <4>1. CASE u = t
        BY <2>0i, <4>1
      <4>2. CASE u # t
        <5>1. Input(u) \in Allocated
          BY <2>0s, <4>2
        <5> QED BY <2>0d, <2>0i, <3>0, <5>1 DEF PreparationOwnership
      <4> QED BY <4>1, <4>2
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF PreparationOwnership
  <2>6. ResourceBounds'
    <3>0. ResourceBounds
      BY SafetyResourceBounds
    <3>1a. IsFiniteSet(LiveMembers)
      BY SafetyTypeOK, FS_Subset DEF ConstantsOK, TypeOK, MemberStateTypes, LiveMembers
    <3>1b. Cardinality(LiveMembers') = Cardinality(LiveMembers) + 1
      BY <2>0t, <2>0u, <3>1a, FS_AddElement
    <3>1c. Cardinality(LiveMembers) < QueueCapacity
      BY <2>0 DEF Admit
    <3>1d. Cardinality(LiveMembers) \in Nat /\ QueueCapacity \in Nat
      BY <3>1a, FS_CardinalityType DEF ConstantsOK
    <3>1. Cardinality(LiveMembers') <= QueueCapacity
      BY ONLY <3>1b, <3>1c, <3>1d
    <3>2. Cardinality(s'.owned) <= Capacity
      BY <2>0f, <3>0 DEF ResourceBounds
    <3>3. Cardinality(s'.ready) <= Capacity
      BY <2>0e, <3>0 DEF ResourceBounds
    <3>4. Cardinality(s'.headBorrow) <= 1
      BY <2>0f, <3>0 DEF ResourceBounds
    <3>4a. Cardinality(s'.projection) <= 1
      BY <2>0e, <3>0 DEF ResourceBounds
    <3>5. Cardinality(s'.prepareBorrow) <= PrepareCapacity
      BY <2>0d, <3>0 DEF ResourceBounds
    <3>6a. UsedBytes' \subseteq ByteDomain
      BY <2>1 DEF TypeOK, PreparationMapTypes, UsedBytes, Resources
    <3>6b. IsFiniteSet(ByteDomain)
      BY DEF ConstantsOK
    <3>6. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
      BY ONLY <3>6a, <3>6b, FS_Subset
    <3>7. \A left, right \in Resources : left # right =>
             s'.buffers[left] \cap s'.buffers[right] = {}
      <4> SUFFICES ASSUME NEW left \in Resources,
                           NEW right \in Resources,
                           left # right
                   PROVE s'.buffers[left] \cap s'.buffers[right] = {}
        OBVIOUS
      <4>1. CASE left = Input(t)
        <5>1. /\ s'.buffers[left] = bytes
               /\ s'.buffers[right] = s.buffers[right]
          BY <2>0o, <4>1
        <5>2. s.buffers[right] \subseteq UsedBytes
          BY DEF UsedBytes
        <5>3. bytes \cap UsedBytes = {}
          BY <2>0 DEF Admit, Fresh
        <5> QED BY <5>1, <5>2, <5>3
      <4>2. CASE right = Input(t)
        <5>1. /\ s'.buffers[left] = s.buffers[left]
               /\ s'.buffers[right] = bytes
          BY <2>0o, <4>2
        <5>2. s.buffers[left] \subseteq UsedBytes
          BY DEF UsedBytes
        <5>3. bytes \cap UsedBytes = {}
          BY <2>0 DEF Admit, Fresh
        <5> QED BY <5>1, <5>2, <5>3
      <4>3. CASE left # Input(t) /\ right # Input(t)
        BY <2>0o, <3>0, <4>3 DEF ResourceBounds
      <4> QED BY <4>1, <4>2, <4>3
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>4a, <3>5, <3>6, <3>7
        DEF ResourceBounds
  <2>7. AuthoritySafety'
    <3>0. AuthoritySafety
      BY SafetyAuthority
    <3>1. (CohortsOf(s.authority \cup s.exported) \subseteq
              s.headCalls \ s.headBorrow)'
      BY <2>0f, <2>0n, <3>0 DEF AuthoritySafety
    <3>2. (s.headBorrow \cap s.abandoned = {})'
      BY <2>0e, <2>0f, <3>0 DEF AuthoritySafety
    <3>3. (s.unknownEpisode => s.halted)'
      BY <2>0h, <3>0 DEF AuthoritySafety
    <3>4. (s.exported \subseteq s.delivered)'
      BY <2>0c, <2>0g, <3>0 DEF AuthoritySafety
    <3>4a. (s.delivered \subseteq s.collected)'
      BY <2>0c, <3>0 DEF AuthoritySafety
    <3>4b. (s.authority \cap s.discarded = {})'
      BY <2>0c, <2>0g, <3>0 DEF AuthoritySafety
    <3>5. (s.resolutionWrites = 0)'
      BY <2>0h, <3>0 DEF AuthoritySafety
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>4a, <3>4b, <3>5 DEF AuthoritySafety
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1>2. CASE \E t \in MemberDomain, bytes \in SUBSET ByteDomain : StartTxnPrepare(t, bytes)
  <2>0. PICK t \in MemberDomain, bytes \in SUBSET ByteDomain : StartTxnPrepare(t, bytes)
    BY <1>2
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0aa. s' = StartTxnPrepareState(t, bytes)
    BY <2>0 DEF StartTxnPrepare
  <2>0b. /\ s'.admitted = s.admitted
           /\ s'.collected = s.collected
           /\ s'.delivered = s.delivered
           /\ s'.discarded = s.discarded
           /\ s'.pending = s.pending
           /\ s'.prepared = s.prepared
           /\ s'.rejected = s.rejected
    BY <2>0aa, <2>0a, StartTxnPrepareStatePreservesMemberFields
  <2>0c. /\ s'.groups = s.groups
           /\ s'.sealed = s.sealed
           /\ s'.ready = s.ready
           /\ s'.issued = s.issued
           /\ s'.stored = s.stored
           /\ s'.published = s.published
           /\ s'.retired = s.retired
           /\ s'.excluded = s.excluded
           /\ s'.abandoned = s.abandoned
           /\ s'.prepareFailed = s.prepareFailed
           /\ s'.batchFailed = s.batchFailed
           /\ s'.validated = s.validated
           /\ s'.projection = s.projection
    BY <2>0aa, <2>0a, StartTxnPrepareStatePreservesCohortFields
  <2>0d. /\ s'.batchCalls = s.batchCalls
           /\ s'.headCalls = s.headCalls
           /\ s'.batchBorrow = s.batchBorrow
           /\ s'.headBorrow = s.headBorrow
           /\ s'.owned = s.owned
           /\ s'.accepted = s.accepted
           /\ s'.unknown = s.unknown
           /\ s'.absent = s.absent
    BY <2>0aa, <2>0a, StartTxnPrepareStatePreservesPublicationFields
  <2>0e. /\ s'.authority = s.authority
           /\ s'.exported = s.exported
           /\ s'.ack = s.ack
    BY <2>0aa, <2>0a, StartTxnPrepareStatePreservesAuthorityFields
  <2>0f. /\ s'.closing = s.closing
           /\ s'.online = s.online
           /\ s'.fenced = s.fenced
           /\ s'.halted = s.halted
           /\ s'.unknownEpisode = s.unknownEpisode
           /\ s'.resolutionWrites = s.resolutionWrites
    BY <2>0aa, <2>0a, StartTxnPrepareStatePreservesLifecycleFields
  <2>0g. /\ DOMAIN s' = StateFields
           /\ s'.prepareCalls = s.prepareCalls \cup {Fragment(t)}
           /\ s'.prepareBorrow = s.prepareBorrow \cup {Fragment(t)}
           /\ s'.buffers = [s.buffers EXCEPT ![Fragment(t)] = bytes]
    BY <2>0aa, <2>0a, StartTxnPrepareStateProjection
  <2>0h. /\ t \in s.pending
           /\ Fragment(t) \notin s.prepareCalls
           /\ Input(t) \in Allocated
           /\ Fresh(bytes)
           /\ Cardinality(s.prepareBorrow) < PrepareCapacity
    BY <2>0 DEF StartTxnPrepare
  <2>0i. t \in s.admitted \ BoundMembers
    BY <2>0h, SafetyMembership
        DEF MembershipSafety, AdmissionMembership, BoundMembership
  <2>0j. t \notin s.prepared
    BY <2>0h, SafetyPreparationOwnership DEF PreparationOwnership
  <2>0k. Fragment(t) \notin s.prepareBorrow
    BY <2>0h, SafetyPreparationOwnership DEF PreparationOwnership
  <2>0l. BoundMembers' = BoundMembers
    BY <2>0b, <2>0c DEF BoundMembers, Members
  <2>0m. CohortsOf(s.ack)' = CohortsOf(s.ack)
    BY <2>0c, <2>0e DEF CohortsOf, Members
  <2>0n. CohortsOf(s.authority \cup s.exported)' =
             CohortsOf(s.authority \cup s.exported)
    BY <2>0c, <2>0e DEF CohortsOf, Members
  <2>0o. \A r \in Resources :
           s'.buffers[r] = IF r = Fragment(t) THEN bytes ELSE s.buffers[r]
    BY <2>0g, SafetyTypeOK DEF TypeOK, PreparationMapTypes
  <2>0p. /\ bytes # {}
           /\ bytes \cap UsedBytes = {}
    BY <2>0h DEF Fresh
  <2>0q. Fragment(t) \in Allocated'
    BY <2>0o, <2>0p DEF Allocated, Resources, Fragments, Fragment
  <2>0r. Allocated \subseteq Allocated'
    <3> SUFFICES ASSUME NEW r \in Allocated
                 PROVE r \in Allocated'
      OBVIOUS
    <3>1. r \in Resources /\ s.buffers[r] # {}
      BY DEF Allocated
    <3>2. CASE r = Fragment(t)
      BY <2>0q, <3>2
    <3>3. CASE r # Fragment(t)
      BY <2>0o, <3>1, <3>3 DEF Allocated
    <3> QED BY <3>2, <3>3
  <2>0s. \A u \in MemberDomain :
           (Input(u) \in Allocated' <=> Input(u) \in Allocated)
    <3> SUFFICES ASSUME NEW u \in MemberDomain
                 PROVE Input(u) \in Allocated' <=> Input(u) \in Allocated
      OBVIOUS
    <3>1. Input(u) \in Resources /\ Input(u) # Fragment(t)
      BY DEF Resources, Inputs, Fragments, Input, Fragment
    <3> QED BY <2>0o, <3>1 DEF Allocated
  <2>0t. LiveMembers' = LiveMembers
    BY <2>0b DEF LiveMembers
  <2>1. TypeOK'
    <3>0. TypeOK
      BY SafetyTypeOK
    <3>1. StateShape'
      BY <2>0g DEF StateShape
    <3>2. MemberStateTypes'
      BY <2>0b, <3>0 DEF TypeOK, MemberStateTypes
    <3>3. PreparationMapTypes'
      <4>1. Fragment(t) \in Work /\ Fragment(t) \in Resources
        BY DEF Work, Resources, Fragments, Fragment
      <4>2. /\ s'.prepareCalls \subseteq Work
              /\ s'.prepareBorrow \subseteq Work
        BY <2>0g, <3>0, <4>1 DEF TypeOK, PreparationMapTypes
      <4>3. s'.buffers \in [Resources -> SUBSET ByteDomain]
        BY <2>0, <2>0g, <3>0, <4>1 DEF TypeOK, PreparationMapTypes
      <4>4. s'.groups \in [CohortDomain -> SUBSET MemberDomain]
        BY <2>0c, <3>0 DEF TypeOK, PreparationMapTypes
      <4> QED BY <4>2, <4>3, <4>4 DEF PreparationMapTypes
    <3>4. CohortStateTypes'
      BY <2>0c, <3>0 DEF TypeOK, CohortStateTypes
    <3>5. PublicationStateTypes'
      BY <2>0d, <3>0 DEF TypeOK, PublicationStateTypes
    <3>6. AuthorityStateTypes'
      BY <2>0e, <3>0 DEF TypeOK, AuthorityStateTypes
    <3>7. LifecycleStateTypes'
      BY <2>0f, <3>0 DEF TypeOK, LifecycleStateTypes
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    BY <2>0b, <2>0c, <2>0d, <2>0e, <2>0g, <2>0l, SafetyMembership
        DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
        AuthorityMembership, TerminalMembership, CohortsOf, Members, Batches, Batch, Fragment
  <2>3. PublicationSafety'
    BY <2>0c, <2>0d, <2>0m, SafetyPublication
        DEF PublicationSafety, PublicationOrder, PublicationExclusion,
        PublicationPredecessorOrder, PublicationAcknowledgement
  <2>4. Ownership'
    <3>0. Ownership
      BY SafetyOwnership
    <3>1. (s.owned \subseteq s.issued)'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>2. (Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated)'
      BY <2>0d, <2>0n, <2>0r, <3>0, FS_Subset DEF Ownership
    <3>3. (s.ready \subseteq
             (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned))'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>4. (s.batchBorrow \cup s.headBorrow \subseteq s.owned)'
      BY <2>0d, <3>0 DEF Ownership
    <3>5. (s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls)'
      BY <2>0d, <3>0 DEF Ownership
    <3>6. (s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {})'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>7. (s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow)'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>8. (s.unknown \subseteq
             (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted))'
      BY <2>0d, <3>0 DEF Ownership
    <3>9. (s.absent \subseteq s.headCalls \ s.headBorrow)'
      BY <2>0d, <3>0 DEF Ownership
    <3>9a. (s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls))'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>9ab. (Batches(s.prepareFailed) \subseteq s.prepareCalls \ s.prepareBorrow)'
      BY <2>0c, <2>0g, <3>0 DEF Ownership, Batches, Batch, Fragment
    <3>9aa. (s.batchFailed \subseteq
          (s.owned \cap s.batchCalls) \ (s.batchBorrow \cup s.stored \cup s.headCalls))'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>9b. (s.projection \subseteq (s.owned \cap s.validated) \ s.abandoned)'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>9c. (s.headBorrow \cup s.accepted \subseteq s.projection)'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>9d. ((s.unknown \cup s.absent) \cap s.projection = {})'
      BY <2>0c, <2>0d, <3>0 DEF Ownership
    <3>10. (s.headBorrow # {} => s.unknown = {})'
      BY <2>0d, <3>0 DEF Ownership
    <3>11. (~s.online => s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
             s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected)'
      BY <2>0, <2>0f DEF StartTxnPrepare
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7, <3>8, <3>9,
        <3>9a, <3>9ab, <3>9aa, <3>9b, <3>9c, <3>9d, <3>10, <3>11 DEF Ownership
  <2>5. PreparationOwnership'
    <3>0. PreparationOwnership
      BY SafetyPreparationOwnership
    <3>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
      BY <2>0g, <2>0q, <2>0r, <3>0, FS_Subset DEF PreparationOwnership
    <3>2. (\A u \in MemberDomain : Fragment(u) \in s.prepareBorrow =>
             Input(u) \in Allocated /\ u \in s.admitted \ BoundMembers)'
      <4> SUFFICES ASSUME NEW u \in MemberDomain, Fragment(u) \in s'.prepareBorrow
                   PROVE Input(u) \in Allocated' /\ u \in s'.admitted \ BoundMembers'
        OBVIOUS
      <4>1. CASE u = t
        BY <2>0b, <2>0h, <2>0i, <2>0l, <2>0r, <4>1
      <4>2. CASE u # t
        <5>1. Fragment(u) # Fragment(t)
          BY <4>2 DEF Fragment
        <5>2. Fragment(u) \in s.prepareBorrow
          BY <2>0g, <5>1
        <5> QED BY <2>0b, <2>0l, <2>0r, <3>0, <5>2, FS_Subset
            DEF PreparationOwnership
      <4> QED BY <4>1, <4>2
    <3>3. (\A c \in CohortDomain : Batch(c) \in s.prepareBorrow =>
             c \in s.owned /\ Fragments(Members(c)) \subseteq Allocated)'
      <4> SUFFICES ASSUME NEW c \in CohortDomain, Batch(c) \in s'.prepareBorrow
                   PROVE c \in s'.owned /\ Fragments(Members(c)') \subseteq Allocated'
        OBVIOUS
      <4>1. Batch(c) # Fragment(t)
        BY DEF Batch, Fragment
      <4>2. Batch(c) \in s.prepareBorrow
        BY <2>0g, <4>1
      <4> QED BY <2>0c, <2>0d, <2>0r, <3>0, <4>2, FS_Subset
          DEF PreparationOwnership, Members
    <3>4. (\A u \in s.prepared : Fragment(u) \in s.prepareCalls \ s.prepareBorrow)'
      <4> SUFFICES ASSUME NEW u \in s'.prepared
                   PROVE Fragment(u) \in s'.prepareCalls \ s'.prepareBorrow
        OBVIOUS
      <4>1. u \in s.prepared /\ u # t
        BY <2>0b, <2>0j
      <4>2. Fragment(u) # Fragment(t)
        BY <4>1 DEF Fragment
      <4> QED BY <2>0g, <3>0, <4>1, <4>2 DEF PreparationOwnership
    <3>5. (\A u \in s.prepared : Input(u) \notin Allocated)'
      <4> SUFFICES ASSUME NEW u \in s'.prepared
                   PROVE Input(u) \notin Allocated'
        OBVIOUS
      <4>1. u \in s.prepared /\ u \in MemberDomain
        BY <2>0b, SafetyTypeOK DEF TypeOK, MemberStateTypes
      <4>2. Input(u) \notin Allocated
        BY <3>0, <4>1 DEF PreparationOwnership
      <4>3. Input(u) \in Allocated' <=> Input(u) \in Allocated
        BY <2>0s, <4>1
      <4> QED BY <4>2, <4>3
    <3>6. (\A c \in s.sealed : Batch(c) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0c, <2>0g, <3>0 DEF PreparationOwnership, Batch, Fragment
    <3>7. (\A u \in MemberDomain : Input(u) \in Allocated =>
             u \in s.pending \/ Fragment(u) \in s.prepareBorrow)'
      <4> SUFFICES ASSUME NEW u \in MemberDomain, Input(u) \in Allocated'
                   PROVE u \in s'.pending \/ Fragment(u) \in s'.prepareBorrow
        OBVIOUS
      <4>1. Input(u) \in Allocated
        BY <2>0s
      <4> QED BY <2>0b, <2>0g, <3>0, <4>1 DEF PreparationOwnership
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF PreparationOwnership
  <2>6. ResourceBounds'
    <3>0. ResourceBounds
      BY SafetyResourceBounds
    <3>1. Cardinality(LiveMembers') <= QueueCapacity
      BY <2>0t, <3>0 DEF ResourceBounds
    <3>2. Cardinality(s'.owned) <= Capacity
      BY <2>0d, <3>0 DEF ResourceBounds
    <3>3. Cardinality(s'.ready) <= Capacity
      BY <2>0c, <3>0 DEF ResourceBounds
    <3>4. Cardinality(s'.headBorrow) <= 1
      BY <2>0d, <3>0 DEF ResourceBounds
    <3>4a. Cardinality(s'.projection) <= 1
      BY <2>0c, <3>0 DEF ResourceBounds
    <3>5aa. IsFiniteSet(MemberDomain)
      BY DEF ConstantsOK
    <3>5ab. [u \in MemberDomain |-> Fragment(u)]
               \in Surjection(MemberDomain, Fragments(MemberDomain))
      BY DEF Surjection, Fragments
    <3>5a. IsFiniteSet(Fragments(MemberDomain))
      BY <3>5aa, <3>5ab, FS_Surjection
    <3>5ba. IsFiniteSet(CohortDomain)
      BY DEF ConstantsOK
    <3>5bb. [d \in CohortDomain |-> Batch(d)]
               \in Surjection(CohortDomain, Batches(CohortDomain))
      BY DEF Surjection, Batches
    <3>5b. IsFiniteSet(Batches(CohortDomain))
      BY <3>5ba, <3>5bb, FS_Surjection
    <3>5c. IsFiniteSet(Work)
      BY <3>5a, <3>5b, FS_Union DEF Work
    <3>5d. s.prepareBorrow \subseteq Work
      BY SafetyTypeOK DEF TypeOK, PreparationMapTypes
    <3>5e. IsFiniteSet(s.prepareBorrow)
      BY <3>5c, <3>5d, FS_Subset
    <3>5f. Cardinality(s'.prepareBorrow) = Cardinality(s.prepareBorrow) + 1
      BY <2>0g, <2>0k, <3>5e, FS_AddElement
    <3>5g. Cardinality(s.prepareBorrow) \in Nat /\ PrepareCapacity \in Nat
      BY <3>5e, FS_CardinalityType DEF ConstantsOK
    <3>5. Cardinality(s'.prepareBorrow) <= PrepareCapacity
      BY ONLY <2>0h, <3>5f, <3>5g
    <3>6a. UsedBytes' \subseteq ByteDomain
      BY <2>1 DEF TypeOK, PreparationMapTypes, UsedBytes, Resources
    <3>6b. IsFiniteSet(ByteDomain)
      BY DEF ConstantsOK
    <3>6. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
      BY ONLY <3>6a, <3>6b, FS_Subset
    <3>7. \A left, right \in Resources : left # right =>
             s'.buffers[left] \cap s'.buffers[right] = {}
      <4> SUFFICES ASSUME NEW left \in Resources,
                           NEW right \in Resources,
                           left # right
                   PROVE s'.buffers[left] \cap s'.buffers[right] = {}
        OBVIOUS
      <4>1. CASE left = Fragment(t)
        <5>1. /\ s'.buffers[left] = bytes
               /\ s'.buffers[right] = s.buffers[right]
          BY <2>0o, <4>1
        <5>2. s.buffers[right] \subseteq UsedBytes
          BY DEF UsedBytes
        <5> QED BY <2>0p, <5>1, <5>2
      <4>2. CASE right = Fragment(t)
        <5>1. /\ s'.buffers[left] = s.buffers[left]
               /\ s'.buffers[right] = bytes
          BY <2>0o, <4>2
        <5>2. s.buffers[left] \subseteq UsedBytes
          BY DEF UsedBytes
        <5> QED BY <2>0p, <5>1, <5>2
      <4>3. CASE left # Fragment(t) /\ right # Fragment(t)
        BY <2>0o, <3>0, <4>3 DEF ResourceBounds
      <4> QED BY <4>1, <4>2, <4>3
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>4a, <3>5, <3>6, <3>7
        DEF ResourceBounds
  <2>7. AuthoritySafety'
    <3>0. AuthoritySafety
      BY SafetyAuthority
    <3>1. (CohortsOf(s.authority \cup s.exported) \subseteq
               s.headCalls \ s.headBorrow)'
      BY <2>0d, <2>0n, <3>0 DEF AuthoritySafety
    <3>2. (s.headBorrow \cap s.abandoned = {})'
      BY <2>0c, <2>0d, <3>0 DEF AuthoritySafety
    <3>3. (s.unknownEpisode => s.halted)'
      BY <2>0f, <3>0 DEF AuthoritySafety
    <3>4. (s.exported \subseteq s.delivered)'
      BY <2>0b, <2>0e, <3>0 DEF AuthoritySafety
    <3>4a. (s.delivered \subseteq s.collected)'
      BY <2>0b, <3>0 DEF AuthoritySafety
    <3>4b. (s.authority \cap s.discarded = {})'
      BY <2>0b, <2>0e, <3>0 DEF AuthoritySafety
    <3>5. (s.resolutionWrites = 0)'
      BY <2>0f, <3>0 DEF AuthoritySafety
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>4a, <3>4b, <3>5 DEF AuthoritySafety
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1>3. CASE \E t \in MemberDomain, success \in BOOLEAN : JoinTxnPrepare(t, success)
  <2>0. PICK t \in MemberDomain, success \in BOOLEAN : JoinTxnPrepare(t, success)
    BY <1>3
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0aa. s' = JoinTxnPrepareState(t, KeepTxnPrepare(t, success))
    BY <2>0 DEF JoinTxnPrepare
  <2>0i. Fragment(t) \in s.prepareBorrow /\ success \in BOOLEAN
    BY <2>0 DEF JoinTxnPrepare
  <2>0ia. KeepTxnPrepare(t, success) \in BOOLEAN
    BY <2>0i DEF KeepTxnPrepare
  <2>0b. /\ DOMAIN s' = StateFields
           /\ s'.prepareBorrow = s.prepareBorrow \ {Fragment(t)}
           /\ s'.prepared = (IF KeepTxnPrepare(t, success)
                               THEN s.prepared \cup {t} ELSE s.prepared)
           /\ s'.pending = (IF KeepTxnPrepare(t, success)
                              THEN s.pending ELSE s.pending \ {t})
           /\ s'.rejected = (IF KeepTxnPrepare(t, success)
                               THEN s.rejected ELSE s.rejected \cup {t})
           /\ s'.buffers = Release(s.buffers, ReleasedTxn(t, KeepTxnPrepare(t, success)))
    BY <2>0aa, <2>0a, <2>0ia, JoinTxnPrepareStateProjection
  <2>0c. /\ s'.admitted = s.admitted
           /\ s'.collected = s.collected
           /\ s'.delivered = s.delivered
           /\ s'.discarded = s.discarded
    BY <2>0aa, <2>0a, <2>0ia, JoinTxnPrepareStatePreservesFixedMemberFields
  <2>0d. /\ s'.groups = s.groups
           /\ s'.prepareCalls = s.prepareCalls
    BY <2>0aa, <2>0a, <2>0ia, JoinTxnPrepareStatePreservesPreparationFields
  <2>0e. /\ s'.sealed = s.sealed
           /\ s'.ready = s.ready
           /\ s'.issued = s.issued
           /\ s'.stored = s.stored
           /\ s'.published = s.published
           /\ s'.retired = s.retired
           /\ s'.excluded = s.excluded
           /\ s'.abandoned = s.abandoned
           /\ s'.prepareFailed = s.prepareFailed
           /\ s'.batchFailed = s.batchFailed
           /\ s'.validated = s.validated
           /\ s'.projection = s.projection
    BY <2>0aa, <2>0a, <2>0ia, JoinTxnPrepareStatePreservesCohortFields
  <2>0f. /\ s'.batchCalls = s.batchCalls
           /\ s'.headCalls = s.headCalls
           /\ s'.batchBorrow = s.batchBorrow
           /\ s'.headBorrow = s.headBorrow
           /\ s'.owned = s.owned
           /\ s'.accepted = s.accepted
           /\ s'.unknown = s.unknown
           /\ s'.absent = s.absent
    BY <2>0aa, <2>0a, <2>0ia, JoinTxnPrepareStatePreservesPublicationFields
  <2>0g. /\ s'.authority = s.authority
           /\ s'.exported = s.exported
           /\ s'.ack = s.ack
    BY <2>0aa, <2>0a, <2>0ia, JoinTxnPrepareStatePreservesAuthorityFields
  <2>0h. /\ s'.closing = s.closing
           /\ s'.online = s.online
           /\ s'.fenced = s.fenced
           /\ s'.halted = s.halted
           /\ s'.unknownEpisode = s.unknownEpisode
           /\ s'.resolutionWrites = s.resolutionWrites
    BY <2>0aa, <2>0a, <2>0ia, JoinTxnPrepareStatePreservesLifecycleFields
  <2>0j. /\ Fragment(t) \in s.prepareCalls \cap Allocated
           /\ Input(t) \in Allocated
           /\ t \in s.admitted \ BoundMembers
    BY <2>0i, SafetyPreparationOwnership DEF PreparationOwnership
  <2>0k. t \notin s.prepared
    BY <2>0i, SafetyPreparationOwnership DEF PreparationOwnership
  <2>0l. BoundMembers' = BoundMembers
    BY <2>0d, <2>0e DEF BoundMembers, Members
  <2>0m. /\ CohortsOf(s.ack)' = CohortsOf(s.ack)
           /\ CohortsOf(s.authority \cup s.exported)' =
                CohortsOf(s.authority \cup s.exported)
    BY <2>0d, <2>0e, <2>0g DEF CohortsOf, Members
  <2>0n. Allocated' = Allocated \ ReleasedTxn(t, KeepTxnPrepare(t, success))
    <3>1. Allocated' \subseteq Allocated \ ReleasedTxn(t, KeepTxnPrepare(t, success))
      <4> SUFFICES ASSUME NEW r \in Allocated'
                   PROVE r \in Allocated \ ReleasedTxn(t, KeepTxnPrepare(t, success))
        OBVIOUS
      <4>1. /\ r \in Resources
             /\ s'.buffers[r] # {}
        BY DEF Allocated
      <4>2. /\ r \notin ReleasedTxn(t, KeepTxnPrepare(t, success))
             /\ s'.buffers[r] = s.buffers[r]
        BY <2>0b, <4>1 DEF Release
      <4> QED BY <4>1, <4>2 DEF Allocated
    <3>2. Allocated \ ReleasedTxn(t, KeepTxnPrepare(t, success)) \subseteq Allocated'
      <4> SUFFICES ASSUME NEW r \in
                             Allocated \ ReleasedTxn(t, KeepTxnPrepare(t, success))
                   PROVE r \in Allocated'
        OBVIOUS
      <4>1. /\ r \in Resources
             /\ s.buffers[r] # {}
             /\ r \notin ReleasedTxn(t, KeepTxnPrepare(t, success))
        BY DEF Allocated
      <4>2. s'.buffers[r] = s.buffers[r]
        BY <2>0b, <4>1 DEF Release
      <4> QED BY <4>1, <4>2 DEF Allocated
    <3> QED BY <3>1, <3>2
  <2>0o. UsedBytes' \subseteq UsedBytes
    <3> SUFFICES ASSUME NEW byte \in UsedBytes'
                 PROVE byte \in UsedBytes
      OBVIOUS
    <3>1. PICK r \in Resources : byte \in s'.buffers[r]
      BY DEF UsedBytes
    <3>2. /\ r \notin ReleasedTxn(t, KeepTxnPrepare(t, success))
           /\ s'.buffers[r] = s.buffers[r]
      BY <2>0b, <3>1 DEF Release
    <3> QED BY <3>1, <3>2 DEF UsedBytes
  <2>0p. LiveMembers' = LiveMembers
    BY <2>0c DEF LiveMembers
  <2>0q. s.online
    BY <2>0i, SafetyOwnership DEF Ownership
  <2>0r. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \cap
             ReleasedTxn(t, KeepTxnPrepare(t, success)) = {}
    BY DEF ReleasedTxn, Batches, Inputs, Fragments, Batch, Input, Fragment
  <2>0s. s'.prepareBorrow \cap ReleasedTxn(t, KeepTxnPrepare(t, success)) = {}
    BY <2>0b, SafetyTypeOK DEF TypeOK, PreparationMapTypes, ReleasedTxn,
       Work, Fragments, Batches, Input, Fragment, Batch
  <2>0t. \A r \in Resources :
           s'.buffers[r] = IF r \in ReleasedTxn(t, KeepTxnPrepare(t, success))
                            THEN {} ELSE s.buffers[r]
    BY <2>0b DEF Release
  <2>1. TypeOK'
    <3>0. TypeOK
      BY SafetyTypeOK
    <3>1. StateShape'
      BY ONLY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY <2>0b, <2>0c, <2>0ia, <3>0, FS_RemoveElement, FS_AddElement
          DEF TypeOK, MemberStateTypes
    <3>3. PreparationMapTypes'
      <4>1. s'.groups \in [CohortDomain -> SUBSET MemberDomain]
        BY <2>0d, <3>0 DEF TypeOK, PreparationMapTypes
      <4>2. s'.buffers \in [Resources -> SUBSET ByteDomain]
        BY <2>0b, <3>0 DEF TypeOK, PreparationMapTypes, Release
      <4>3. s'.prepareCalls \subseteq Work /\ s'.prepareBorrow \subseteq Work
        BY <2>0b, <2>0d, <3>0 DEF TypeOK, PreparationMapTypes
      <4> QED BY <4>1, <4>2, <4>3 DEF PreparationMapTypes
    <3>4. CohortStateTypes'
      BY <2>0e, <3>0 DEF TypeOK, CohortStateTypes
    <3>5. PublicationStateTypes'
      BY <2>0f, <3>0 DEF TypeOK, PublicationStateTypes
    <3>6. AuthorityStateTypes'
      BY <2>0g, <3>0 DEF TypeOK, AuthorityStateTypes
    <3>7. LifecycleStateTypes'
      BY <2>0h, <3>0 DEF TypeOK, LifecycleStateTypes
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    BY <2>0b, <2>0c, <2>0d, <2>0e, <2>0f, <2>0g, <2>0i, <2>0ia, <2>0j,
       <2>0k, <2>0l, SafetyMembership
       DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
       AuthorityMembership, TerminalMembership, CohortsOf, Members, Batches
  <2>3. PublicationSafety'
    BY <2>0d, <2>0e, <2>0f, <2>0g, <2>0m, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
       PublicationPredecessorOrder, PublicationAcknowledgement
  <2>4. Ownership'
    <3>0. Ownership
      BY SafetyOwnership
    <3>1. (s.owned \subseteq s.issued)'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>2. (Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated)'
      BY <2>0f, <2>0m, <2>0n, <2>0r, <3>0 DEF Ownership
    <3>3. (s.ready \subseteq
             (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned))'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>4. (s.batchBorrow \cup s.headBorrow \subseteq s.owned)'
      BY <2>0f, <3>0 DEF Ownership
    <3>5. (s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls)'
      BY <2>0f, <3>0 DEF Ownership
    <3>6. (s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {})'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>7. (s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow)'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>8. (s.unknown \subseteq
             (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted))'
      BY <2>0f, <3>0 DEF Ownership
    <3>9. (s.absent \subseteq s.headCalls \ s.headBorrow)'
      BY <2>0f, <3>0 DEF Ownership
    <3>9a. (s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls))'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>9ab. (Batches(s.prepareFailed) \subseteq s.prepareCalls \ s.prepareBorrow)'
      BY <2>0b, <2>0d, <2>0e, <3>0 DEF Ownership, Batches
    <3>9aa. (s.batchFailed \subseteq
          (s.owned \cap s.batchCalls) \ (s.batchBorrow \cup s.stored \cup s.headCalls))'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>9b. (s.projection \subseteq (s.owned \cap s.validated) \ s.abandoned)'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>9c. (s.headBorrow \cup s.accepted \subseteq s.projection)'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>9d. ((s.unknown \cup s.absent) \cap s.projection = {})'
      BY <2>0e, <2>0f, <3>0 DEF Ownership
    <3>10. (s.headBorrow # {} => s.unknown = {})'
      BY <2>0f, <3>0 DEF Ownership
    <3>11. (~s.online =>
              s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
              s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected)'
      BY <2>0q, <2>0h
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7, <3>8, <3>9,
        <3>9a, <3>9ab, <3>9aa, <3>9b, <3>9c, <3>9d, <3>10, <3>11 DEF Ownership
  <2>5. PreparationOwnership'
    <3>0. PreparationOwnership
      BY SafetyPreparationOwnership
    <3>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
      BY <2>0b, <2>0d, <2>0n, <2>0s, <3>0 DEF PreparationOwnership
    <3>2. (\A u \in MemberDomain :
             Fragment(u) \in s.prepareBorrow =>
               Input(u) \in Allocated /\ u \in s.admitted \ BoundMembers)'
      BY <2>0b, <2>0c, <2>0j, <2>0l, <2>0n, <3>0
         DEF PreparationOwnership, ReleasedTxn, KeepTxnPrepare,
         Resources, Inputs, Fragments, Input, Fragment
    <3>3. (\A c \in CohortDomain :
             Batch(c) \in s.prepareBorrow =>
               c \in s.owned /\ Fragments(Members(c)) \subseteq Allocated)'
      <4> SUFFICES ASSUME NEW c \in CohortDomain,
                           Batch(c) \in s'.prepareBorrow
                   PROVE c \in s'.owned /\ Fragments(Members(c)') \subseteq Allocated'
        OBVIOUS
      <4>1. Batch(c) \in s.prepareBorrow
        BY <2>0b DEF Batch, Fragment
      <4>2. c \in s.owned /\ Fragments(Members(c)) \subseteq Allocated
        BY <3>0, <4>1 DEF PreparationOwnership
      <4>3. c \in s.issued
        BY <4>2, SafetyOwnership DEF Ownership
      <4>4. t \notin Members(c)
        BY <2>0j, <4>3 DEF BoundMembers, Members
      <4>5. Fragments(Members(c)) \cap ReleasedTxn(t, KeepTxnPrepare(t, success)) = {}
        BY <4>4 DEF ReleasedTxn, Fragments, Input, Fragment
      <4>6. Fragments(Members(c)) \subseteq Allocated'
        BY <2>0n, <4>2, <4>5
      <4> QED BY <2>0d, <2>0f, <4>2, <4>6 DEF Members
    <3>4. (\A u \in s.prepared :
             Fragment(u) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0b, <2>0d, <2>0i, <2>0j, <2>0k, <3>0
         DEF PreparationOwnership, KeepTxnPrepare, Fragment
    <3>5. (\A u \in s.prepared : Input(u) \notin Allocated)'
      BY <2>0b, <2>0n, <3>0
         DEF PreparationOwnership, ReleasedTxn, KeepTxnPrepare, Input, Fragment
    <3>6. (\A c \in s.sealed : Batch(c) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0b, <2>0d, <2>0e, <3>0 DEF PreparationOwnership, Batch, Fragment
    <3>7. (\A u \in MemberDomain :
             Input(u) \in Allocated => u \in s.pending \/ Fragment(u) \in s.prepareBorrow)'
      BY <2>0b, <2>0n, <3>0
         DEF PreparationOwnership, ReleasedTxn, KeepTxnPrepare, Input, Fragment
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF PreparationOwnership
  <2>6. ResourceBounds'
    <3>0. ResourceBounds
      BY SafetyResourceBounds
    <3>1. Cardinality(LiveMembers') <= QueueCapacity
      BY <2>0p, <3>0 DEF ResourceBounds
    <3>2. Cardinality(s'.owned) <= Capacity
      BY <2>0f, <3>0 DEF ResourceBounds
    <3>3. Cardinality(s'.ready) <= Capacity
      BY <2>0e, <3>0 DEF ResourceBounds
    <3>4. Cardinality(s'.headBorrow) <= 1
      BY <2>0f, <3>0 DEF ResourceBounds
    <3>4a. Cardinality(s'.projection) <= 1
      BY <2>0e, <3>0 DEF ResourceBounds
    <3>5aa. IsFiniteSet(MemberDomain)
      BY DEF ConstantsOK
    <3>5ab. [u \in MemberDomain |-> Fragment(u)]
               \in Surjection(MemberDomain, Fragments(MemberDomain))
      BY DEF Surjection, Fragments
    <3>5a. IsFiniteSet(Fragments(MemberDomain))
      BY <3>5aa, <3>5ab, FS_Surjection
    <3>5ba. IsFiniteSet(CohortDomain)
      BY DEF ConstantsOK
    <3>5bb. [c \in CohortDomain |-> Batch(c)]
               \in Surjection(CohortDomain, Batches(CohortDomain))
      BY DEF Surjection, Batches
    <3>5b. IsFiniteSet(Batches(CohortDomain))
      BY <3>5ba, <3>5bb, FS_Surjection
    <3>5c. IsFiniteSet(Work)
      BY <3>5a, <3>5b, FS_Union DEF Work
    <3>5d. s.prepareBorrow \subseteq Work /\ s'.prepareBorrow \subseteq s.prepareBorrow
      BY <2>0b, SafetyTypeOK DEF TypeOK, PreparationMapTypes
    <3>5e. IsFiniteSet(s.prepareBorrow)
      BY <3>5c, <3>5d, FS_Subset
    <3>5f. /\ IsFiniteSet(s'.prepareBorrow)
             /\ Cardinality(s'.prepareBorrow) <= Cardinality(s.prepareBorrow)
      BY <3>5d, <3>5e, FS_Subset
    <3>5g. Cardinality(s.prepareBorrow) <= PrepareCapacity
      BY <3>0 DEF ResourceBounds
    <3>5h. /\ Cardinality(s'.prepareBorrow) \in Nat
             /\ Cardinality(s.prepareBorrow) \in Nat
             /\ PrepareCapacity \in Nat
      BY <3>5e, <3>5f, FS_CardinalityType DEF ConstantsOK
    <3>5. Cardinality(s'.prepareBorrow) <= PrepareCapacity
      BY ONLY <3>5f, <3>5g, <3>5h
    <3>6a. UsedBytes' \subseteq ByteDomain
      BY <2>1 DEF TypeOK, PreparationMapTypes, UsedBytes, Resources
    <3>6b. IsFiniteSet(ByteDomain)
      BY DEF ConstantsOK
    <3>6. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
      BY <3>6a, <3>6b, FS_Subset
    <3>7. \A left, right \in Resources : left # right =>
             s'.buffers[left] \cap s'.buffers[right] = {}
      BY <2>0t, <3>0 DEF ResourceBounds
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>4a, <3>5, <3>6, <3>7
        DEF ResourceBounds
  <2>7. AuthoritySafety'
    BY <2>0c, <2>0d, <2>0e, <2>0f, <2>0g, <2>0h, <2>0m, SafetyAuthority
       DEF AuthoritySafety
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1> QED BY <1>1, <1>2, <1>3

THEOREM FreezePreserves ==
    ASSUME NEW c \in CohortDomain,
        NEW ts \in SUBSET MemberDomain,
        NEW bytes \in SUBSET ByteDomain,
        ConstantsOK,
        Safety,
        Freeze(c, ts, bytes)
    PROVE Safety'
<1>0. s' = FreezeState(c, ts, bytes)
  BY DEF Freeze
<1>0a. StateShape /\ PreparationMapTypes /\ CohortStateTypes
  BY SafetyTypeOK DEF TypeOK
<1>0b. FreezeFieldsPresent
  BY StateShapeProvidesFreezeFields, <1>0a DEF StateShape
<1>0c. /\ (s').pending = s.pending \ ts
         /\ (s').groups = [s.groups EXCEPT ![c] = ts]
         /\ (s').issued = s.issued \cup {c}
         /\ (s').owned = s.owned \cup {c}
         /\ (s').buffers = [s.buffers EXCEPT ![Batch(c)] = bytes]
  BY FreezeStateChangedValues, <1>0, <1>0b
<1>0d. /\ (s').admitted = s.admitted
         /\ (s').collected = s.collected
         /\ (s').delivered = s.delivered
         /\ (s').discarded = s.discarded
         /\ (s').prepared = s.prepared
         /\ (s').rejected = s.rejected
  BY FreezeStatePreservesMemberFields, <1>0, <1>0a DEF StateShape
<1>0e. /\ (s').prepareCalls = s.prepareCalls
         /\ (s').prepareBorrow = s.prepareBorrow
  BY FreezeStatePreservesPreparationFields, <1>0, <1>0a DEF StateShape
<1>0f. /\ (s').sealed = s.sealed
         /\ (s').ready = s.ready
         /\ (s').stored = s.stored
         /\ (s').published = s.published
         /\ (s').retired = s.retired
         /\ (s').excluded = s.excluded
         /\ (s').abandoned = s.abandoned
         /\ (s').prepareFailed = s.prepareFailed
         /\ (s').batchFailed = s.batchFailed
         /\ (s').validated = s.validated
         /\ (s').projection = s.projection
  BY FreezeStatePreservesCohortFields, <1>0, <1>0a DEF StateShape
<1>0g. /\ (s').batchCalls = s.batchCalls
         /\ (s').headCalls = s.headCalls
         /\ (s').batchBorrow = s.batchBorrow
         /\ (s').headBorrow = s.headBorrow
         /\ (s').accepted = s.accepted
         /\ (s').unknown = s.unknown
         /\ (s').absent = s.absent
  BY FreezeStatePreservesPublicationFields, <1>0, <1>0a DEF StateShape
<1>0h. /\ (s').authority = s.authority
         /\ (s').exported = s.exported
         /\ (s').ack = s.ack
  BY FreezeStatePreservesAuthorityFields, <1>0, <1>0a DEF StateShape
<1>0i. /\ (s').closing = s.closing
         /\ (s').online = s.online
         /\ (s').halted = s.halted
         /\ (s').fenced = s.fenced
         /\ (s').unknownEpisode = s.unknownEpisode
         /\ (s').resolutionWrites = s.resolutionWrites
  BY FreezeStatePreservesLifecycleFields, <1>0, <1>0a DEF StateShape
<1>0j. \A d \in CohortDomain : s'.groups[d] = IF d = c THEN ts ELSE s.groups[d]
  BY FreezeStateGroupAt, <1>0, <1>0a, <1>0b DEF PreparationMapTypes
<1>0k. BoundMembers' = BoundMembers \cup ts
  BY FreezeBoundMembersValue, <1>0a, SafetyMembership DEF MembershipSafety
<1>0l. CohortsOf(s.ack)' \subseteq CohortsOf(s.ack)
  <2> SUFFICES ASSUME NEW d \in CohortsOf(s.ack)'
               PROVE d \in CohortsOf(s.ack)
    OBVIOUS
  <2>1. /\ d \in s'.issued
         /\ s'.groups[d] \cap s.ack # {}
    BY <1>0h DEF CohortsOf, Members
  <2>2. d \in CohortDomain
    BY <1>0c, <2>1, SafetyTypeOK DEF TypeOK, CohortStateTypes
  <2>3. ts \cap s.ack = {}
    BY SafetyMembership, FS_Subset
        DEF MembershipSafety, AuthorityMembership, BoundMembership, Freeze
  <2>4. d # c
    BY <1>0j, <2>1, <2>2, <2>3
  <2>5. /\ d \in s.issued
         /\ s'.groups[d] = s.groups[d]
    BY <1>0c, <1>0j, <2>1, <2>2, <2>4
  <2> QED BY <2>1, <2>5 DEF CohortsOf, Members
<1>0m. CohortsOf(s.authority \cup s.exported)' \subseteq
         CohortsOf(s.authority \cup s.exported)
  <2> SUFFICES ASSUME NEW d \in CohortsOf(s.authority \cup s.exported)'
               PROVE d \in CohortsOf(s.authority \cup s.exported)
    OBVIOUS
  <2>1. /\ d \in s'.issued
         /\ s'.groups[d] \cap (s.authority \cup s.exported) # {}
    BY <1>0h DEF CohortsOf, Members
  <2>2. d \in CohortDomain
    BY <1>0c, <2>1, SafetyTypeOK DEF TypeOK, CohortStateTypes
  <2>3. ts \cap (s.authority \cup s.exported) = {}
    BY SafetyMembership, FS_Subset
        DEF MembershipSafety, AuthorityMembership, BoundMembership, Freeze
  <2>4. d # c
    BY <1>0j, <2>1, <2>2, <2>3
  <2>5. /\ d \in s.issued
         /\ s'.groups[d] = s.groups[d]
    BY <1>0c, <1>0j, <2>1, <2>2, <2>4
  <2> QED BY <2>1, <2>5 DEF CohortsOf, Members
<1>0n. \A r \in Resources :
         s'.buffers[r] = IF r = Batch(c) THEN bytes ELSE s.buffers[r]
  BY <1>0c, SafetyTypeOK DEF TypeOK, PreparationMapTypes
<1>0oa. bytes # {}
  BY DEF Freeze, Fresh
<1>0o. Batch(c) \in Allocated'
  BY <1>0n, <1>0oa DEF Allocated, Resources, Batches, Batch
<1>0p. Allocated \subseteq Allocated'
  <2> SUFFICES ASSUME NEW r \in Allocated
               PROVE r \in Allocated'
    OBVIOUS
  <2>1. r \in Resources /\ s.buffers[r] # {}
    BY DEF Allocated
  <2>2. CASE r = Batch(c)
    BY <1>0o, <2>2
  <2>3. CASE r # Batch(c)
    BY <1>0n, <2>1, <2>3 DEF Allocated
  <2> QED BY <2>2, <2>3
<1>0q. \A t \in MemberDomain :
         (Input(t) \in Allocated' <=> Input(t) \in Allocated)
  <2> SUFFICES ASSUME NEW t \in MemberDomain
               PROVE Input(t) \in Allocated' <=> Input(t) \in Allocated
    OBVIOUS
  <2>1. Input(t) \in Resources /\ Input(t) # Batch(c)
    BY DEF Resources, Inputs, Batches, Input, Batch
  <2> QED BY <1>0n, <2>1 DEF Allocated
<1>1. TypeOK'
  <2>0. s' = FreezeState(c, ts, bytes)
    BY DEF Freeze
  <2>13. StateShape
    BY SafetyTypeOK DEF TypeOK
  <2>14. FreezeFieldsPresent
    BY StateShapeProvidesFreezeFields, <2>13 DEF StateShape
  <2>15. /\ FreezeState(c, ts, bytes).pending = s.pending \ ts
           /\ FreezeState(c, ts, bytes).groups = [s.groups EXCEPT ![c] = ts]
           /\ FreezeState(c, ts, bytes).issued = s.issued \cup {c}
           /\ FreezeState(c, ts, bytes).owned = s.owned \cup {c}
           /\ FreezeState(c, ts, bytes).buffers = [s.buffers EXCEPT ![Batch(c)] = bytes]
    BY FreezeStateChangedValues, <2>14
  <2>16. StateShape'
    BY FreezeStatePreservesDomain, <2>0, <2>13 DEF StateShape
  <2>1. MemberStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>2. MemberStateTypes'
    <3>0. /\ (s').admitted = s.admitted
           /\ (s').collected = s.collected
           /\ (s').delivered = s.delivered
           /\ (s').discarded = s.discarded
           /\ (s').prepared = s.prepared
           /\ (s').rejected = s.rejected
      BY FreezeStatePreservesMemberFields, <2>0, <2>13 DEF StateShape
    <3>0e. (s').pending = s.pending \ ts
      BY <2>0, <2>15
    <3>1. (s').admitted \subseteq MemberDomain
      BY <2>1, <3>0 DEF MemberStateTypes
    <3>2. (s').pending \subseteq MemberDomain
      BY <2>1, <3>0e, FS_Subset DEF MemberStateTypes
    <3>3. (s').collected \subseteq (s').admitted
      BY <2>1, <3>0 DEF MemberStateTypes
    <3>3a. (s').delivered \subseteq (s').collected
      BY <2>1, <3>0 DEF MemberStateTypes
    <3>3b. (s').discarded \subseteq (s').collected
      BY <2>1, <3>0 DEF MemberStateTypes
    <3>4. (s').prepared \subseteq MemberDomain
      BY <2>1, <3>0 DEF MemberStateTypes
    <3>5. (s').rejected \subseteq MemberDomain
      BY <2>1, <3>0 DEF MemberStateTypes
    <3> QED BY <3>1, <3>2, <3>3, <3>3a, <3>3b, <3>4, <3>5 DEF MemberStateTypes
  <2>3. PreparationMapTypes
    BY SafetyTypeOK DEF TypeOK
  <2>4. PreparationMapTypes'
    <3>0. /\ (s').prepareCalls = s.prepareCalls
           /\ (s').prepareBorrow = s.prepareBorrow
      BY FreezeStatePreservesPreparationFields, <2>0, <2>13 DEF StateShape
    <3>1. (s').groups = [s.groups EXCEPT ![c] = ts]
      BY <2>0, <2>15
    <3>2. (s').groups \in [CohortDomain -> SUBSET MemberDomain]
      BY <2>3, <3>1 DEF Freeze, PreparationMapTypes
    <3>3. (s').buffers = [s.buffers EXCEPT ![Batch(c)] = bytes]
      BY <2>0, <2>15
    <3>4. Batch(c) \in Resources
      BY DEF Resources, Batches, Batch
    <3>5. (s').buffers \in [Resources -> SUBSET ByteDomain]
      BY <2>3, <3>3, <3>4 DEF PreparationMapTypes
    <3> QED BY <2>3, <3>0, <3>2, <3>5 DEF PreparationMapTypes
  <2>5. CohortStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>6. CohortStateTypes'
    <3>0. /\ (s').sealed = s.sealed
           /\ (s').ready = s.ready
           /\ (s').stored = s.stored
           /\ (s').published = s.published
           /\ (s').retired = s.retired
           /\ (s').excluded = s.excluded
           /\ (s').abandoned = s.abandoned
           /\ (s').prepareFailed = s.prepareFailed
           /\ (s').batchFailed = s.batchFailed
           /\ (s').validated = s.validated
           /\ (s').projection = s.projection
      BY FreezeStatePreservesCohortFields, <2>0, <2>13 DEF StateShape
    <3>3. (s').issued = s.issued \cup {c}
      BY <2>0, <2>15
    <3> QED BY <2>5, <3>0, <3>3,
        FS_AddElement DEF Freeze, CohortStateTypes
  <2>7. PublicationStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>8. PublicationStateTypes'
    <3>0. /\ (s').batchCalls = s.batchCalls
           /\ (s').headCalls = s.headCalls
           /\ (s').batchBorrow = s.batchBorrow
           /\ (s').headBorrow = s.headBorrow
           /\ (s').accepted = s.accepted
           /\ (s').unknown = s.unknown
           /\ (s').absent = s.absent
      BY FreezeStatePreservesPublicationFields, <2>0, <2>13 DEF StateShape
    <3>5. (s').owned = s.owned \cup {c}
      BY <2>0, <2>15
    <3> QED BY <2>7, <3>0, <3>5,
        FS_AddElement DEF Freeze, PublicationStateTypes
  <2>9. AuthorityStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>10. AuthorityStateTypes'
    <3>0. /\ (s').authority = s.authority
           /\ (s').exported = s.exported
           /\ (s').ack = s.ack
      BY FreezeStatePreservesAuthorityFields, <2>0, <2>13 DEF StateShape
    <3> QED BY <2>9, <3>0 DEF AuthorityStateTypes
  <2>11. LifecycleStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>12. LifecycleStateTypes'
    <3>0. /\ (s').closing = s.closing
           /\ (s').online = s.online
           /\ (s').halted = s.halted
           /\ (s').fenced = s.fenced
           /\ (s').unknownEpisode = s.unknownEpisode
           /\ (s').resolutionWrites = s.resolutionWrites
      BY FreezeStatePreservesLifecycleFields, <2>0, <2>13 DEF StateShape
    <3> QED BY <2>11, <3>0 DEF LifecycleStateTypes
  <2> QED BY <2>2, <2>4, <2>6, <2>8, <2>10, <2>12, <2>16 DEF TypeOK
<1>2. MembershipSafety'
  <2>0. s' = FreezeState(c, ts, bytes)
    BY DEF Freeze
  <2>0a. StateShape /\ PreparationMapTypes /\ CohortStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>0b. FreezeFieldsPresent
    BY StateShapeProvidesFreezeFields, <2>0a DEF StateShape
  <2>0c. /\ (s').pending = s.pending \ ts
           /\ (s').groups = [s.groups EXCEPT ![c] = ts]
           /\ (s').issued = s.issued \cup {c}
           /\ (s').owned = s.owned \cup {c}
           /\ (s').buffers = [s.buffers EXCEPT ![Batch(c)] = bytes]
    BY FreezeStateChangedValues, <2>0, <2>0b
  <2>0d. /\ (s').admitted = s.admitted
           /\ (s').collected = s.collected
           /\ (s').delivered = s.delivered
           /\ (s').discarded = s.discarded
           /\ (s').prepared = s.prepared
           /\ (s').rejected = s.rejected
    BY FreezeStatePreservesMemberFields, <2>0, <2>0a DEF StateShape
  <2>0e. /\ (s').authority = s.authority
           /\ (s').exported = s.exported
           /\ (s').ack = s.ack
    BY FreezeStatePreservesAuthorityFields, <2>0, <2>0a DEF StateShape
  <2>0f. \A d \in CohortDomain : s'.groups[d] = IF d = c THEN ts ELSE s.groups[d]
    BY FreezeStateGroupAt, <2>0, <2>0a, <2>0b DEF PreparationMapTypes
  <2>1. AdmissionMembership'
    <3>1. StateShape /\ AdmissionMembership
      BY SafetyTypeOK, SafetyMembership DEF TypeOK, MembershipSafety
    <3>3. (s').admitted = s.admitted
      BY <2>0d
    <3>4. (s').prepared = s.prepared
      BY <2>0d
    <3>5. (s').rejected = s.rejected
      BY <2>0d
    <3>6. (s').pending = s.pending \ ts
      BY <2>0c
    <3> QED BY <3>1, <3>3, <3>4, <3>5, <3>6, FS_Subset DEF AdmissionMembership
  <2>2. BoundMembership'
    <3>1. StateShape /\ PreparationMapTypes /\ CohortStateTypes /\ BoundMembership /\
           GroupPartition
      BY SafetyTypeOK, SafetyMembership DEF TypeOK, MembershipSafety
    <3>3. (s').prepared = s.prepared
      BY <2>0d
    <3>4. (s').pending = s.pending \ ts
      BY <2>0c
    <3>5. BoundMembers' = BoundMembers \cup ts
      BY FreezeBoundMembersValue, <3>1
    <3>6. BoundMembers' \subseteq (s').prepared
      BY <3>1, <3>3, <3>5, FS_Subset DEF Freeze, BoundMembership
    <3>7. (s').pending \cap BoundMembers' = {}
      BY <3>1, <3>4, <3>5 DEF Freeze, BoundMembership
    <3> QED BY <3>6, <3>7 DEF BoundMembership
  <2>3. GroupPartition'
    <3>1. StateShape /\ PreparationMapTypes /\ CohortStateTypes /\ GroupPartition /\
           BoundMembership
      BY SafetyTypeOK, SafetyMembership DEF TypeOK, MembershipSafety
    <3>2. /\ s'.groups = [s.groups EXCEPT ![c] = ts]
           /\ s'.issued = s.issued \cup {c}
      BY <2>0c
    <3>3. \A d \in CohortDomain \ {c} : ts \cap s.groups[d] = {}
      <4> SUFFICES ASSUME NEW d \in CohortDomain \ {c}
                   PROVE ts \cap s.groups[d] = {}
        OBVIOUS
      <4>1. CASE d \in s.issued
        <5>1. s.groups[d] \subseteq BoundMembers
          BY <4>1 DEF BoundMembers, Members
        <5> QED BY <3>1, <5>1 DEF Freeze, BoundMembership
      <4>2. CASE d \notin s.issued
        BY <3>1, <4>2 DEF GroupPartition, Members
      <4> QED BY <4>1, <4>2
    <3>4. \A d \in CohortDomain : (d \in s'.issued <=> s'.groups[d] # {})
      <4> SUFFICES ASSUME NEW d \in CohortDomain
                   PROVE d \in s'.issued <=> s'.groups[d] # {}
        OBVIOUS
      <4>1. CASE d = c
        BY <2>0f, <3>2, <4>1 DEF Freeze
      <4>2. CASE d # c
        <5>1. s'.groups[d] = s.groups[d]
          BY <2>0f, <4>2
        <5> QED BY <3>1, <3>2, <4>2, <5>1 DEF GroupPartition, Members
      <4> QED BY <4>1, <4>2
    <3>5. \A d, e \in CohortDomain : d # e => s'.groups[d] \cap s'.groups[e] = {}
      <4> SUFFICES ASSUME NEW d \in CohortDomain,
                          NEW e \in CohortDomain,
                          d # e
                   PROVE s'.groups[d] \cap s'.groups[e] = {}
        OBVIOUS
      <4>1. CASE d = c
        BY <2>0f, <3>2, <3>3, <4>1
      <4>2. CASE e = c
        BY <2>0f, <3>2, <3>3, <4>2
      <4>3. CASE d # c /\ e # c
        BY <2>0f, <3>1, <3>2, <4>3 DEF GroupPartition, Members
      <4> QED BY <4>1, <4>2, <4>3
    <3>6. \A d \in s'.issued : Cardinality(s'.groups[d]) <= MemberCapacity
      <4> SUFFICES ASSUME NEW d \in s'.issued
                   PROVE Cardinality(s'.groups[d]) <= MemberCapacity
        OBVIOUS
      <4>1. CASE d = c
        BY <2>0f, <3>2, <4>1 DEF Freeze
      <4>2. CASE d # c
        <5>1. d \in CohortDomain /\ d \in s.issued
          BY <3>1, <3>2, <4>2 DEF CohortStateTypes
        <5>2. s'.groups[d] = s.groups[d]
          BY <2>0f, <4>2, <5>1
        <5>3. Cardinality(s.groups[d]) <= MemberCapacity
          BY <3>1, <5>1 DEF GroupPartition, Members
        <5> QED BY <5>2, <5>3
      <4> QED BY <4>1, <4>2
    <3> QED BY <3>4, <3>5, <3>6 DEF GroupPartition, Members
  <2>4. AuthorityMembership'
    <3>1. StateShape /\ PreparationMapTypes /\ CohortStateTypes /\ GroupPartition /\
           AuthorityMembership /\ TerminalMembership
      BY SafetyTypeOK, SafetyMembership DEF TypeOK, MembershipSafety
    <3>3. /\ (s').authority = s.authority
           /\ (s').exported = s.exported
           /\ (s').ack = s.ack
           /\ (s').rejected = s.rejected
      BY <2>0d, <2>0e
    <3>4. BoundMembers' = BoundMembers \cup ts
      BY FreezeBoundMembersValue, <3>1
    <3>5. (s').authority \cup (s').exported \cup (s').ack \subseteq BoundMembers'
      BY <3>1, <3>3, <3>4, FS_Subset DEF AuthorityMembership
    <3>6. (s').rejected \cap BoundMembers' = {}
      BY <3>1, <3>3, <3>4 DEF Freeze, AuthorityMembership, TerminalMembership
    <3> QED BY <3>5, <3>6 DEF AuthorityMembership
  <2>5. TerminalMembership'
    <3>1. StateShape /\ TerminalMembership
      BY SafetyTypeOK, SafetyMembership DEF TypeOK, MembershipSafety
    <3>2. (CohortsOf(s.collected))' = CohortsOf(s.collected)
      BY FreezeCollectedCohortsValue, SafetyTypeOK, SafetyMembership
         DEF TypeOK, MembershipSafety
    <3>2a. /\ s'.prepareBorrow = s.prepareBorrow
            /\ s'.batchBorrow = s.batchBorrow
            /\ s'.headBorrow = s.headBorrow
            /\ s'.headCalls = s.headCalls
            /\ s'.excluded = s.excluded
      BY FreezeStatePreservesPreparationFields, FreezeStatePreservesPublicationFields,
         FreezeStatePreservesCohortFields, <2>0, <3>1 DEF TypeOK, StateShape
    <3>3. /\ (s').rejected = s.rejected
           /\ (s').collected = s.collected
           /\ (s').delivered = s.delivered
           /\ (s').discarded = s.discarded
      BY <2>0d
    <3>4. (s').pending = s.pending \ ts
      BY <2>0c
    <3> QED BY <3>1, <3>2, <3>2a, <3>3, <3>4
        DEF TerminalMembership, Batches
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5 DEF MembershipSafety
<1>3. PublicationSafety'
  <2>1. PublicationOrder'
    BY SafetyPublication, <1>0c, <1>0f, <1>0g, FS_Subset
        DEF PublicationSafety, PublicationOrder
  <2>2. c \notin s.excluded
    BY SafetyPublication DEF PublicationSafety, PublicationExclusion, Freeze
  <2>3. PublicationExclusion'
    BY SafetyPublication, <1>0c, <1>0f, <1>0g, <2>2, FS_Subset
        DEF PublicationSafety, PublicationExclusion
  <2>4. PublicationPredecessorOrder'
    BY SafetyPublication, <1>0f, <1>0g
        DEF PublicationSafety, PublicationPredecessorOrder
  <2>5. PublicationAcknowledgement'
    BY SafetyPublication, <1>0f, <1>0h, <1>0l, FS_Subset
        DEF PublicationSafety, PublicationAcknowledgement
  <2> QED BY <2>1, <2>3, <2>4, <2>5 DEF PublicationSafety
<1>4. Ownership'
  <2>1. s'.owned \subseteq s'.issued
    BY SafetyOwnership, <1>0c, FS_Subset DEF Ownership
  <2>2. Batches(s'.owned \cup CohortsOf(s.authority \cup s.exported)') \subseteq
         Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \cup {Batch(c)}
    BY <1>0c, <1>0h, <1>0m, FS_Subset DEF Batches
  <2>3. Batches(s'.owned \cup CohortsOf(s.authority \cup s.exported)') \subseteq Allocated'
    BY SafetyOwnership, <1>0o, <1>0p, <2>2, FS_Subset DEF Ownership
  <2>4. s'.ready \subseteq
         (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
    BY SafetyOwnership, <1>0c, <1>0f, <1>0g, FS_Subset DEF Ownership
  <2>5. s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
    BY SafetyOwnership, <1>0c, <1>0g, FS_Subset DEF Ownership
  <2>6. /\ s'.batchBorrow \subseteq s'.batchCalls
         /\ s'.headBorrow \subseteq s'.headCalls
    BY SafetyOwnership, <1>0g DEF Ownership
  <2>7. /\ s'.batchBorrow \cap s'.stored = {}
         /\ s'.headBorrow \cap s'.published = {}
    BY SafetyOwnership, <1>0f, <1>0g DEF Ownership
  <2>8. s'.accepted \subseteq (s'.owned \cap s'.published) \ s'.headBorrow
    BY SafetyOwnership, <1>0c, <1>0f, <1>0g, FS_Subset DEF Ownership
  <2>9. s'.unknown \subseteq
         (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
    BY SafetyOwnership, <1>0c, <1>0g, FS_Subset DEF Ownership
  <2>10. s'.absent \subseteq s'.headCalls \ s'.headBorrow
    BY SafetyOwnership, <1>0g DEF Ownership
  <2>10a. s'.prepareFailed \subseteq s'.owned \ (s'.sealed \cup s'.batchCalls)
    BY SafetyOwnership, <1>0c, <1>0f, <1>0g DEF Ownership
  <2>10ab. Batches(s'.prepareFailed) \subseteq s'.prepareCalls \ s'.prepareBorrow
    BY SafetyOwnership, <1>0e, <1>0f DEF Ownership, Batches
  <2>10aa. s'.batchFailed \subseteq
          (s'.owned \cap s'.batchCalls) \ (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
    BY SafetyOwnership, <1>0c, <1>0f, <1>0g DEF Ownership
  <2>10b. s'.projection \subseteq (s'.owned \cap s'.validated) \ s'.abandoned
    BY SafetyOwnership, <1>0c, <1>0f, <1>0g DEF Ownership
  <2>10c. s'.headBorrow \cup s'.accepted \subseteq s'.projection
    BY SafetyOwnership, <1>0f, <1>0g DEF Ownership
  <2>10d. (s'.unknown \cup s'.absent) \cap s'.projection = {}
    BY SafetyOwnership, <1>0f, <1>0g DEF Ownership
  <2>11. s'.headBorrow # {} => s'.unknown = {}
    BY SafetyOwnership, <1>0g DEF Ownership
  <2>12. ~s'.online => s'.pending = {} /\ s'.owned = {} /\
           s'.prepareBorrow = {} /\ s'.batchBorrow = {} /\ s'.headBorrow = {} /\
           s'.admitted = s'.collected
    BY <1>0i DEF Freeze
  <2>13. /\ s'.owned \subseteq s'.issued
          /\ Batches(s'.owned \cup CohortsOf(s.authority \cup s.exported)') \subseteq Allocated'
          /\ s'.ready \subseteq
               (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
          /\ s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
          /\ s'.batchBorrow \subseteq s'.batchCalls
          /\ s'.headBorrow \subseteq s'.headCalls
          /\ s'.batchBorrow \cap s'.stored = {}
          /\ s'.headBorrow \cap s'.published = {}
          /\ s'.accepted \subseteq (s'.owned \cap s'.published) \ s'.headBorrow
          /\ s'.unknown \subseteq
               (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
          /\ s'.absent \subseteq s'.headCalls \ s'.headBorrow
          /\ s'.prepareFailed \subseteq s'.owned \ (s'.sealed \cup s'.batchCalls)
          /\ Batches(s'.prepareFailed) \subseteq s'.prepareCalls \ s'.prepareBorrow
          /\ s'.batchFailed \subseteq
               (s'.owned \cap s'.batchCalls) \ (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
          /\ s'.projection \subseteq (s'.owned \cap s'.validated) \ s'.abandoned
          /\ s'.headBorrow \cup s'.accepted \subseteq s'.projection
          /\ (s'.unknown \cup s'.absent) \cap s'.projection = {}
          /\ (s'.headBorrow # {} => s'.unknown = {})
          /\ (~s'.online => s'.pending = {} /\ s'.owned = {} /\
               s'.prepareBorrow = {} /\ s'.batchBorrow = {} /\ s'.headBorrow = {} /\
               s'.admitted = s'.collected)
    BY ONLY <2>1, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10,
        <2>10a, <2>10ab, <2>10aa, <2>10b, <2>10c, <2>10d, <2>11, <2>12
  <2> QED BY ONLY <2>13
      DEF Ownership, Batches, CohortsOf, Members, Allocated
<1>5. PreparationOwnership'
  <2>0. \A t \in MemberDomain : Fragment(t) \in s.prepareBorrow => t \notin ts
    BY SafetyPreparationOwnership DEF PreparationOwnership, Freeze
  <2>0a. \A t \in MemberDomain : Input(t) \in Allocated => t \notin ts
    BY SafetyPreparationOwnership DEF PreparationOwnership, Freeze
  <2>1. s'.prepareBorrow \subseteq s'.prepareCalls \cap Allocated'
    BY SafetyPreparationOwnership, <1>0e, <1>0p, FS_Subset DEF PreparationOwnership
  <2>2. \A t \in MemberDomain :
         Fragment(t) \in s'.prepareBorrow =>
           Input(t) \in Allocated' /\ t \in s'.admitted \ BoundMembers'
    BY SafetyPreparationOwnership, <1>0d, <1>0e, <1>0k, <1>0p, <2>0, FS_Subset
        DEF PreparationOwnership
  <2>3. \A d \in CohortDomain :
         Batch(d) \in s'.prepareBorrow =>
           d \in s'.owned /\ Fragments(Members(d)') \subseteq Allocated'
    <3> SUFFICES ASSUME NEW d \in CohortDomain,
                         Batch(d) \in s'.prepareBorrow
                 PROVE d \in s'.owned /\ Fragments(Members(d)') \subseteq Allocated'
      OBVIOUS
    <3>1. /\ d \in s.owned
           /\ Fragments(Members(d)) \subseteq Allocated
      BY SafetyPreparationOwnership, <1>0e DEF PreparationOwnership
    <3>2. d \in s.issued /\ d # c
      BY SafetyOwnership, <3>1 DEF Ownership, Freeze
    <3>3. d \in s'.owned
      BY <1>0c, <3>1
    <3>4. s'.groups[d] = s.groups[d]
      BY <1>0j, <3>2
    <3> QED BY <1>0p, <3>1, <3>3, <3>4, FS_Subset DEF Members
  <2>4. \A t \in s'.prepared : Fragment(t) \in s'.prepareCalls \ s'.prepareBorrow
    BY SafetyPreparationOwnership, <1>0d, <1>0e DEF PreparationOwnership
  <2>5. \A t \in s'.prepared : Input(t) \notin Allocated'
    <3> SUFFICES ASSUME NEW t \in s'.prepared
                 PROVE Input(t) \notin Allocated'
      OBVIOUS
    <3>1. t \in s.prepared
      BY <1>0d
    <3>1a. t \in MemberDomain
      BY <1>1, <3>1 DEF TypeOK, MemberStateTypes
    <3>2. Input(t) \notin Allocated
      BY SafetyPreparationOwnership, <3>1 DEF PreparationOwnership
    <3>3. Input(t) \in Allocated' => Input(t) \in Allocated
      BY <1>0q, <3>1a
    <3> QED BY <3>2, <3>3
  <2>6. \A d \in s'.sealed : Batch(d) \in s'.prepareCalls \ s'.prepareBorrow
    BY SafetyPreparationOwnership, <1>0e, <1>0f DEF PreparationOwnership
  <2>7. \A t \in MemberDomain :
         Input(t) \in Allocated' => t \in s'.pending \/ Fragment(t) \in s'.prepareBorrow
    BY SafetyPreparationOwnership, <1>0c, <1>0e, <1>0q, <2>0a
        DEF PreparationOwnership
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7
      DEF PreparationOwnership
<1>6. ResourceBounds'
  <2>1. Cardinality(LiveMembers') <= QueueCapacity
    BY SafetyResourceBounds, <1>0d DEF ResourceBounds, LiveMembers
  <2>2aa. IsFiniteSet(CohortDomain)
    BY DEF ConstantsOK
  <2>2ab. s.owned \subseteq CohortDomain
    BY SafetyTypeOK DEF TypeOK, PublicationStateTypes
  <2>2a. IsFiniteSet(s.owned)
    BY ONLY <2>2aa, <2>2ab, FS_Subset
  <2>2b. c \notin s.owned
    BY SafetyOwnership DEF Ownership, Freeze
  <2>2c. Cardinality(s.owned) < Capacity
    BY DEF Freeze
  <2>2d. Cardinality(s'.owned) = Cardinality(s.owned) + 1
    BY <1>0c, <2>2a, <2>2b, FS_AddElement
  <2>2e. Cardinality(s.owned) \in Nat
    BY <2>2a, FS_CardinalityType
  <2>2f. Capacity \in Nat
    BY DEF ConstantsOK
  <2>2. Cardinality(s'.owned) <= Capacity
    BY ONLY <2>2c, <2>2d, <2>2e, <2>2f
  <2>3. Cardinality(s'.ready) <= Capacity
    BY SafetyResourceBounds, <1>0f DEF ResourceBounds
  <2>4. Cardinality(s'.headBorrow) <= 1
    BY SafetyResourceBounds, <1>0g DEF ResourceBounds
  <2>4a. Cardinality(s'.projection) <= 1
    BY SafetyResourceBounds, <1>0f DEF ResourceBounds
  <2>5. Cardinality(s'.prepareBorrow) <= PrepareCapacity
    BY SafetyResourceBounds, <1>0e DEF ResourceBounds
  <2>6a. UsedBytes' \subseteq ByteDomain
    BY <1>1 DEF TypeOK, PreparationMapTypes, UsedBytes, Resources
  <2>6b. IsFiniteSet(ByteDomain)
    BY DEF ConstantsOK
  <2>6. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
    BY ONLY <2>6a, <2>6b, FS_Subset
  <2>7. \A left, right \in Resources :
         left # right => s'.buffers[left] \cap s'.buffers[right] = {}
    <3> SUFFICES ASSUME NEW left \in Resources,
                         NEW right \in Resources,
                         left # right
                 PROVE s'.buffers[left] \cap s'.buffers[right] = {}
      OBVIOUS
    <3>1. CASE left = Batch(c)
      <4>1. /\ s'.buffers[left] = bytes
             /\ s'.buffers[right] = s.buffers[right]
        BY <1>0n, <3>1
      <4>2. s.buffers[right] \subseteq UsedBytes
        BY DEF UsedBytes
      <4> QED BY <1>0oa, <4>1, <4>2 DEF Freeze, Fresh
    <3>2. CASE right = Batch(c)
      <4>1. /\ s'.buffers[left] = s.buffers[left]
             /\ s'.buffers[right] = bytes
        BY <1>0n, <3>2
      <4>2. s.buffers[left] \subseteq UsedBytes
        BY DEF UsedBytes
      <4> QED BY <1>0oa, <4>1, <4>2 DEF Freeze, Fresh
    <3>3. CASE left # Batch(c) /\ right # Batch(c)
      BY SafetyResourceBounds, <1>0n, <3>3 DEF ResourceBounds
    <3> QED BY <3>1, <3>2, <3>3
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>4a, <2>5, <2>6, <2>7
      DEF ResourceBounds
<1>7. AuthoritySafety'
  <2>1. CohortsOf(s.authority \cup s.exported)' \subseteq
         s'.headCalls \ s'.headBorrow
    BY SafetyAuthority, <1>0g, <1>0h, <1>0m, FS_Subset DEF AuthoritySafety
  <2>2. s'.headBorrow \cap s'.abandoned = {}
    BY SafetyAuthority, <1>0f, <1>0g DEF AuthoritySafety
  <2>3. s'.unknownEpisode => s'.halted
    BY SafetyAuthority, <1>0i DEF AuthoritySafety
  <2>4. s'.exported \subseteq s'.delivered
    BY SafetyAuthority, <1>0d, <1>0h DEF AuthoritySafety
  <2>4a. s'.delivered \subseteq s'.collected
    BY SafetyAuthority, <1>0d DEF AuthoritySafety
  <2>4b. s'.authority \cap s'.discarded = {}
    BY SafetyAuthority, <1>0d, <1>0h DEF AuthoritySafety
  <2>5. s'.resolutionWrites = 0
    BY SafetyAuthority, <1>0i DEF AuthoritySafety
  <2>6. /\ CohortsOf(s.authority \cup s.exported)' \subseteq
              s'.headCalls \ s'.headBorrow
         /\ s'.headBorrow \cap s'.abandoned = {}
         /\ (s'.unknownEpisode => s'.halted)
         /\ s'.exported \subseteq s'.delivered
         /\ s'.delivered \subseteq s'.collected
         /\ s'.authority \cap s'.discarded = {}
         /\ s'.resolutionWrites = 0
    BY ONLY <2>1, <2>2, <2>3, <2>4, <2>4a, <2>4b, <2>5
  <2> QED BY ONLY <2>6 DEF AuthoritySafety, CohortsOf, Members
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM BatchPreparationPreserves ==
    ASSUME NEW c \in CohortDomain,
        NEW success \in BOOLEAN,
        ConstantsOK,
        Safety,
        StartBatchPrepare(c) \/ JoinBatchPrepare(c, success)
    PROVE Safety'
<1>1. CASE StartBatchPrepare(c)
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0b. /\ DOMAIN s' = StateFields
           /\ s'.prepareCalls = s.prepareCalls \cup {Batch(c)}
           /\ s'.prepareBorrow = s.prepareBorrow \cup {Batch(c)}
           /\ \A field \in StateFields \ {"prepareCalls", "prepareBorrow"} :
                s'[field] = s[field]
    BY <1>1, <2>0a, StartBatchPrepareProjection
  <2>0c. /\ s.online
           /\ c \in s.owned
           /\ Batch(c) \notin s.prepareCalls
           /\ Fragments(Members(c)) \subseteq Allocated
           /\ Cardinality(s.prepareBorrow) < PrepareCapacity
    BY <1>1 DEF StartBatchPrepare
  <2>0d. Batch(c) \notin s.prepareBorrow
    BY <2>0c, SafetyPreparationOwnership DEF PreparationOwnership
  <2>0e. Batch(c) \in Allocated
    BY <2>0c, SafetyOwnership DEF Ownership, Batches
  <2>0f. c \notin s.sealed
    BY <2>0c, SafetyPreparationOwnership DEF PreparationOwnership
  <2>0g. c \notin CohortsOf(s.collected)
    BY <2>0c, <2>0f, SafetyMembership, SafetyPublication
        DEF MembershipSafety, TerminalMembership, PublicationSafety, PublicationOrder,
        PublicationExclusion
  <2>0h. Batch(c) \notin Batches(CohortsOf(s.collected))
    BY <2>0g DEF Batches, Batch
  <2>0i. Batch(c) \notin Batches(s.prepareFailed)
    BY <2>0c, SafetyOwnership DEF Ownership, Batches, Batch
  <2>0j. /\ Allocated' = Allocated
           /\ BoundMembers' = BoundMembers
           /\ LiveMembers' = LiveMembers
           /\ UsedBytes' = UsedBytes
           /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
           /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
           /\ (CohortsOf(s.authority \cup s.exported))' =
                CohortsOf(s.authority \cup s.exported)
           /\ \A d \in CohortDomain : Members(d)' = Members(d)
    BY <2>0b DEF StateFields, Allocated, BoundMembers, LiveMembers, UsedBytes,
       CohortsOf, Members
  <2>1. TypeOK'
    <3>1. StateShape'
      BY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY <2>0b, SafetyTypeOK DEF TypeOK, MemberStateTypes, StateFields
    <3>3. PreparationMapTypes'
      <4>1. s'.groups \in [CohortDomain -> SUBSET MemberDomain]
        BY <2>0b, SafetyTypeOK DEF TypeOK, PreparationMapTypes, StateFields
      <4>2. s'.buffers \in [Resources -> SUBSET ByteDomain]
        BY <2>0b, SafetyTypeOK DEF TypeOK, PreparationMapTypes, StateFields
      <4>3. s'.prepareCalls \subseteq Work
        BY <2>0b, SafetyTypeOK, FS_Subset
            DEF TypeOK, PreparationMapTypes, Work, Batches, Batch
      <4>4. s'.prepareBorrow \subseteq Work
        BY <2>0b, SafetyTypeOK, FS_Subset
            DEF TypeOK, PreparationMapTypes, Work, Batches, Batch
      <4> QED BY <4>1, <4>2, <4>3, <4>4 DEF PreparationMapTypes
    <3>4. CohortStateTypes'
      BY <2>0b, SafetyTypeOK DEF TypeOK, CohortStateTypes, StateFields
    <3>5. PublicationStateTypes'
      BY <2>0b, SafetyTypeOK DEF TypeOK, PublicationStateTypes, StateFields
    <3>6. AuthorityStateTypes'
      BY <2>0b, SafetyTypeOK DEF TypeOK, AuthorityStateTypes, StateFields
    <3>7. LifecycleStateTypes'
      BY <2>0b, SafetyTypeOK DEF TypeOK, LifecycleStateTypes, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>1. AdmissionMembership'
      BY <2>0b, SafetyMembership DEF MembershipSafety, AdmissionMembership, StateFields
    <3>2. BoundMembership'
      BY <2>0b, <2>0j, SafetyMembership
          DEF MembershipSafety, BoundMembership, StateFields
    <3>3. GroupPartition'
      <4>1. \A d \in CohortDomain : d \in s'.issued <=> Members(d)' # {}
        BY <2>0b, <2>0j, SafetyMembership
            DEF MembershipSafety, GroupPartition, StateFields
      <4>2. \A d, e \in CohortDomain :
               d # e => Members(d)' \cap Members(e)' = {}
        BY <2>0j, SafetyMembership DEF MembershipSafety, GroupPartition
      <4>3. \A d \in s'.issued : Cardinality(Members(d)') <= MemberCapacity
        <5> SUFFICES ASSUME NEW d \in s'.issued
                     PROVE Cardinality(Members(d)') <= MemberCapacity
          OBVIOUS
        <5>1. d \in s.issued
          BY <2>0b DEF StateFields
        <5>2. d \in CohortDomain
          BY <5>1, SafetyTypeOK DEF TypeOK, CohortStateTypes
        <5>3. Members(d)' = Members(d)
          BY <2>0j, <5>2
        <5> QED BY <5>1, <5>3, SafetyMembership DEF MembershipSafety, GroupPartition
      <4> QED BY <4>1, <4>2, <4>3 DEF GroupPartition
    <3>4. AuthorityMembership'
      BY <2>0b, <2>0j, SafetyMembership
          DEF MembershipSafety, AuthorityMembership, StateFields
    <3>5. TerminalMembership'
      BY <2>0b, <2>0h, <2>0j, SafetyMembership
          DEF MembershipSafety, TerminalMembership, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>1. PublicationOrder'
      BY <2>0b, SafetyPublication DEF PublicationSafety, PublicationOrder, StateFields
    <3>2. PublicationExclusion'
      BY <2>0b, SafetyPublication DEF PublicationSafety, PublicationExclusion, StateFields
    <3>3. PublicationPredecessorOrder'
      BY <2>0b, SafetyPublication
          DEF PublicationSafety, PublicationPredecessorOrder, StateFields
    <3>4. PublicationAcknowledgement'
      BY <2>0b, <2>0j, SafetyPublication
          DEF PublicationSafety, PublicationAcknowledgement, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY SafetyOwnership
    <3>1. (s.owned \subseteq s.issued)'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>2. (Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated)'
      BY <2>0b, <2>0j, <3>0 DEF Ownership, StateFields
    <3>3. (s.ready \subseteq
             (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned))'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>4. (s.batchBorrow \cup s.headBorrow \subseteq s.owned)'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>5. (s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls)'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>6. (s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {})'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>7. (s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow)'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>8. (s.unknown \subseteq
             (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted))'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9. (s.absent \subseteq s.headCalls \ s.headBorrow)'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9a. (s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls))'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9ab. (Batches(s.prepareFailed) \subseteq s.prepareCalls \ s.prepareBorrow)'
      BY <2>0b, <2>0i, <3>0 DEF Ownership, StateFields
    <3>9aa. (s.batchFailed \subseteq
          (s.owned \cap s.batchCalls) \ (s.batchBorrow \cup s.stored \cup s.headCalls))'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9b. (s.projection \subseteq (s.owned \cap s.validated) \ s.abandoned)'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9c. (s.headBorrow \cup s.accepted \subseteq s.projection)'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9d. ((s.unknown \cup s.absent) \cap s.projection = {})'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>10. (s.headBorrow # {} => s.unknown = {})'
      BY <2>0b, <3>0 DEF Ownership, StateFields
    <3>11. (~s.online => s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
             s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected)'
      BY <2>0b, <2>0c DEF StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7, <3>8, <3>9,
        <3>9a, <3>9ab, <3>9aa, <3>9b, <3>9c, <3>9d, <3>10, <3>11 DEF Ownership
  <2>5. PreparationOwnership'
    <3>0. PreparationOwnership
      BY SafetyPreparationOwnership
    <3>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
      BY <2>0b, <2>0e, <2>0j, <3>0, FS_Subset DEF PreparationOwnership
    <3>2. (\A u \in MemberDomain : Fragment(u) \in s.prepareBorrow =>
             Input(u) \in Allocated /\ u \in s.admitted \ BoundMembers)'
      BY <2>0b, <2>0j, <3>0
          DEF PreparationOwnership, StateFields, Fragment, Batch
    <3>3. (\A d \in CohortDomain : Batch(d) \in s.prepareBorrow =>
             d \in s.owned /\ Fragments(Members(d)) \subseteq Allocated)'
      BY <2>0b, <2>0c, <2>0j, <3>0
          DEF PreparationOwnership, StateFields, Batch
    <3>4. (\A u \in s.prepared : Fragment(u) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0b, <3>0 DEF PreparationOwnership, StateFields, Fragment, Batch
    <3>5. (\A u \in s.prepared : Input(u) \notin Allocated)'
      BY <2>0b, <2>0j, <3>0 DEF PreparationOwnership, StateFields
    <3>6. (\A d \in s.sealed : Batch(d) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0b, <2>0c, <2>0f, <3>0 DEF PreparationOwnership, StateFields, Batch
    <3>7. (\A u \in MemberDomain : Input(u) \in Allocated =>
             u \in s.pending \/ Fragment(u) \in s.prepareBorrow)'
      BY <2>0b, <2>0j, <3>0 DEF PreparationOwnership, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF PreparationOwnership
  <2>6. ResourceBounds'
    <3>0. ResourceBounds
      BY SafetyResourceBounds
    <3>1. Cardinality(LiveMembers') <= QueueCapacity
      BY <2>0j, <3>0 DEF ResourceBounds
    <3>2. Cardinality(s'.owned) <= Capacity
      BY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3>3. Cardinality(s'.ready) <= Capacity
      BY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3>4. Cardinality(s'.headBorrow) <= 1
      BY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3>4a. Cardinality(s'.projection) <= 1
      BY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3>5aa. IsFiniteSet(MemberDomain)
      BY DEF ConstantsOK
    <3>5ab. [u \in MemberDomain |-> Fragment(u)]
               \in Surjection(MemberDomain, Fragments(MemberDomain))
      BY DEF Surjection, Fragments
    <3>5a. IsFiniteSet(Fragments(MemberDomain))
      BY <3>5aa, <3>5ab, FS_Surjection
    <3>5ba. IsFiniteSet(CohortDomain)
      BY DEF ConstantsOK
    <3>5bb. [d \in CohortDomain |-> Batch(d)]
               \in Surjection(CohortDomain, Batches(CohortDomain))
      BY DEF Surjection, Batches
    <3>5b. IsFiniteSet(Batches(CohortDomain))
      BY <3>5ba, <3>5bb, FS_Surjection
    <3>5c. IsFiniteSet(Work)
      BY <3>5a, <3>5b, FS_Union DEF Work
    <3>5d. s.prepareBorrow \subseteq Work
      BY SafetyTypeOK DEF TypeOK, PreparationMapTypes
    <3>5e. IsFiniteSet(s.prepareBorrow)
      BY <3>5c, <3>5d, FS_Subset
    <3>5f. Cardinality(s'.prepareBorrow) = Cardinality(s.prepareBorrow) + 1
      BY <2>0b, <2>0d, <3>5e, FS_AddElement
    <3>5g. Cardinality(s.prepareBorrow) \in Nat /\ PrepareCapacity \in Nat
      BY <3>5e, FS_CardinalityType DEF ConstantsOK
    <3>5. Cardinality(s'.prepareBorrow) <= PrepareCapacity
      BY ONLY <2>0c, <3>5f, <3>5g
    <3>6. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
      BY <2>0j, <3>0 DEF ResourceBounds
    <3>7. \A left, right \in Resources : left # right =>
             s'.buffers[left] \cap s'.buffers[right] = {}
      BY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>4a, <3>5, <3>6, <3>7
        DEF ResourceBounds
  <2>7. AuthoritySafety'
    BY <2>0b, <2>0j, SafetyAuthority DEF AuthoritySafety, StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1>2. CASE JoinBatchPrepare(c, success)
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0b. DOMAIN s' = StateFields
    BY <1>2, <2>0a, JoinBatchPrepareProjection
  <2>0ba. s'.prepareBorrow = s.prepareBorrow \ {Batch(c)}
    BY <1>2, <2>0a, JoinBatchPrepareProjection
  <2>0bb. s'.buffers = Release(s.buffers, Fragments(Members(c)))
    BY <1>2, <2>0a, JoinBatchPrepareProjection
  <2>0bc. s'.sealed =
             (IF KeepBatchPrepare(c, success) THEN s.sealed \cup {c} ELSE s.sealed)
    BY <1>2, <2>0a, JoinBatchPrepareProjection
  <2>0bd. s'.ready =
             (IF KeepBatchPrepare(c, success) THEN s.ready \cup {c} ELSE s.ready)
    BY <1>2, <2>0a, JoinBatchPrepareProjection
  <2>0be. s'.prepareFailed =
             (IF KeepBatchPrepare(c, success) THEN s.prepareFailed
              ELSE s.prepareFailed \cup {c})
    BY <1>2, <2>0a, JoinBatchPrepareProjection
  <2>0bf. \A field \in StateFields \
              {"prepareBorrow", "buffers", "sealed", "ready", "prepareFailed"} :
              s'[field] = s[field]
    BY <1>2, <2>0a, JoinBatchPrepareProjection
  <2>0c. Batch(c) \in s.prepareBorrow /\ success \in BOOLEAN
    BY <1>2 DEF JoinBatchPrepare
  <2>0d. KeepBatchPrepare(c, success) \in BOOLEAN
    BY <2>0c DEF KeepBatchPrepare
  <2>0e. c \in s.owned /\ Fragments(Members(c)) \subseteq Allocated
    BY <2>0c, SafetyPreparationOwnership DEF PreparationOwnership
  <2>0f. /\ BoundMembers' = BoundMembers
           /\ LiveMembers' = LiveMembers
           /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
           /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
           /\ (CohortsOf(s.authority \cup s.exported))' =
                CohortsOf(s.authority \cup s.exported)
           /\ \A d \in CohortDomain : Members(d)' = Members(d)
    BY <2>0bf DEF StateFields, BoundMembers, LiveMembers, CohortsOf, Members
  <2>0g. /\ Batch(c) \in s.prepareCalls
           /\ c \notin s.sealed
           /\ c \notin s.batchCalls
           /\ c \notin s.prepareFailed
    BY <2>0c, SafetyPublication, SafetyOwnership, SafetyPreparationOwnership
       DEF PublicationSafety, PublicationOrder, Ownership, PreparationOwnership,
           Batches, Batch
  <2>0ga. c \in s.issued
    BY <2>0e, SafetyOwnership DEF Ownership
  <2>0gb. Members(c) \subseteq s.prepared
    BY <2>0ga, SafetyMembership
       DEF MembershipSafety, BoundMembership, BoundMembers
  <2>0h. Allocated' = Allocated \ Fragments(Members(c))
    <3>1. Allocated' \subseteq Allocated \ Fragments(Members(c))
      <4> SUFFICES ASSUME NEW r \in Allocated'
                   PROVE r \in Allocated \ Fragments(Members(c))
        OBVIOUS
      <4>1. /\ r \in Resources
             /\ s'.buffers[r] # {}
        BY DEF Allocated
      <4>2. /\ r \notin Fragments(Members(c))
             /\ s'.buffers[r] = s.buffers[r]
        BY <2>0bb, <4>1 DEF Release
      <4> QED BY <4>1, <4>2 DEF Allocated
    <3>2. Allocated \ Fragments(Members(c)) \subseteq Allocated'
      <4> SUFFICES ASSUME NEW r \in Allocated \ Fragments(Members(c))
                   PROVE r \in Allocated'
        OBVIOUS
      <4>1. /\ r \in Resources
             /\ s.buffers[r] # {}
             /\ r \notin Fragments(Members(c))
        BY DEF Allocated
      <4>2. s'.buffers[r] = s.buffers[r]
        BY <2>0bb, <4>1 DEF Release
      <4> QED BY <4>1, <4>2 DEF Allocated
    <3> QED BY <3>1, <3>2
  <2>0i. UsedBytes' \subseteq UsedBytes
    <3> SUFFICES ASSUME NEW byte \in UsedBytes'
                 PROVE byte \in UsedBytes
      OBVIOUS
    <3>1. PICK r \in Resources : byte \in s'.buffers[r]
      BY DEF UsedBytes
    <3>2. /\ r \notin Fragments(Members(c))
           /\ s'.buffers[r] = s.buffers[r]
      BY <2>0bb, <3>1 DEF Release
    <3> QED BY <3>1, <3>2 DEF UsedBytes
  <2>0j. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \cap
             Fragments(Members(c)) = {}
    BY DEF Batches, Fragments, Batch, Fragment
  <2>0k. s'.prepareBorrow \cap Fragments(Members(c)) = {}
    BY <2>0ba, <2>0gb, SafetyPreparationOwnership
       DEF PreparationOwnership, Fragments, Batch, Fragment
  <2>0l. s.online
    BY <2>0c, SafetyOwnership DEF Ownership
  <2>0m. \A r \in Resources :
           s'.buffers[r] = IF r \in Fragments(Members(c)) THEN {} ELSE s.buffers[r]
    BY <2>0bb DEF Release
  <2>1. TypeOK'
    <3>1. StateShape'
      BY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY <2>0bf, SafetyTypeOK DEF TypeOK, MemberStateTypes, StateFields
    <3>3. PreparationMapTypes'
      <4>1. s'.groups \in [CohortDomain -> SUBSET MemberDomain]
        BY <2>0bf, SafetyTypeOK DEF TypeOK, PreparationMapTypes, StateFields
      <4>2. s'.buffers \in [Resources -> SUBSET ByteDomain]
        BY <2>0bb, SafetyTypeOK DEF TypeOK, PreparationMapTypes, Release
      <4>3. s'.prepareCalls \subseteq Work
        BY <2>0bf, SafetyTypeOK DEF TypeOK, PreparationMapTypes, StateFields
      <4>4. s'.prepareBorrow \subseteq Work
        BY <2>0ba, SafetyTypeOK, FS_RemoveElement, FS_Subset
            DEF TypeOK, PreparationMapTypes
      <4> QED BY <4>1, <4>2, <4>3, <4>4 DEF PreparationMapTypes
    <3>4. CohortStateTypes'
      <4>1. (s.sealed \subseteq CohortDomain /\ s.ready \subseteq CohortDomain)'
        BY <2>0bc, <2>0bd, <2>0d, SafetyTypeOK, FS_AddElement, FS_Subset
            DEF TypeOK, CohortStateTypes
      <4>2. (s.issued \subseteq CohortDomain /\ s.stored \subseteq CohortDomain)'
        BY <2>0bf, SafetyTypeOK DEF TypeOK, CohortStateTypes, StateFields
      <4>3. (s.published \subseteq CohortDomain /\ s.retired \subseteq CohortDomain)'
        BY <2>0bf, SafetyTypeOK DEF TypeOK, CohortStateTypes, StateFields
      <4>4. (s.excluded \subseteq CohortDomain /\ s.abandoned \subseteq CohortDomain)'
        BY <2>0bf, SafetyTypeOK DEF TypeOK, CohortStateTypes, StateFields
      <4>5. (s.prepareFailed \subseteq CohortDomain /\ s.batchFailed \subseteq CohortDomain)'
        BY <2>0be, <2>0bf, <2>0d, SafetyTypeOK, FS_AddElement, FS_Subset
            DEF TypeOK, CohortStateTypes, StateFields
      <4>6. (s.validated \subseteq CohortDomain)'
        BY <2>0bf, SafetyTypeOK DEF TypeOK, CohortStateTypes, StateFields
      <4>7. (s.projection \subseteq CohortDomain)'
        BY <2>0bf, SafetyTypeOK DEF TypeOK, CohortStateTypes, StateFields
      <4> QED BY <4>1, <4>2, <4>3, <4>4, <4>5, <4>6, <4>7 DEF CohortStateTypes
    <3>5. PublicationStateTypes'
      BY <2>0bf, SafetyTypeOK DEF TypeOK, PublicationStateTypes, StateFields
    <3>6. AuthorityStateTypes'
      BY <2>0bf, SafetyTypeOK DEF TypeOK, AuthorityStateTypes, StateFields
    <3>7. LifecycleStateTypes'
      BY <2>0bf, SafetyTypeOK DEF TypeOK, LifecycleStateTypes, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>1. AdmissionMembership'
      BY <2>0bf, SafetyMembership DEF MembershipSafety, AdmissionMembership, StateFields
    <3>2. BoundMembership'
      BY <2>0bf, <2>0f, SafetyMembership
          DEF MembershipSafety, BoundMembership, StateFields
    <3>3. GroupPartition'
      <4>1. \A d \in CohortDomain : d \in s'.issued <=> Members(d)' # {}
        BY <2>0bf, <2>0f, SafetyMembership
            DEF MembershipSafety, GroupPartition, StateFields
      <4>2. \A d, e \in CohortDomain :
               d # e => Members(d)' \cap Members(e)' = {}
        BY <2>0f, SafetyMembership DEF MembershipSafety, GroupPartition
      <4>3. \A d \in s'.issued : Cardinality(Members(d)') <= MemberCapacity
        <5> SUFFICES ASSUME NEW d \in s'.issued
                     PROVE Cardinality(Members(d)') <= MemberCapacity
          OBVIOUS
        <5>1. d \in s.issued
          BY <2>0bf DEF StateFields
        <5>2. d \in CohortDomain
          BY <5>1, SafetyTypeOK DEF TypeOK, CohortStateTypes
        <5>3. Members(d)' = Members(d)
          BY <2>0f, <5>2
        <5> QED BY <5>1, <5>3, SafetyMembership DEF MembershipSafety, GroupPartition
      <4> QED BY <4>1, <4>2, <4>3 DEF GroupPartition
    <3>4. AuthorityMembership'
      BY <2>0bf, <2>0f, SafetyMembership
          DEF MembershipSafety, AuthorityMembership, StateFields
    <3>5. TerminalMembership'
      BY <2>0ba, <2>0bf, <2>0f, SafetyMembership, FS_RemoveElement, FS_Subset
          DEF MembershipSafety, TerminalMembership, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>1. PublicationOrder'
      <4>1. (s.retired \subseteq s.published /\ s.published \subseteq s.headCalls /\
             s.headCalls \subseteq s.validated /\ s.validated \subseteq s.stored /\
             s.stored \subseteq s.batchCalls)'
        BY <2>0bf, SafetyPublication
            DEF PublicationSafety, PublicationOrder, StateFields
      <4>2. (s.batchCalls \subseteq s.sealed)'
        BY <2>0bc, <2>0bf, <2>0d, SafetyPublication, FS_Subset
            DEF PublicationSafety, PublicationOrder, StateFields
      <4>3. (s.sealed \subseteq s.issued)'
        <5>1. s'.issued = s.issued
          BY <2>0bf DEF StateFields
        <5>2. c \in s.issued
          BY <2>0e, SafetyOwnership DEF Ownership
        <5>3. IF KeepBatchPrepare(c, success)
               THEN s.sealed \cup {c} \subseteq s.issued
               ELSE s.sealed \subseteq s.issued
          BY <2>0d, <5>2, SafetyPublication, FS_AddElement, FS_Subset
              DEF PublicationSafety, PublicationOrder
        <5> QED BY <2>0bc, <5>1, <5>3
      <4> QED BY <4>1, <4>2, <4>3 DEF PublicationOrder
    <3>2. PublicationExclusion'
      BY <2>0bf, SafetyPublication
          DEF PublicationSafety, PublicationExclusion, StateFields
    <3>3. PublicationPredecessorOrder'
      BY <2>0bf, SafetyPublication
          DEF PublicationSafety, PublicationPredecessorOrder, StateFields
    <3>4. PublicationAcknowledgement'
      BY <2>0bf, <2>0f, SafetyPublication
          DEF PublicationSafety, PublicationAcknowledgement, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY SafetyOwnership
    <3>1. (s.owned \subseteq s.issued)'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>2. (Batches(s.owned \cup CohortsOf(s.authority \cup s.exported)) \subseteq Allocated)'
      BY <2>0bf, <2>0f, <2>0h, <2>0j, <3>0 DEF Ownership, StateFields
    <3>3. (s.ready \subseteq
             (s.owned \cap s.sealed) \ (s.batchCalls \cup s.abandoned))'
      BY <2>0bc, <2>0bd, <2>0bf, <2>0d, <2>0e, <2>0g, <3>0,
         FS_AddElement, FS_Subset
          DEF Ownership, KeepBatchPrepare, StateFields
    <3>4. (s.batchBorrow \cup s.headBorrow \subseteq s.owned)'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>5. (s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls)'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>6. (s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {})'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>7. (s.accepted \subseteq (s.owned \cap s.published) \ s.headBorrow)'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>8. (s.unknown \subseteq
             (s.owned \cap s.headCalls) \ (s.headBorrow \cup s.accepted))'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>9. (s.absent \subseteq s.headCalls \ s.headBorrow)'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>9a. (s.prepareFailed \subseteq s.owned \ (s.sealed \cup s.batchCalls))'
      <4>1. s.prepareFailed \subseteq
               s.owned \ ((s.sealed \cup {c}) \cup s.batchCalls)
        BY <2>0g, <3>0 DEF Ownership
      <4>2. s.prepareFailed \cup {c} \subseteq
               s.owned \ (s.sealed \cup s.batchCalls)
        BY <2>0e, <2>0g, <3>0, FS_AddElement, FS_Subset DEF Ownership
      <4>3. IF KeepBatchPrepare(c, success)
               THEN s.prepareFailed \subseteq
                      s.owned \ ((s.sealed \cup {c}) \cup s.batchCalls)
               ELSE s.prepareFailed \cup {c} \subseteq
                      s.owned \ (s.sealed \cup s.batchCalls)
        BY <2>0d, <4>1, <4>2
      <4> QED BY <2>0bc, <2>0be, <2>0bf, <4>3 DEF StateFields
    <3>9ab. (Batches(s.prepareFailed) \subseteq s.prepareCalls \ s.prepareBorrow)'
      BY <2>0ba, <2>0be, <2>0bf, <2>0d, <2>0g, <3>0,
         FS_AddElement, FS_RemoveElement, FS_Subset
          DEF Ownership, Batches, Batch, StateFields
    <3>9aa. (s.batchFailed \subseteq
          (s.owned \cap s.batchCalls) \ (s.batchBorrow \cup s.stored \cup s.headCalls))'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>9b. (s.projection \subseteq (s.owned \cap s.validated) \ s.abandoned)'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>9c. (s.headBorrow \cup s.accepted \subseteq s.projection)'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>9d. ((s.unknown \cup s.absent) \cap s.projection = {})'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>10. (s.headBorrow # {} => s.unknown = {})'
      BY <2>0bf, <3>0 DEF Ownership, StateFields
    <3>11. (~s.online => s.pending = {} /\ s.owned = {} /\ s.prepareBorrow = {} /\
             s.batchBorrow = {} /\ s.headBorrow = {} /\ s.admitted = s.collected)'
      BY <2>0bf, <2>0l, <3>0 DEF Ownership, StateFields
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7, <3>8, <3>9,
        <3>9a, <3>9ab, <3>9aa, <3>9b, <3>9c, <3>9d, <3>10, <3>11 DEF Ownership
  <2>5. PreparationOwnership'
    <3>0. PreparationOwnership
      BY SafetyPreparationOwnership
    <3>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
      BY <2>0ba, <2>0bf, <2>0h, <2>0k, <3>0, FS_RemoveElement, FS_Subset
          DEF PreparationOwnership, StateFields
    <3>2. (\A u \in MemberDomain : Fragment(u) \in s.prepareBorrow =>
             Input(u) \in Allocated /\ u \in s.admitted \ BoundMembers)'
      BY <2>0ba, <2>0bf, <2>0f, <2>0h, <3>0
          DEF PreparationOwnership, StateFields, Fragments, Input, Fragment, Batch
    <3>3. (\A d \in CohortDomain : Batch(d) \in s.prepareBorrow =>
             d \in s.owned /\ Fragments(Members(d)) \subseteq Allocated)'
      <4> SUFFICES ASSUME NEW d \in CohortDomain,
                           Batch(d) \in s'.prepareBorrow
                   PROVE d \in s'.owned /\ Fragments(Members(d)') \subseteq Allocated'
        OBVIOUS
      <4>1. Batch(d) \in s.prepareBorrow /\ d # c
        BY <2>0ba DEF Batch
      <4>2. d \in s.owned /\ Fragments(Members(d)) \subseteq Allocated
        BY <3>0, <4>1 DEF PreparationOwnership
      <4>3. Fragments(Members(d)) \cap Fragments(Members(c)) = {}
        BY <4>1, SafetyMembership
           DEF MembershipSafety, GroupPartition, Fragments, Fragment
      <4>4. Fragments(Members(d)) \subseteq Allocated'
        BY <2>0h, <4>2, <4>3
      <4> QED BY <2>0bf, <2>0f, <4>2, <4>4 DEF StateFields
    <3>4. (\A u \in s.prepared : Fragment(u) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0ba, <2>0bf, <3>0
          DEF PreparationOwnership, StateFields, Fragment, Batch
    <3>5. (\A u \in s.prepared : Input(u) \notin Allocated)'
      BY <2>0bf, <2>0h, <3>0 DEF PreparationOwnership, StateFields
    <3>6. (\A d \in s.sealed : Batch(d) \in s.prepareCalls \ s.prepareBorrow)'
      BY <2>0ba, <2>0bc, <2>0bf, <2>0d, <2>0g, <3>0,
         FS_AddElement, FS_RemoveElement, FS_Subset
          DEF PreparationOwnership, StateFields, Batch
    <3>7. (\A u \in MemberDomain : Input(u) \in Allocated =>
             u \in s.pending \/ Fragment(u) \in s.prepareBorrow)'
      BY <2>0ba, <2>0bf, <2>0h, <3>0
          DEF PreparationOwnership, StateFields, Input, Fragment, Batch
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF PreparationOwnership
  <2>6. ResourceBounds'
    <3>0. ResourceBounds
      BY SafetyResourceBounds
    <3>1. Cardinality(LiveMembers') <= QueueCapacity
      BY <2>0f, <3>0 DEF ResourceBounds
    <3>2. Cardinality(s'.owned) <= Capacity
      BY <2>0bf, <3>0 DEF ResourceBounds, StateFields
    <3>3a. s'.ready \subseteq s'.owned
      BY <2>4 DEF Ownership
    <3>3ba. IsFiniteSet(CohortDomain)
      BY DEF ConstantsOK
    <3>3bb. s'.owned \subseteq CohortDomain
      BY <2>1 DEF TypeOK, PublicationStateTypes
    <3>3b. IsFiniteSet(s'.owned)
      BY <3>3ba, <3>3bb, FS_Subset
    <3>3c. Cardinality(s'.ready) <= Cardinality(s'.owned)
      BY <3>3a, <3>3b, FS_Subset
    <3>3d. /\ Cardinality(s'.ready) \in Nat
             /\ Cardinality(s'.owned) \in Nat
             /\ Capacity \in Nat
      BY <3>3a, <3>3b, FS_Subset, FS_CardinalityType DEF ConstantsOK
    <3>3. Cardinality(s'.ready) <= Capacity
      BY ONLY <3>2, <3>3c, <3>3d
    <3>4. Cardinality(s'.headBorrow) <= 1
      BY <2>0bf, <3>0 DEF ResourceBounds, StateFields
    <3>4a. Cardinality(s'.projection) <= 1
      BY <2>0bf, <3>0 DEF ResourceBounds, StateFields
    <3>5aa. IsFiniteSet(MemberDomain)
      BY DEF ConstantsOK
    <3>5ab. [u \in MemberDomain |-> Fragment(u)]
               \in Surjection(MemberDomain, Fragments(MemberDomain))
      BY DEF Surjection, Fragments
    <3>5a. IsFiniteSet(Fragments(MemberDomain))
      BY <3>5aa, <3>5ab, FS_Surjection
    <3>5ba. IsFiniteSet(CohortDomain)
      BY DEF ConstantsOK
    <3>5bb. [d \in CohortDomain |-> Batch(d)]
               \in Surjection(CohortDomain, Batches(CohortDomain))
      BY DEF Surjection, Batches
    <3>5b. IsFiniteSet(Batches(CohortDomain))
      BY <3>5ba, <3>5bb, FS_Surjection
    <3>5c. IsFiniteSet(Work)
      BY <3>5a, <3>5b, FS_Union DEF Work
    <3>5d. s.prepareBorrow \subseteq Work /\ s'.prepareBorrow \subseteq s.prepareBorrow
      BY <2>0ba, SafetyTypeOK, FS_RemoveElement, FS_Subset
          DEF TypeOK, PreparationMapTypes
    <3>5e. IsFiniteSet(s.prepareBorrow)
      BY <3>5c, <3>5d, FS_Subset
    <3>5f. /\ IsFiniteSet(s'.prepareBorrow)
             /\ Cardinality(s'.prepareBorrow) <= Cardinality(s.prepareBorrow)
      BY <3>5d, <3>5e, FS_Subset
    <3>5g. Cardinality(s.prepareBorrow) <= PrepareCapacity
      BY <3>0 DEF ResourceBounds
    <3>5h. /\ Cardinality(s'.prepareBorrow) \in Nat
             /\ Cardinality(s.prepareBorrow) \in Nat
             /\ PrepareCapacity \in Nat
      BY <3>5e, <3>5f, FS_CardinalityType DEF ConstantsOK
    <3>5. Cardinality(s'.prepareBorrow) <= PrepareCapacity
      BY ONLY <3>5f, <3>5g, <3>5h
    <3>6a. UsedBytes' \subseteq ByteDomain
      BY <2>1 DEF TypeOK, PreparationMapTypes, UsedBytes, Resources
    <3>6b. IsFiniteSet(ByteDomain)
      BY DEF ConstantsOK
    <3>6. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
      BY <3>6a, <3>6b, FS_Subset
    <3>7. \A left, right \in Resources : left # right =>
             s'.buffers[left] \cap s'.buffers[right] = {}
      BY <2>0m, <3>0 DEF ResourceBounds
    <3> QED BY <3>1, <3>2, <3>3, <3>4, <3>4a, <3>5, <3>6, <3>7
        DEF ResourceBounds
  <2>7. AuthoritySafety'
    BY <2>0bf, <2>0f, SafetyAuthority DEF AuthoritySafety, StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1> QED BY <1>1, <1>2

THEOREM PublicationPreserves ==
    ASSUME NEW c \in CohortDomain,
        NEW entered \in BOOLEAN,
        NEW uncertain \in BOOLEAN,
        ConstantsOK,
        Safety,
        StartBatch(c) \/ JoinBatch(c, entered) \/ ValidateFront(c, entered) \/ StartHead(c) \/
            JoinHead(c, entered, uncertain) \/ Retire(c, entered)
    PROVE Safety'
<1>1. CASE StartBatch(c)
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0b. /\ DOMAIN s' = StateFields
           /\ s'.ready = s.ready \ {c}
           /\ s'.batchCalls = s.batchCalls \cup {c}
           /\ s'.batchBorrow = s.batchBorrow \cup {c}
           /\ \A field \in StateFields \ {"ready", "batchCalls", "batchBorrow"} :
                s'[field] = s[field]
    BY <1>1, <2>0a, StartBatchProjection
  <2>0c. /\ s.online
           /\ c \in s.ready
    BY <1>1 DEF StartBatch
  <2>0d. /\ c \in s.owned
           /\ c \in s.sealed
           /\ c \notin s.batchCalls
           /\ c \notin s.abandoned
    BY <2>0c, SafetyOwnership DEF Ownership
  <2>0e. c \notin s.stored
    BY <2>0d, SafetyPublication DEF PublicationSafety, PublicationOrder
  <2>0f. c \notin CohortsOf(s.collected)
    BY <2>0d, SafetyMembership, SafetyPublication
       DEF MembershipSafety, TerminalMembership, PublicationSafety, PublicationOrder,
       PublicationExclusion
  <2>0g. /\ Allocated' = Allocated
           /\ BoundMembers' = BoundMembers
           /\ LiveMembers' = LiveMembers
           /\ UsedBytes' = UsedBytes
           /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
           /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
           /\ (CohortsOf(s.authority \cup s.exported))' =
                CohortsOf(s.authority \cup s.exported)
           /\ \A d \in CohortDomain : Members(d)' = Members(d)
    BY <2>0b DEF StateFields, Allocated, BoundMembers, LiveMembers, UsedBytes,
       CohortsOf, Members
  <2>1. TypeOK'
    <3>1. StateShape'
      BY ONLY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY ONLY <2>0b, Safety, SafetyTypeOK DEF TypeOK, MemberStateTypes, StateFields
    <3>3. PreparationMapTypes'
      BY ONLY <2>0b, Safety, SafetyTypeOK DEF TypeOK, PreparationMapTypes, StateFields
    <3>4. CohortStateTypes'
      BY ONLY <2>0b, Safety, SafetyTypeOK, FS_RemoveElement, FS_Subset
         DEF TypeOK, CohortStateTypes, StateFields
    <3>5a. PublicationStateTypes
      BY ONLY Safety, SafetyTypeOK DEF TypeOK
    <3>5. PublicationStateTypes'
      <4>1. s'.batchCalls \subseteq CohortDomain
        BY ONLY <2>0b, <3>5a, FS_AddElement, FS_Subset
           DEF PublicationStateTypes
      <4>2. s'.batchBorrow \subseteq CohortDomain
        BY ONLY <2>0b, <3>5a, FS_AddElement, FS_Subset
           DEF PublicationStateTypes
      <4>3. /\ s'.headCalls \subseteq CohortDomain
             /\ s'.headBorrow \subseteq CohortDomain
             /\ s'.owned \subseteq CohortDomain
             /\ s'.accepted \subseteq CohortDomain
             /\ s'.unknown \subseteq CohortDomain
             /\ s'.absent \subseteq CohortDomain
        BY ONLY <2>0b, <3>5a DEF PublicationStateTypes, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF PublicationStateTypes
    <3>6. AuthorityStateTypes'
      BY ONLY <2>0b, Safety, SafetyTypeOK DEF TypeOK, AuthorityStateTypes, StateFields
    <3>7. LifecycleStateTypes'
      BY ONLY <2>0b, Safety, SafetyTypeOK DEF TypeOK, LifecycleStateTypes, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>1. AdmissionMembership'
      BY ONLY <2>0b, Safety, SafetyMembership
         DEF MembershipSafety, AdmissionMembership, StateFields
    <3>2. BoundMembership'
      BY ONLY <2>0b, <2>0g, Safety, SafetyMembership
         DEF MembershipSafety, BoundMembership, StateFields
    <3>3. GroupPartition'
      <4>1. \A d \in CohortDomain : d \in s'.issued <=> Members(d)' # {}
        BY ONLY <2>0b, <2>0g, Safety, SafetyMembership
           DEF MembershipSafety, GroupPartition, StateFields
      <4>2. \A d, e \in CohortDomain :
               d # e => Members(d)' \cap Members(e)' = {}
        BY ONLY <2>0g, Safety, SafetyMembership
           DEF MembershipSafety, GroupPartition
      <4>3. \A d \in s'.issued : Cardinality(Members(d)') <= MemberCapacity
        <5> SUFFICES ASSUME NEW d \in s'.issued
                     PROVE Cardinality(Members(d)') <= MemberCapacity
          OBVIOUS
        <5>1. d \in s.issued
          BY ONLY <2>0b DEF StateFields
        <5>2. d \in CohortDomain
          BY ONLY <5>1, Safety, SafetyTypeOK DEF TypeOK, CohortStateTypes
        <5>3. Members(d)' = Members(d)
          BY ONLY <2>0g, <5>2
        <5> QED
          BY ONLY <5>1, <5>3, Safety, SafetyMembership
             DEF MembershipSafety, GroupPartition
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF GroupPartition
    <3>4. AuthorityMembership'
      BY ONLY <2>0b, <2>0g, Safety, SafetyMembership
         DEF MembershipSafety, AuthorityMembership, StateFields
    <3>5. TerminalMembership'
      BY ONLY <2>0b, <2>0f, <2>0g, Safety, SafetyMembership,
         FS_AddElement, FS_Subset
         DEF MembershipSafety, TerminalMembership, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>1. PublicationOrder'
      BY ONLY <2>0b, <2>0d, Safety, SafetyPublication, FS_AddElement, FS_Subset
         DEF PublicationSafety, PublicationOrder, StateFields
    <3>2. PublicationExclusion'
      BY ONLY <2>0b, Safety, SafetyPublication
         DEF PublicationSafety, PublicationExclusion, StateFields
    <3>3. PublicationPredecessorOrder'
      BY ONLY <2>0b, <2>0c, Safety, SafetyPublication
         DEF PublicationSafety, PublicationPredecessorOrder, StateFields
    <3>4. PublicationAcknowledgement'
      BY ONLY <2>0b, <2>0g, Safety, SafetyPublication
         DEF PublicationSafety, PublicationAcknowledgement, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY ONLY Safety, SafetyOwnership
    <3>1. s'.owned \subseteq s'.issued
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
             \subseteq Allocated'
      <4>1. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
               \subseteq Allocated
        BY ONLY <3>0 DEF Ownership, CohortsOf, Members, Allocated
      <4>2. s'.owned = s.owned
        BY ONLY <2>0b DEF StateFields
      <4>3. (CohortsOf(s.authority \cup s.exported))' =
               CohortsOf(s.authority \cup s.exported)
        BY ONLY <2>0g
      <4>4. Allocated' = Allocated
        BY ONLY <2>0g
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4
    <3>3. s'.ready \subseteq
             (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
      BY ONLY <2>0b, <3>0, FS_RemoveElement, FS_Subset DEF Ownership, StateFields
    <3>4a. s'.batchBorrow \subseteq s'.owned
      <4>1. s.batchBorrow \subseteq s.owned
        BY ONLY <3>0 DEF Ownership
      <4>2. s'.batchBorrow = s.batchBorrow \cup {c}
        BY ONLY <2>0b
      <4>3. s'.owned = s.owned
        BY ONLY <2>0b DEF StateFields
      <4>4. c \in s.owned
        BY ONLY <2>0d
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4, FS_AddElement, FS_Subset
    <3>4b. s'.headBorrow \subseteq s'.owned
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>4. s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
      BY ONLY <3>4a, <3>4b
    <3>5. s'.batchBorrow \subseteq s'.batchCalls /\
           s'.headBorrow \subseteq s'.headCalls
      BY ONLY <2>0b, <3>0, FS_AddElement, FS_Subset DEF Ownership, StateFields
    <3>6. s'.batchBorrow \cap s'.stored = {} /\
           s'.headBorrow \cap s'.published = {}
      BY ONLY <2>0b, <2>0e, <3>0, FS_AddElement DEF Ownership, StateFields
    <3>7. s'.accepted \subseteq (s'.owned \cap s'.published) \ s'.headBorrow
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>8. s'.unknown \subseteq
             (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9. s'.absent \subseteq s'.headCalls \ s'.headBorrow
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9a. s'.prepareFailed \subseteq s'.owned \ (s'.sealed \cup s'.batchCalls)
      BY ONLY <2>0b, <2>0d, <3>0, FS_AddElement, FS_Subset DEF Ownership, StateFields
    <3>9ab. Batches(s'.prepareFailed) \subseteq s'.prepareCalls \ s'.prepareBorrow
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9aa. s'.batchFailed \subseteq
          (s'.owned \cap s'.batchCalls) \
             (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
      BY ONLY <2>0b, <2>0d, <3>0, FS_AddElement, FS_Subset DEF Ownership, StateFields
    <3>9b. s'.projection \subseteq
          (s'.owned \cap s'.validated) \ s'.abandoned
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9c. s'.headBorrow \cup s'.accepted \subseteq s'.projection
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9d. (s'.unknown \cup s'.absent) \cap s'.projection = {}
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>10. s'.headBorrow # {} => s'.unknown = {}
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>11. ~s'.online =>
          s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
          s'.batchBorrow = {} /\ s'.headBorrow = {} /\ s'.admitted = s'.collected
      BY ONLY <2>0b, <2>0c DEF StateFields
    <3>12a. /\ s'.owned \subseteq s'.issued
              /\ Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
                 \subseteq Allocated'
              /\ s'.ready \subseteq
                   (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
              /\ s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
      BY ONLY <3>1, <3>2, <3>3, <3>4
    <3>12b. /\ s'.batchBorrow \subseteq s'.batchCalls
              /\ s'.headBorrow \subseteq s'.headCalls
              /\ s'.batchBorrow \cap s'.stored = {}
              /\ s'.headBorrow \cap s'.published = {}
              /\ s'.accepted \subseteq
                   (s'.owned \cap s'.published) \ s'.headBorrow
              /\ s'.unknown \subseteq
                   (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
              /\ s'.absent \subseteq s'.headCalls \ s'.headBorrow
      BY ONLY <3>5, <3>6, <3>7, <3>8, <3>9
    <3>12c. /\ s'.prepareFailed \subseteq
                   s'.owned \ (s'.sealed \cup s'.batchCalls)
              /\ Batches(s'.prepareFailed) \subseteq
                   s'.prepareCalls \ s'.prepareBorrow
              /\ s'.batchFailed \subseteq
                   (s'.owned \cap s'.batchCalls) \
                      (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
      BY ONLY <3>9a, <3>9ab, <3>9aa
    <3>12d. /\ s'.projection \subseteq
                   (s'.owned \cap s'.validated) \ s'.abandoned
              /\ s'.headBorrow \cup s'.accepted \subseteq s'.projection
              /\ (s'.unknown \cup s'.absent) \cap s'.projection = {}
              /\ (s'.headBorrow # {} => s'.unknown = {})
              /\ (~s'.online =>
                   s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
                   s'.batchBorrow = {} /\ s'.headBorrow = {} /\
                   s'.admitted = s'.collected)
      BY ONLY <3>9b, <3>9c, <3>9d, <3>10, <3>11
    <3> QED BY ONLY <3>12a, <3>12b, <3>12c, <3>12d
        DEF Ownership, Members, CohortsOf, Allocated
  <2>5. PreparationOwnership'
    <3>0. PreparationOwnership
      BY ONLY Safety, SafetyPreparationOwnership
    <3>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
      BY ONLY <2>0b, <2>0g, <3>0 DEF PreparationOwnership, StateFields
    <3>2. (\A t \in MemberDomain : Fragment(t) \in s.prepareBorrow =>
             Input(t) \in Allocated /\ t \in s.admitted \ BoundMembers)'
      BY ONLY <2>0b, <2>0g, <3>0 DEF PreparationOwnership, StateFields
    <3>3. (\A d \in CohortDomain : Batch(d) \in s.prepareBorrow =>
             d \in s.owned /\ Fragments(Members(d)) \subseteq Allocated)'
      BY ONLY <2>0b, <2>0g, <3>0 DEF PreparationOwnership, StateFields
    <3>4. (\A t \in s.prepared : Fragment(t) \in s.prepareCalls \ s.prepareBorrow)'
      BY ONLY <2>0b, <3>0 DEF PreparationOwnership, StateFields
    <3>5. (\A t \in s.prepared : Input(t) \notin Allocated)'
      BY ONLY <2>0b, <2>0g, <3>0 DEF PreparationOwnership, StateFields
    <3>6. (\A d \in s.sealed : Batch(d) \in s.prepareCalls \ s.prepareBorrow)'
      BY ONLY <2>0b, <3>0 DEF PreparationOwnership, StateFields
    <3>7. (\A t \in MemberDomain : Input(t) \in Allocated =>
             t \in s.pending \/ Fragment(t) \in s.prepareBorrow)'
      BY ONLY <2>0b, <2>0g, <3>0 DEF PreparationOwnership, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF PreparationOwnership
  <2>6. ResourceBounds'
    <3>0. ResourceBounds
      BY ONLY Safety, SafetyResourceBounds
    <3>1. Cardinality(LiveMembers') <= QueueCapacity
      BY ONLY <2>0g, <3>0 DEF ResourceBounds
    <3>2. Cardinality(s'.owned) <= Capacity
      BY ONLY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3>3a. IsFiniteSet(s.ready)
      <4>1. IsFiniteSet(CohortDomain)
        BY ONLY ConstantsOK DEF ConstantsOK
      <4>2. s.ready \subseteq CohortDomain
        BY ONLY Safety, SafetyTypeOK DEF TypeOK, CohortStateTypes
      <4> QED BY ONLY <4>1, <4>2, FS_Subset
    <3>3. Cardinality(s'.ready) <= Capacity
      <4>1. s'.ready \subseteq s.ready
        BY ONLY <2>0b DEF StateFields
      <4>2. /\ IsFiniteSet(s'.ready)
             /\ Cardinality(s'.ready) <= Cardinality(s.ready)
        BY ONLY <3>3a, <4>1, FS_Subset
      <4>3. Cardinality(s.ready) <= Capacity
        BY ONLY <3>0 DEF ResourceBounds
      <4>4. /\ Cardinality(s'.ready) \in Nat
             /\ Cardinality(s.ready) \in Nat
             /\ Capacity \in Nat
        BY ONLY <3>3a, <4>2, ConstantsOK, FS_CardinalityType DEF ConstantsOK
      <4> QED BY ONLY <4>2, <4>3, <4>4
    <3>4. Cardinality(s'.headBorrow) <= 1
      BY ONLY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3>4a. Cardinality(s'.projection) <= 1
      BY ONLY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3>5. Cardinality(s'.prepareBorrow) <= PrepareCapacity
      BY ONLY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3>6. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
      BY ONLY <2>0g, <3>0 DEF ResourceBounds
    <3>7. \A left, right \in Resources : left # right =>
             s'.buffers[left] \cap s'.buffers[right] = {}
      BY ONLY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>4a, <3>5, <3>6, <3>7
        DEF ResourceBounds
  <2>7. AuthoritySafety'
    <3>1. (CohortsOf(s.authority \cup s.exported) \subseteq
             s.headCalls \ s.headBorrow)'
      BY ONLY <2>0b, <2>0g, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3>2. (s.headBorrow \cap s.abandoned = {})'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3>3. (s.unknownEpisode => s.halted)'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3>4. (s.exported \subseteq s.delivered /\ s.delivered \subseteq s.collected)'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3>5. (s.authority \cap s.discarded = {})'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3>6. (s.resolutionWrites = 0)'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6 DEF AuthoritySafety
  <2> QED BY ONLY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1>2. CASE JoinBatch(c, entered)
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0b. /\ DOMAIN s' = StateFields
           /\ s'.batchBorrow = s.batchBorrow \ {c}
           /\ s'.stored = (IF entered THEN s.stored \cup {c} ELSE s.stored)
           /\ s'.batchFailed = (IF entered THEN s.batchFailed ELSE s.batchFailed \cup {c})
           /\ \A field \in StateFields \ {"batchBorrow", "stored", "batchFailed"} :
                s'[field] = s[field]
    BY <1>2, <2>0a, JoinBatchProjection
  <2>0c. /\ c \in s.batchBorrow
           /\ entered \in BOOLEAN
    BY <1>2 DEF JoinBatch
  <2>0d. /\ c \in s.owned
           /\ c \in s.batchCalls
           /\ c \notin s.stored
           /\ c \notin s.batchFailed
    BY <2>0c, SafetyOwnership DEF Ownership
  <2>0e. /\ c \in s.sealed
           /\ c \notin s.headCalls
    BY <2>0d, SafetyPublication DEF PublicationSafety, PublicationOrder
  <2>0f. /\ Allocated' = Allocated
           /\ BoundMembers' = BoundMembers
           /\ LiveMembers' = LiveMembers
           /\ UsedBytes' = UsedBytes
           /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
           /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
           /\ (CohortsOf(s.authority \cup s.exported))' =
                CohortsOf(s.authority \cup s.exported)
           /\ \A d \in CohortDomain : Members(d)' = Members(d)
    BY <2>0b DEF StateFields, Allocated, BoundMembers, LiveMembers, UsedBytes,
       CohortsOf, Members
  <2>1. TypeOK'
    <3>0. TypeOK
      BY ONLY Safety, SafetyTypeOK
    <3>0c. c \in CohortDomain
      BY ONLY <2>0d, <3>0 DEF TypeOK, PublicationStateTypes
    <3>1. StateShape'
      BY ONLY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, MemberStateTypes, StateFields
    <3>3. PreparationMapTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, PreparationMapTypes, StateFields
    <3>4. CohortStateTypes'
      <4>1. s'.stored \subseteq CohortDomain
        BY ONLY <2>0b, <2>0c, <3>0, <3>0c
           DEF TypeOK, CohortStateTypes
      <4>2. s'.batchFailed \subseteq CohortDomain
        BY ONLY <2>0b, <2>0c, <3>0, <3>0c
           DEF TypeOK, CohortStateTypes
      <4>3. /\ s'.sealed \subseteq CohortDomain
             /\ s'.ready \subseteq CohortDomain
             /\ s'.issued \subseteq CohortDomain
             /\ s'.published \subseteq CohortDomain
             /\ s'.retired \subseteq CohortDomain
             /\ s'.excluded \subseteq CohortDomain
             /\ s'.abandoned \subseteq CohortDomain
             /\ s'.prepareFailed \subseteq CohortDomain
             /\ s'.validated \subseteq CohortDomain
             /\ s'.projection \subseteq CohortDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, CohortStateTypes, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF CohortStateTypes
    <3>5. PublicationStateTypes'
      <4>1. s'.batchBorrow \subseteq CohortDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, PublicationStateTypes
      <4>2. /\ s'.batchCalls \subseteq CohortDomain
             /\ s'.headCalls \subseteq CohortDomain
             /\ s'.headBorrow \subseteq CohortDomain
             /\ s'.owned \subseteq CohortDomain
             /\ s'.accepted \subseteq CohortDomain
             /\ s'.unknown \subseteq CohortDomain
             /\ s'.absent \subseteq CohortDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, PublicationStateTypes, StateFields
      <4> QED BY ONLY <4>1, <4>2 DEF PublicationStateTypes
    <3>6. AuthorityStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, AuthorityStateTypes, StateFields
    <3>7. LifecycleStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, LifecycleStateTypes, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>1. AdmissionMembership'
      BY ONLY <2>0b, Safety, SafetyMembership
         DEF MembershipSafety, AdmissionMembership, StateFields
    <3>2. BoundMembership'
      BY ONLY <2>0b, <2>0f, Safety, SafetyMembership
         DEF MembershipSafety, BoundMembership, StateFields
    <3>3. GroupPartition'
      <4>1. \A d \in CohortDomain : d \in s'.issued <=> Members(d)' # {}
        BY ONLY <2>0b, <2>0f, Safety, SafetyMembership
           DEF MembershipSafety, GroupPartition, StateFields
      <4>2. \A d, e \in CohortDomain :
               d # e => Members(d)' \cap Members(e)' = {}
        BY ONLY <2>0f, Safety, SafetyMembership
           DEF MembershipSafety, GroupPartition
      <4>3. \A d \in s'.issued : Cardinality(Members(d)') <= MemberCapacity
        <5> SUFFICES ASSUME NEW d \in s'.issued
                     PROVE Cardinality(Members(d)') <= MemberCapacity
          OBVIOUS
        <5>1. d \in s.issued
          BY ONLY <2>0b DEF StateFields
        <5>2. d \in CohortDomain
          BY ONLY <5>1, Safety, SafetyTypeOK DEF TypeOK, CohortStateTypes
        <5>3. Members(d)' = Members(d)
          BY ONLY <2>0f, <5>2
        <5> QED
          BY ONLY <5>1, <5>3, Safety, SafetyMembership
             DEF MembershipSafety, GroupPartition
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF GroupPartition
    <3>4. AuthorityMembership'
      BY ONLY <2>0b, <2>0f, Safety, SafetyMembership
         DEF MembershipSafety, AuthorityMembership, StateFields
    <3>5. TerminalMembership'
      <4>0. TerminalMembership
        BY ONLY Safety, SafetyMembership DEF MembershipSafety
      <4>1. /\ s'.rejected \cap s'.pending = {}
             /\ s'.collected \cap s'.pending = {}
             /\ s'.delivered \subseteq s'.collected
             /\ s'.discarded \subseteq s'.collected
             /\ s'.delivered \cap s'.discarded = {}
        BY ONLY <2>0b, <4>0 DEF TerminalMembership, StateFields
      <4>2. (CohortsOf(s.collected))' \subseteq s'.headCalls \cup s'.excluded
        BY ONLY <2>0b, <2>0f, <4>0 DEF TerminalMembership, StateFields
      <4>3. (CohortsOf(s.collected))' \cap
               (s'.batchBorrow \cup s'.headBorrow) = {}
        BY ONLY <2>0b, <2>0f, <4>0 DEF TerminalMembership, StateFields
      <4>4. Batches((CohortsOf(s.collected))') \cap s'.prepareBorrow = {}
        BY ONLY <2>0b, <2>0f, <4>0 DEF TerminalMembership, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4 DEF TerminalMembership
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>0. PublicationSafety
      BY ONLY Safety, SafetyPublication
    <3>1. PublicationOrder'
      <4>1. /\ s'.retired \subseteq s'.published
             /\ s'.published \subseteq s'.headCalls
             /\ s'.headCalls \subseteq s'.validated
             /\ s'.batchCalls \subseteq s'.sealed
             /\ s'.sealed \subseteq s'.issued
        BY ONLY <2>0b, <3>0
           DEF PublicationSafety, PublicationOrder, StateFields
      <4>2. s'.validated \subseteq s'.stored
        BY ONLY <2>0b, <3>0
           DEF PublicationSafety, PublicationOrder, StateFields
      <4>3. s'.stored \subseteq s'.batchCalls
        BY ONLY <2>0b, <2>0d, <3>0
           DEF PublicationSafety, PublicationOrder, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF PublicationOrder
    <3>2. PublicationExclusion'
      BY ONLY <2>0b, <3>0
         DEF PublicationSafety, PublicationExclusion, StateFields
    <3>3. PublicationPredecessorOrder'
      BY ONLY <2>0b, <3>0
         DEF PublicationSafety, PublicationPredecessorOrder, StateFields
    <3>4. PublicationAcknowledgement'
      BY ONLY <2>0b, <2>0f, <3>0
         DEF PublicationSafety, PublicationAcknowledgement, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY ONLY Safety, SafetyOwnership
    <3>1. s'.owned \subseteq s'.issued
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
             \subseteq Allocated'
      <4>1. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
               \subseteq Allocated
        BY ONLY <3>0 DEF Ownership, CohortsOf, Members, Allocated
      <4>2. s'.owned = s.owned
        BY ONLY <2>0b DEF StateFields
      <4>3. (CohortsOf(s.authority \cup s.exported))' =
               CohortsOf(s.authority \cup s.exported)
        BY ONLY <2>0f
      <4>4. Allocated' = Allocated
        BY ONLY <2>0f
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4
    <3>3. s'.ready \subseteq
             (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>4a. s'.batchBorrow \subseteq s'.owned
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>4b. s'.headBorrow \subseteq s'.owned
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>4. s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
      BY ONLY <3>4a, <3>4b
    <3>5. s'.batchBorrow \subseteq s'.batchCalls /\
           s'.headBorrow \subseteq s'.headCalls
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>6. s'.batchBorrow \cap s'.stored = {} /\
           s'.headBorrow \cap s'.published = {}
      <4>1. CASE entered
        BY ONLY <4>1, <2>0b, <3>0 DEF Ownership, StateFields
      <4>2. CASE ~entered
        BY ONLY <4>2, <2>0b, <3>0 DEF Ownership, StateFields
      <4> QED BY ONLY <4>1, <4>2
    <3>7. s'.accepted \subseteq (s'.owned \cap s'.published) \ s'.headBorrow
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>8. s'.unknown \subseteq
             (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9. s'.absent \subseteq s'.headCalls \ s'.headBorrow
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9a. s'.prepareFailed \subseteq s'.owned \ (s'.sealed \cup s'.batchCalls)
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9ab. Batches(s'.prepareFailed) \subseteq s'.prepareCalls \ s'.prepareBorrow
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9aa. s'.batchFailed \subseteq
          (s'.owned \cap s'.batchCalls) \
             (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
      <4>0. s.batchFailed \subseteq
          (s.owned \cap s.batchCalls) \
             (s.batchBorrow \cup s.stored \cup s.headCalls)
        BY ONLY <3>0 DEF Ownership
      <4>1. CASE entered
        <5>1. s'.batchFailed = s.batchFailed
          BY ONLY <4>1, <2>0b
        <5>2. s'.batchFailed \subseteq s'.owned \cap s'.batchCalls
          BY ONLY <5>1, <4>0, <2>0b DEF StateFields
        <5>3. s'.batchFailed \cap s'.batchBorrow = {}
          BY ONLY <5>1, <4>0, <2>0b
        <5>4. s'.batchFailed \cap s'.stored = {}
          BY ONLY <4>1, <5>1, <4>0, <2>0b, <2>0d
        <5>5. s'.batchFailed \cap s'.headCalls = {}
          BY ONLY <5>1, <4>0, <2>0b DEF StateFields
        <5> QED BY ONLY <5>2, <5>3, <5>4, <5>5
      <4>2. CASE ~entered
        <5>1. s'.batchFailed = s.batchFailed \cup {c}
          BY ONLY <4>2, <2>0b
        <5>2. s'.batchFailed \subseteq s'.owned \cap s'.batchCalls
          BY ONLY <5>1, <4>0, <2>0b, <2>0d DEF StateFields
        <5>3. s'.batchFailed \cap s'.batchBorrow = {}
          BY ONLY <5>1, <4>0, <2>0b
        <5>4. s'.batchFailed \cap s'.stored = {}
          BY ONLY <4>2, <5>1, <4>0, <2>0b, <2>0d
        <5>5. s'.batchFailed \cap s'.headCalls = {}
          BY ONLY <5>1, <4>0, <2>0b, <2>0e DEF StateFields
        <5> QED BY ONLY <5>2, <5>3, <5>4, <5>5
      <4> QED BY ONLY <4>1, <4>2
    <3>9b. s'.projection \subseteq
          (s'.owned \cap s'.validated) \ s'.abandoned
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9c. s'.headBorrow \cup s'.accepted \subseteq s'.projection
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9d. (s'.unknown \cup s'.absent) \cap s'.projection = {}
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>10. s'.headBorrow # {} => s'.unknown = {}
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>11. ~s'.online =>
          s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
          s'.batchBorrow = {} /\ s'.headBorrow = {} /\ s'.admitted = s'.collected
      <4>1. s.online
        BY ONLY <2>0c, <3>0 DEF Ownership
      <4>2. s'.online = s.online
        BY ONLY <2>0b DEF StateFields
      <4> QED BY ONLY <4>1, <4>2
    <3>12a. /\ s'.owned \subseteq s'.issued
              /\ Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
                 \subseteq Allocated'
              /\ s'.ready \subseteq
                   (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
              /\ s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
      BY ONLY <3>1, <3>2, <3>3, <3>4
    <3>12b. /\ s'.batchBorrow \subseteq s'.batchCalls
              /\ s'.headBorrow \subseteq s'.headCalls
              /\ s'.batchBorrow \cap s'.stored = {}
              /\ s'.headBorrow \cap s'.published = {}
              /\ s'.accepted \subseteq
                   (s'.owned \cap s'.published) \ s'.headBorrow
              /\ s'.unknown \subseteq
                   (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
              /\ s'.absent \subseteq s'.headCalls \ s'.headBorrow
      BY ONLY <3>5, <3>6, <3>7, <3>8, <3>9
    <3>12c. /\ s'.prepareFailed \subseteq
                   s'.owned \ (s'.sealed \cup s'.batchCalls)
              /\ Batches(s'.prepareFailed) \subseteq
                   s'.prepareCalls \ s'.prepareBorrow
              /\ s'.batchFailed \subseteq
                   (s'.owned \cap s'.batchCalls) \
                      (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
      BY ONLY <3>9a, <3>9ab, <3>9aa
    <3>12d. /\ s'.projection \subseteq
                   (s'.owned \cap s'.validated) \ s'.abandoned
              /\ s'.headBorrow \cup s'.accepted \subseteq s'.projection
              /\ (s'.unknown \cup s'.absent) \cap s'.projection = {}
              /\ (s'.headBorrow # {} => s'.unknown = {})
              /\ (~s'.online =>
                   s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
                   s'.batchBorrow = {} /\ s'.headBorrow = {} /\
                   s'.admitted = s'.collected)
      BY ONLY <3>9b, <3>9c, <3>9d, <3>10, <3>11
    <3> QED BY ONLY <3>12a, <3>12b, <3>12c, <3>12d
        DEF Ownership, Members, CohortsOf, Allocated
  <2>5. PreparationOwnership'
    BY <2>0b, <2>0f, SafetyPreparationOwnership
       DEF PreparationOwnership, StateFields
  <2>6. ResourceBounds'
    BY <2>0b, <2>0f, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>7. AuthoritySafety'
    BY <2>0b, <2>0f, SafetyAuthority DEF AuthoritySafety, StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1>3. CASE StartHead(c)
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0b. /\ DOMAIN s' = StateFields
           /\ s'.headCalls = s.headCalls \cup {c}
           /\ s'.headBorrow = {c}
           /\ \A field \in StateFields \ {"headCalls", "headBorrow"} :
                s'[field] = s[field]
    BY <1>3, <2>0a, StartHeadProjection
  <2>0c. /\ s.online
           /\ ~s.halted
           /\ ~s.fenced
           /\ s.unknown = {}
           /\ s.headBorrow = {}
           /\ c \in s.owned \cap s.stored \cap s.validated
           /\ c \notin s.headCalls \cup s.batchBorrow \cup s.abandoned
           /\ s.projection = {c}
           /\ Earlier(c) \subseteq s.retired
    BY <1>3 DEF StartHead
  <2>0d0. s.absent \subseteq s.headCalls
    BY ONLY Safety, SafetyOwnership DEF Ownership
  <2>0d. /\ c \in s.batchCalls
           /\ c \in s.sealed
           /\ c \in s.issued
           /\ c \notin s.published
           /\ c \notin s.absent
           /\ c \notin s.excluded
    BY ONLY <2>0c, <2>0d0, Safety, SafetyPublication
       DEF PublicationSafety, PublicationOrder,
       PublicationExclusion
  <2>0e. /\ s.accepted = {}
           /\ c \notin s.batchFailed
    BY <2>0c, <2>0d, SafetyOwnership DEF Ownership
  <2>0f. c \notin CohortsOf(s.collected)
    BY <2>0c, <2>0d, SafetyMembership, SafetyPublication
       DEF MembershipSafety, TerminalMembership, PublicationSafety, PublicationExclusion
  <2>0g. /\ Allocated' = Allocated
           /\ BoundMembers' = BoundMembers
           /\ LiveMembers' = LiveMembers
           /\ UsedBytes' = UsedBytes
           /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
           /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
           /\ (CohortsOf(s.authority \cup s.exported))' =
                CohortsOf(s.authority \cup s.exported)
           /\ \A d \in CohortDomain : Members(d)' = Members(d)
    BY <2>0b DEF StateFields, Allocated, BoundMembers, LiveMembers, UsedBytes,
       CohortsOf, Members
  <2>1. TypeOK'
    <3>0. TypeOK
      BY ONLY Safety, SafetyTypeOK
    <3>0c. c \in CohortDomain
      BY ONLY <2>0c, <3>0 DEF TypeOK, PublicationStateTypes
    <3>1. StateShape'
      BY ONLY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, MemberStateTypes, StateFields
    <3>3. PreparationMapTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, PreparationMapTypes, StateFields
    <3>4. CohortStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, CohortStateTypes, StateFields
    <3>5. PublicationStateTypes'
      <4>1. s'.headCalls \subseteq CohortDomain
        BY ONLY <2>0b, <3>0, <3>0c DEF TypeOK, PublicationStateTypes
      <4>2. s'.headBorrow \subseteq CohortDomain
        BY ONLY <2>0b, <3>0c
      <4>3. /\ s'.batchCalls \subseteq CohortDomain
             /\ s'.batchBorrow \subseteq CohortDomain
             /\ s'.owned \subseteq CohortDomain
             /\ s'.accepted \subseteq CohortDomain
             /\ s'.unknown \subseteq CohortDomain
             /\ s'.absent \subseteq CohortDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, PublicationStateTypes, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF PublicationStateTypes
    <3>6. AuthorityStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, AuthorityStateTypes, StateFields
    <3>7. LifecycleStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, LifecycleStateTypes, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>1. AdmissionMembership'
      BY ONLY <2>0b, Safety, SafetyMembership
         DEF MembershipSafety, AdmissionMembership, StateFields
    <3>2. BoundMembership'
      BY ONLY <2>0b, <2>0g, Safety, SafetyMembership
         DEF MembershipSafety, BoundMembership, StateFields
    <3>3. GroupPartition'
      <4>1. \A d \in CohortDomain : d \in s'.issued <=> Members(d)' # {}
        BY ONLY <2>0b, <2>0g, Safety, SafetyMembership
           DEF MembershipSafety, GroupPartition, StateFields
      <4>2. \A d, e \in CohortDomain :
               d # e => Members(d)' \cap Members(e)' = {}
        BY ONLY <2>0g, Safety, SafetyMembership
           DEF MembershipSafety, GroupPartition
      <4>3. \A d \in s'.issued : Cardinality(Members(d)') <= MemberCapacity
        <5> SUFFICES ASSUME NEW d \in s'.issued
                     PROVE Cardinality(Members(d)') <= MemberCapacity
          OBVIOUS
        <5>1. d \in s.issued
          BY ONLY <2>0b DEF StateFields
        <5>2. d \in CohortDomain
          BY ONLY <5>1, Safety, SafetyTypeOK DEF TypeOK, CohortStateTypes
        <5>3. Members(d)' = Members(d)
          BY ONLY <2>0g, <5>2
        <5> QED
          BY ONLY <5>1, <5>3, Safety, SafetyMembership
             DEF MembershipSafety, GroupPartition
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF GroupPartition
    <3>4. AuthorityMembership'
      BY ONLY <2>0b, <2>0g, Safety, SafetyMembership
         DEF MembershipSafety, AuthorityMembership, StateFields
    <3>5. TerminalMembership'
      <4>0. TerminalMembership
        BY ONLY Safety, SafetyMembership DEF MembershipSafety
      <4>1. /\ s'.rejected \cap s'.pending = {}
             /\ s'.collected \cap s'.pending = {}
             /\ s'.delivered \subseteq s'.collected
             /\ s'.discarded \subseteq s'.collected
             /\ s'.delivered \cap s'.discarded = {}
        BY ONLY <2>0b, <4>0 DEF TerminalMembership, StateFields
      <4>2. (CohortsOf(s.collected))' \subseteq s'.headCalls \cup s'.excluded
        BY ONLY <2>0b, <2>0g, <4>0 DEF TerminalMembership, StateFields
      <4>3. (CohortsOf(s.collected))' \cap
               (s'.batchBorrow \cup s'.headBorrow) = {}
        BY ONLY <2>0b, <2>0f, <2>0g, <4>0
           DEF TerminalMembership, StateFields
      <4>4. Batches((CohortsOf(s.collected))') \cap s'.prepareBorrow = {}
        BY ONLY <2>0b, <2>0g, <4>0 DEF TerminalMembership, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4 DEF TerminalMembership
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>0. PublicationSafety
      BY ONLY Safety, SafetyPublication
    <3>1. PublicationOrder'
      <4>1. /\ s'.retired \subseteq s'.published
             /\ s'.validated \subseteq s'.stored
             /\ s'.stored \subseteq s'.batchCalls
             /\ s'.batchCalls \subseteq s'.sealed
             /\ s'.sealed \subseteq s'.issued
        BY ONLY <2>0b, <3>0
           DEF PublicationSafety, PublicationOrder, StateFields
      <4>2. s'.published \subseteq s'.headCalls
        BY ONLY <2>0b, <3>0
           DEF PublicationSafety, PublicationOrder, StateFields
      <4>3. s'.headCalls \subseteq s'.validated
        BY ONLY <2>0b, <2>0c, <3>0
           DEF PublicationSafety, PublicationOrder, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF PublicationOrder
    <3>2. PublicationExclusion'
      BY ONLY <2>0b, <3>0
         DEF PublicationSafety, PublicationExclusion, StateFields
    <3>3. PublicationPredecessorOrder'
      <4> SUFFICES ASSUME NEW d \in s'.headCalls
                   PROVE Earlier(d) \subseteq s'.retired
        BY DEF PublicationPredecessorOrder
      <4>1. CASE d = c
        BY ONLY <4>1, <2>0b, <2>0c DEF StateFields
      <4>2. CASE d # c
        <5>1. d \in s.headCalls
          BY ONLY <4>2, <2>0b
        <5> QED BY ONLY <5>1, <2>0b, <3>0
            DEF PublicationSafety, PublicationPredecessorOrder, StateFields
      <4> QED BY ONLY <4>1, <4>2
    <3>4. PublicationAcknowledgement'
      BY ONLY <2>0b, <2>0g, <3>0
         DEF PublicationSafety, PublicationAcknowledgement, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY ONLY Safety, SafetyOwnership
    <3>1. s'.owned \subseteq s'.issued
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
             \subseteq Allocated'
      <4>1. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
               \subseteq Allocated
        BY ONLY <3>0 DEF Ownership, CohortsOf, Members, Allocated
      <4>2. s'.owned = s.owned
        BY ONLY <2>0b DEF StateFields
      <4>3. (CohortsOf(s.authority \cup s.exported))' =
               CohortsOf(s.authority \cup s.exported)
        BY ONLY <2>0g
      <4>4. Allocated' = Allocated
        BY ONLY <2>0g
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4
    <3>3. s'.ready \subseteq
             (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>4a. s'.batchBorrow \subseteq s'.owned
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>4b. s'.headBorrow \subseteq s'.owned
      BY ONLY <2>0b, <2>0c DEF StateFields
    <3>4. s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
      BY ONLY <3>4a, <3>4b
    <3>5. s'.batchBorrow \subseteq s'.batchCalls /\
           s'.headBorrow \subseteq s'.headCalls
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>6. s'.batchBorrow \cap s'.stored = {} /\
           s'.headBorrow \cap s'.published = {}
      BY ONLY <2>0b, <2>0d, <3>0 DEF Ownership, StateFields
    <3>7. s'.accepted \subseteq (s'.owned \cap s'.published) \ s'.headBorrow
      BY ONLY <2>0b, <2>0e DEF StateFields
    <3>8. s'.unknown \subseteq
             (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
      BY ONLY <2>0b, <2>0c DEF StateFields
    <3>9. s'.absent \subseteq s'.headCalls \ s'.headBorrow
      BY ONLY <2>0b, <2>0d0, <2>0d DEF StateFields
    <3>9a. s'.prepareFailed \subseteq s'.owned \ (s'.sealed \cup s'.batchCalls)
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9ab. Batches(s'.prepareFailed) \subseteq s'.prepareCalls \ s'.prepareBorrow
      BY ONLY <2>0b, <2>0g, <3>0 DEF Ownership, StateFields
    <3>9aa. s'.batchFailed \subseteq
          (s'.owned \cap s'.batchCalls) \
             (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
      <4>1. s.batchFailed \subseteq
          (s.owned \cap s.batchCalls) \
             (s.batchBorrow \cup s.stored \cup s.headCalls)
        BY ONLY <3>0 DEF Ownership
      <4>2. s'.batchFailed \subseteq
          (s'.owned \cap s'.batchCalls) \ (s'.batchBorrow \cup s'.stored)
        BY ONLY <2>0b, <4>1 DEF StateFields
      <4>3. s'.batchFailed \cap s'.headCalls = {}
        BY ONLY <2>0b, <2>0e, <4>1 DEF StateFields
      <4> QED BY ONLY <4>2, <4>3
    <3>9b. s'.projection \subseteq
          (s'.owned \cap s'.validated) \ s'.abandoned
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9c. s'.headBorrow \cup s'.accepted \subseteq s'.projection
      BY ONLY <2>0b, <2>0c, <2>0e DEF StateFields
    <3>9d. (s'.unknown \cup s'.absent) \cap s'.projection = {}
      BY ONLY <2>0b, <2>0c, <2>0d, <3>0 DEF Ownership, StateFields
    <3>10. s'.headBorrow # {} => s'.unknown = {}
      BY ONLY <2>0b, <2>0c DEF StateFields
    <3>11. ~s'.online =>
          s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
          s'.batchBorrow = {} /\ s'.headBorrow = {} /\ s'.admitted = s'.collected
      BY ONLY <2>0b, <2>0c DEF StateFields
    <3>12a. /\ s'.owned \subseteq s'.issued
              /\ Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
                 \subseteq Allocated'
              /\ s'.ready \subseteq
                   (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
              /\ s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
      BY ONLY <3>1, <3>2, <3>3, <3>4
    <3>12b. /\ s'.batchBorrow \subseteq s'.batchCalls
              /\ s'.headBorrow \subseteq s'.headCalls
              /\ s'.batchBorrow \cap s'.stored = {}
              /\ s'.headBorrow \cap s'.published = {}
              /\ s'.accepted \subseteq
                   (s'.owned \cap s'.published) \ s'.headBorrow
              /\ s'.unknown \subseteq
                   (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
              /\ s'.absent \subseteq s'.headCalls \ s'.headBorrow
      BY ONLY <3>5, <3>6, <3>7, <3>8, <3>9
    <3>12c. /\ s'.prepareFailed \subseteq
                   s'.owned \ (s'.sealed \cup s'.batchCalls)
              /\ Batches(s'.prepareFailed) \subseteq
                   s'.prepareCalls \ s'.prepareBorrow
              /\ s'.batchFailed \subseteq
                   (s'.owned \cap s'.batchCalls) \
                      (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
      BY ONLY <3>9a, <3>9ab, <3>9aa
    <3>12d. /\ s'.projection \subseteq
                   (s'.owned \cap s'.validated) \ s'.abandoned
              /\ s'.headBorrow \cup s'.accepted \subseteq s'.projection
              /\ (s'.unknown \cup s'.absent) \cap s'.projection = {}
              /\ (s'.headBorrow # {} => s'.unknown = {})
              /\ (~s'.online =>
                   s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
                   s'.batchBorrow = {} /\ s'.headBorrow = {} /\
                   s'.admitted = s'.collected)
      BY ONLY <3>9b, <3>9c, <3>9d, <3>10, <3>11
    <3> QED BY ONLY <3>12a, <3>12b, <3>12c, <3>12d
        DEF Ownership, Members, CohortsOf, Allocated
  <2>5. PreparationOwnership'
    BY <2>0b, <2>0g, SafetyPreparationOwnership
       DEF PreparationOwnership, StateFields
  <2>6. ResourceBounds'
    BY <2>0b, <2>0g, SafetyResourceBounds, FS_Singleton, FS_CardinalityType
       DEF ResourceBounds, StateFields
  <2>7. AuthoritySafety'
    <3>1. (CohortsOf(s.authority \cup s.exported) \subseteq
             s.headCalls \ s.headBorrow)'
      <4>1. CohortsOf(s.authority \cup s.exported) \subseteq s.headCalls
        BY ONLY Safety, SafetyAuthority DEF AuthoritySafety
      <4>2. c \notin CohortsOf(s.authority \cup s.exported)
        BY ONLY <4>1, <2>0c
      <4>3. (CohortsOf(s.authority \cup s.exported))' \subseteq s'.headCalls
        BY ONLY <4>1, <2>0b, <2>0g
      <4>4. (CohortsOf(s.authority \cup s.exported))' \cap s'.headBorrow = {}
        BY ONLY <4>2, <2>0b, <2>0g
      <4> QED BY ONLY <4>3, <4>4
    <3>2. (s.headBorrow \cap s.abandoned = {})'
      BY ONLY <2>0b, <2>0c DEF StateFields
    <3>3. (s.unknownEpisode => s.halted)'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3>4. (s.exported \subseteq s.delivered /\ s.delivered \subseteq s.collected)'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3>5. (s.authority \cap s.discarded = {})'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3>6. (s.resolutionWrites = 0)'
      BY ONLY <2>0b, Safety, SafetyAuthority DEF AuthoritySafety, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6 DEF AuthoritySafety
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1>3a. CASE ValidateFront(c, entered)
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0b. /\ DOMAIN s' = StateFields
           /\ s'.validated = (IF entered THEN s.validated \cup {c} ELSE s.validated)
           /\ s'.projection = (IF entered THEN {c} ELSE {})
           /\ s'.abandoned = (IF entered THEN s.abandoned ELSE s.abandoned \cup {c})
           /\ s'.halted = (s.halted \/ ~entered)
           /\ \A field \in StateFields \ {"validated", "projection", "abandoned", "halted"} :
                s'[field] = s[field]
    BY <1>3a, <2>0a, ValidateFrontProjection
  <2>0c. /\ s.online
           /\ ~s.halted
           /\ ~s.fenced
           /\ entered \in BOOLEAN
           /\ c \in s.owned \cap s.stored
           /\ c \notin s.headCalls \cup s.batchBorrow \cup s.abandoned
           /\ Earlier(c) \subseteq s.retired
           /\ s.headBorrow = {}
           /\ s.projection = {}
    BY <1>3a DEF ValidateFront
  <2>0d. /\ c \in s.batchCalls
           /\ c \in s.sealed
           /\ c \in s.issued
           /\ c \notin s.published
    BY <2>0c, SafetyPublication DEF PublicationSafety, PublicationOrder
  <2>0e. /\ s.accepted = {}
           /\ c \notin s.unknown
           /\ c \notin s.absent
           /\ c \notin s.ready
    BY <2>0c, <2>0d, SafetyOwnership DEF Ownership
  <2>0f. /\ Allocated' = Allocated
           /\ BoundMembers' = BoundMembers
           /\ LiveMembers' = LiveMembers
           /\ UsedBytes' = UsedBytes
           /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
           /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
           /\ (CohortsOf(s.authority \cup s.exported))' =
                CohortsOf(s.authority \cup s.exported)
           /\ \A d \in CohortDomain : Members(d)' = Members(d)
    BY <2>0b DEF StateFields, Allocated, BoundMembers, LiveMembers, UsedBytes,
       CohortsOf, Members
  <2>1. TypeOK'
    <3>0. TypeOK
      BY ONLY Safety, SafetyTypeOK
    <3>1. StateShape'
      BY ONLY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, MemberStateTypes, StateFields
    <3>3. PreparationMapTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, PreparationMapTypes, StateFields
    <3>4. CohortStateTypes'
      <4>1. /\ s'.sealed \subseteq CohortDomain
             /\ s'.ready \subseteq CohortDomain
             /\ s'.issued \subseteq CohortDomain
             /\ s'.stored \subseteq CohortDomain
             /\ s'.published \subseteq CohortDomain
             /\ s'.retired \subseteq CohortDomain
             /\ s'.excluded \subseteq CohortDomain
             /\ s'.prepareFailed \subseteq CohortDomain
             /\ s'.batchFailed \subseteq CohortDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, CohortStateTypes, StateFields
      <4>2. s'.abandoned \subseteq CohortDomain
        <5>1. CASE entered
          BY ONLY <5>1, <2>0b, <3>0 DEF TypeOK, CohortStateTypes
        <5>2. CASE ~entered
          BY ONLY <5>2, <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
             DEF TypeOK, CohortStateTypes
        <5> QED BY ONLY <5>1, <5>2
      <4>3. s'.validated \subseteq CohortDomain
        <5>1. CASE entered
          BY ONLY <5>1, <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
             DEF TypeOK, CohortStateTypes
        <5>2. CASE ~entered
          BY ONLY <5>2, <2>0b, <3>0 DEF TypeOK, CohortStateTypes
        <5> QED BY ONLY <5>1, <5>2
      <4>4. s'.projection \subseteq CohortDomain
        <5>1. CASE entered
          BY ONLY <5>1, <2>0b, <2>0c, FS_Singleton
        <5>2. CASE ~entered
          BY ONLY <5>2, <2>0b, FS_EmptySet
        <5> QED BY ONLY <5>1, <5>2
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4 DEF CohortStateTypes
    <3>5. PublicationStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, PublicationStateTypes, StateFields
    <3>6. AuthorityStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, AuthorityStateTypes, StateFields
    <3>7. LifecycleStateTypes'
      BY ONLY <2>0b, <2>0c, <3>0 DEF TypeOK, LifecycleStateTypes, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>1. AdmissionMembership'
      BY ONLY <2>0b, Safety, SafetyMembership
         DEF MembershipSafety, AdmissionMembership, StateFields
    <3>2. BoundMembership'
      BY ONLY <2>0b, <2>0f, Safety, SafetyMembership
         DEF MembershipSafety, BoundMembership, StateFields
    <3>3. GroupPartition'
      <4>0. GroupPartition
        BY ONLY Safety, SafetyMembership
           DEF MembershipSafety
      <4>1. (\A d \in CohortDomain : (d \in s.issued <=> Members(d) # {}))'
        BY ONLY <2>0b, <2>0f, <4>0
           DEF GroupPartition, Members, StateFields
      <4>2. (\A d, e \in CohortDomain :
                 d # e => Members(d) \cap Members(e) = {})'
        BY ONLY <2>0f, <4>0 DEF GroupPartition, Members
      <4>3. (\A d \in s.issued : Cardinality(Members(d)) <= MemberCapacity)'
        BY ONLY <2>0b, <2>0f, <4>0
           DEF GroupPartition, Members, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF GroupPartition
    <3>4. AuthorityMembership'
      BY ONLY <2>0b, <2>0f, Safety, SafetyMembership
         DEF MembershipSafety, AuthorityMembership, StateFields
    <3>5. TerminalMembership'
      BY ONLY <2>0b, <2>0f, Safety, SafetyMembership
         DEF MembershipSafety, TerminalMembership, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>0. PublicationSafety
      BY ONLY Safety, SafetyPublication
    <3>1. PublicationOrder'
      <4>1. /\ s'.retired \subseteq s'.published
             /\ s'.published \subseteq s'.headCalls
             /\ s'.stored \subseteq s'.batchCalls
             /\ s'.batchCalls \subseteq s'.sealed
             /\ s'.sealed \subseteq s'.issued
        BY ONLY <2>0b, <3>0
           DEF PublicationSafety, PublicationOrder, StateFields
      <4>2. s'.headCalls \subseteq s'.validated
        BY ONLY <2>0b, <3>0, FS_AddElement, FS_Subset
           DEF PublicationSafety, PublicationOrder, StateFields
      <4>3. s'.validated \subseteq s'.stored
        <5>1. CASE entered
          BY ONLY <5>1, <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
             DEF PublicationSafety, PublicationOrder, StateFields
        <5>2. CASE ~entered
          BY ONLY <5>2, <2>0b, <3>0
             DEF PublicationSafety, PublicationOrder, StateFields
        <5> QED BY ONLY <5>1, <5>2
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF PublicationOrder
    <3>2. PublicationExclusion'
      BY ONLY <2>0b, <2>0d, <3>0, FS_AddElement
         DEF PublicationSafety, PublicationExclusion, StateFields
    <3>3. PublicationPredecessorOrder'
      BY ONLY <2>0b, <3>0
         DEF PublicationSafety, PublicationPredecessorOrder, StateFields
    <3>4. PublicationAcknowledgement'
      BY ONLY <2>0b, <2>0f, <3>0
         DEF PublicationSafety, PublicationAcknowledgement, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY ONLY Safety, SafetyOwnership
    <3>1. CASE entered
      <4>1. /\ s'.owned \subseteq s'.issued
             /\ Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
                \subseteq Allocated'
             /\ s'.ready \subseteq
                  (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
             /\ s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
             /\ s'.batchBorrow \subseteq s'.batchCalls
             /\ s'.headBorrow \subseteq s'.headCalls
             /\ s'.batchBorrow \cap s'.stored = {}
             /\ s'.headBorrow \cap s'.published = {}
        <5>1. s'.owned \subseteq s'.issued
          BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
        <5>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
                 \subseteq Allocated'
          BY ONLY <2>0b, <2>0f, <3>0 DEF Ownership, StateFields
        <5>3. s'.ready \subseteq
                 (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
          BY ONLY <2>0b, <3>1, <3>0 DEF Ownership, StateFields
        <5>4. s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
          BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
        <5>5. /\ s'.batchBorrow \subseteq s'.batchCalls
               /\ s'.headBorrow \subseteq s'.headCalls
          BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
        <5>6. /\ s'.batchBorrow \cap s'.stored = {}
               /\ s'.headBorrow \cap s'.published = {}
          BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
        <5> QED BY ONLY <5>1, <5>2, <5>3, <5>4, <5>5, <5>6
      <4>2. /\ s'.accepted \subseteq
                  (s'.owned \cap s'.published) \ s'.headBorrow
             /\ s'.unknown \subseteq
                  (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
             /\ s'.absent \subseteq s'.headCalls \ s'.headBorrow
             /\ s'.prepareFailed \subseteq
                  s'.owned \ (s'.sealed \cup s'.batchCalls)
             /\ Batches(s'.prepareFailed) \subseteq
                  s'.prepareCalls \ s'.prepareBorrow
             /\ s'.batchFailed \subseteq
                  (s'.owned \cap s'.batchCalls) \
                     (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
        BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
      <4>3. /\ s'.projection \subseteq
                  (s'.owned \cap s'.validated) \ s'.abandoned
             /\ s'.headBorrow \cup s'.accepted \subseteq s'.projection
             /\ (s'.unknown \cup s'.absent) \cap s'.projection = {}
             /\ (s'.headBorrow # {} => s'.unknown = {})
        BY ONLY <3>1, <2>0b, <2>0c, <2>0d, <2>0e, <3>0,
           FS_AddElement, FS_EmptySet, FS_Singleton
           DEF Ownership, StateFields
      <4>4. ~s'.online =>
             s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
             s'.batchBorrow = {} /\ s'.headBorrow = {} /\
             s'.admitted = s'.collected
        BY ONLY <2>0b, <2>0c DEF StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4 DEF Ownership
    <3>2. CASE ~entered
      <4>1. /\ s'.owned \subseteq s'.issued
             /\ Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
                \subseteq Allocated'
             /\ s'.ready \subseteq
                  (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
             /\ s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
             /\ s'.batchBorrow \subseteq s'.batchCalls
             /\ s'.headBorrow \subseteq s'.headCalls
             /\ s'.batchBorrow \cap s'.stored = {}
             /\ s'.headBorrow \cap s'.published = {}
        <5>1. s'.owned \subseteq s'.issued
          BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
        <5>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
                 \subseteq Allocated'
          BY ONLY <2>0b, <2>0f, <3>0 DEF Ownership, StateFields
        <5>3. s'.ready \subseteq
                 (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
          BY ONLY <3>2, <2>0b, <2>0e, <3>0, FS_AddElement
             DEF Ownership, StateFields
        <5>4. s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
          BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
        <5>5. /\ s'.batchBorrow \subseteq s'.batchCalls
               /\ s'.headBorrow \subseteq s'.headCalls
          BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
        <5>6. /\ s'.batchBorrow \cap s'.stored = {}
               /\ s'.headBorrow \cap s'.published = {}
          BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
        <5> QED BY ONLY <5>1, <5>2, <5>3, <5>4, <5>5, <5>6
      <4>2. /\ s'.accepted \subseteq
                  (s'.owned \cap s'.published) \ s'.headBorrow
             /\ s'.unknown \subseteq
                  (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
             /\ s'.absent \subseteq s'.headCalls \ s'.headBorrow
             /\ s'.prepareFailed \subseteq
                  s'.owned \ (s'.sealed \cup s'.batchCalls)
             /\ Batches(s'.prepareFailed) \subseteq
                  s'.prepareCalls \ s'.prepareBorrow
             /\ s'.batchFailed \subseteq
                  (s'.owned \cap s'.batchCalls) \
                     (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
        BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
      <4>3. /\ s'.projection \subseteq
                  (s'.owned \cap s'.validated) \ s'.abandoned
             /\ s'.headBorrow \cup s'.accepted \subseteq s'.projection
             /\ (s'.unknown \cup s'.absent) \cap s'.projection = {}
             /\ (s'.headBorrow # {} => s'.unknown = {})
        BY ONLY <3>2, <2>0b, <2>0c, <2>0e, <3>0,
           FS_AddElement, FS_EmptySet DEF Ownership, StateFields
      <4>4. ~s'.online =>
             s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
             s'.batchBorrow = {} /\ s'.headBorrow = {} /\
             s'.admitted = s'.collected
        BY ONLY <2>0b, <2>0c DEF StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4 DEF Ownership
    <3> QED BY ONLY <3>1, <3>2
  <2>5. PreparationOwnership'
    <3>0. PreparationOwnership
      BY ONLY Safety, SafetyPreparationOwnership
    <3>1. (s.prepareBorrow \subseteq s.prepareCalls \cap Allocated)'
      BY ONLY <2>0b, <2>0f, <3>0 DEF PreparationOwnership, StateFields
    <3>2. (\A t \in MemberDomain : Fragment(t) \in s.prepareBorrow =>
             Input(t) \in Allocated /\ t \in s.admitted \ BoundMembers)'
      BY ONLY <2>0b, <2>0f, <3>0 DEF PreparationOwnership, StateFields
    <3>3. (\A d \in CohortDomain : Batch(d) \in s.prepareBorrow =>
             d \in s.owned /\ Fragments(Members(d)) \subseteq Allocated)'
      BY ONLY <2>0b, <2>0f, <3>0 DEF PreparationOwnership, StateFields
    <3>4. (\A t \in s.prepared : Fragment(t) \in s.prepareCalls \ s.prepareBorrow)'
      BY ONLY <2>0b, <3>0 DEF PreparationOwnership, StateFields
    <3>5. (\A t \in s.prepared : Input(t) \notin Allocated)'
      BY ONLY <2>0b, <2>0f, <3>0 DEF PreparationOwnership, StateFields
    <3>6. (\A d \in s.sealed : Batch(d) \in s.prepareCalls \ s.prepareBorrow)'
      BY ONLY <2>0b, <3>0 DEF PreparationOwnership, StateFields
    <3>7. (\A t \in MemberDomain : Input(t) \in Allocated =>
             t \in s.pending \/ Fragment(t) \in s.prepareBorrow)'
      BY ONLY <2>0b, <2>0f, <3>0 DEF PreparationOwnership, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF PreparationOwnership
  <2>6. ResourceBounds'
    BY <2>0b, <2>0f, SafetyResourceBounds, FS_EmptySet, FS_Singleton,
       FS_CardinalityType
       DEF ResourceBounds, StateFields
  <2>7. AuthoritySafety'
    <3>0. AuthoritySafety
      BY ONLY Safety, SafetyAuthority
    <3>1. (CohortsOf(s.authority \cup s.exported) \subseteq
             s.headCalls \ s.headBorrow)'
      BY ONLY <2>0b, <2>0f, <3>0 DEF AuthoritySafety, StateFields
    <3>2. (s.headBorrow \cap s.abandoned = {})'
      BY ONLY <2>0b, <2>0c DEF StateFields
    <3>3. (s.unknownEpisode => s.halted)'
      BY ONLY <2>0b, <3>0 DEF AuthoritySafety, StateFields
    <3>4. (s.exported \subseteq s.delivered /\ s.delivered \subseteq s.collected)'
      BY ONLY <2>0b, <3>0 DEF AuthoritySafety, StateFields
    <3>5. (s.authority \cap s.discarded = {})'
      BY ONLY <2>0b, <3>0 DEF AuthoritySafety, StateFields
    <3>6. (s.resolutionWrites = 0)'
      BY ONLY <2>0b, <3>0 DEF AuthoritySafety, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6 DEF AuthoritySafety
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1>4. CASE JoinHead(c, entered, uncertain)
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0b. /\ DOMAIN s' = StateFields
           /\ s'.headBorrow = {}
           /\ s'.projection = (IF entered /\ ~uncertain THEN s.projection ELSE {})
           /\ s'.published = (IF entered THEN s.published \cup {c} ELSE s.published)
           /\ s'.accepted =
                (IF entered /\ ~uncertain THEN s.accepted \cup {c} ELSE s.accepted)
           /\ s'.unknown = (IF uncertain THEN s.unknown \cup {c} ELSE s.unknown)
           /\ s'.authority =
                (IF uncertain THEN s.authority \cup Members(c) ELSE s.authority)
           /\ s'.absent =
                (IF ~entered /\ ~uncertain THEN s.absent \cup {c} ELSE s.absent)
           /\ s'.abandoned =
                (IF ~entered /\ ~uncertain THEN s.abandoned \cup {c} ELSE s.abandoned)
           /\ s'.unknownEpisode = (s.unknownEpisode \/ uncertain)
           /\ s'.halted = (s.halted \/ uncertain \/ ~entered)
           /\ s'.fenced = (s.fenced \/ (~entered /\ ~uncertain))
           /\ \A field \in StateFields \
                {"headBorrow", "projection", "published", "accepted", "unknown",
                 "authority", "absent", "abandoned", "unknownEpisode", "halted", "fenced"} :
                s'[field] = s[field]
    BY <1>4, <2>0a, JoinHeadProjection
  <2>0c. /\ c \in s.headBorrow
           /\ entered \in BOOLEAN
           /\ uncertain \in BOOLEAN
    BY <1>4 DEF JoinHead
  <2>0d. /\ c \in s.owned
           /\ c \in s.headCalls
           /\ c \notin s.published
           /\ c \notin s.accepted
           /\ c \notin s.absent
           /\ c \in s.projection
           /\ s.unknown = {}
    BY <2>0c, SafetyOwnership DEF Ownership
  <2>0e. /\ s.projection = {c}
           /\ s.accepted = {}
    <3>1. IsFiniteSet(CohortDomain)
      BY ONLY ConstantsOK DEF ConstantsOK
    <3>2. s.projection \subseteq CohortDomain
      BY ONLY Safety, SafetyTypeOK DEF TypeOK, CohortStateTypes
    <3>3. IsFiniteSet(s.projection)
      BY ONLY <3>1, <3>2, FS_Subset
    <3>4. {c} \subseteq s.projection
      BY ONLY <2>0d
    <3>5. /\ Cardinality({c}) = 1
           /\ Cardinality(s.projection) <= 1
      BY ONLY <2>0c, Safety, SafetyResourceBounds, FS_Singleton
         DEF ResourceBounds
    <3>6. Cardinality({c}) = Cardinality(s.projection)
      BY ONLY <3>3, <3>4, <3>5, FS_Subset, FS_CardinalityType
    <3>7. s.projection = {c}
      BY ONLY <3>3, <3>4, <3>6, FS_Subset
    <3>8. s.accepted = {}
      BY ONLY <2>0d, <3>7, Safety, SafetyOwnership DEF Ownership
    <3> QED BY ONLY <3>7, <3>8
  <2>0f. /\ c \in s.validated
           /\ c \in s.stored
           /\ c \in s.batchCalls
           /\ c \in s.sealed
           /\ c \in s.issued
           /\ Earlier(c) \subseteq s.retired
           /\ c \notin s.excluded
    BY <2>0d, SafetyPublication DEF PublicationSafety, PublicationOrder,
       PublicationPredecessorOrder, PublicationExclusion
  <2>0g. /\ c \notin s.abandoned
           /\ c \notin CohortsOf(s.collected)
           /\ Members(c) \subseteq BoundMembers
           /\ Members(c) \subseteq MemberDomain
    <3>1. c \notin s.abandoned
      BY ONLY <2>0c, Safety, SafetyAuthority DEF AuthoritySafety
    <3>2. c \notin CohortsOf(s.collected)
      BY ONLY <2>0c, Safety, SafetyMembership
         DEF MembershipSafety, TerminalMembership, CohortsOf, Members
    <3>3. Members(c) \subseteq BoundMembers
      BY ONLY <2>0f DEF BoundMembers
    <3>4. Members(c) \subseteq MemberDomain
      BY ONLY <2>0f, Safety, SafetyTypeOK DEF TypeOK, PreparationMapTypes, Members
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4
  <2>0h. /\ Allocated' = Allocated
           /\ BoundMembers' = BoundMembers
           /\ LiveMembers' = LiveMembers
           /\ UsedBytes' = UsedBytes
           /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
           /\ (CohortsOf(s.ack))' = CohortsOf(s.ack)
           /\ \A d \in CohortDomain : Members(d)' = Members(d)
    BY <2>0b DEF StateFields, Allocated, BoundMembers, LiveMembers, UsedBytes,
       CohortsOf, Members
  <2>0i. (CohortsOf(s.authority \cup s.exported))' \subseteq
           CohortsOf(s.authority \cup s.exported) \cup {c}
    <3> SUFFICES ASSUME NEW d \in (CohortsOf(s.authority \cup s.exported))'
                 PROVE d \in CohortsOf(s.authority \cup s.exported) \cup {c}
      OBVIOUS
    <3>1. /\ d \in s'.issued
           /\ Members(d)' \cap (s'.authority \cup s'.exported) # {}
      BY ONLY DEF CohortsOf
    <3>2. /\ d \in CohortDomain
           /\ d \in s.issued
           /\ Members(d)' = Members(d)
      BY ONLY <3>1, <2>0b, <2>0h, Safety, SafetyTypeOK
         DEF TypeOK, CohortStateTypes, StateFields
    <3>3. CASE ~uncertain
      <4>1. /\ s'.authority = s.authority
             /\ s'.exported = s.exported
        BY ONLY <3>3, <2>0b, <2>0c DEF StateFields
      <4>2. Members(d) \cap (s.authority \cup s.exported) # {}
        BY ONLY <3>1, <3>2, <4>1
      <4> QED BY ONLY <3>2, <4>2 DEF CohortsOf
    <3>4. CASE uncertain
      <4>1. /\ s'.authority = s.authority \cup Members(c)
             /\ s'.exported = s.exported
        BY ONLY <3>4, <2>0b, <2>0c DEF StateFields
      <4>2. Members(d) \cap
               ((s.authority \cup s.exported) \cup Members(c)) # {}
        BY ONLY <3>1, <3>2, <4>1
      <4>3. CASE Members(d) \cap (s.authority \cup s.exported) # {}
        BY ONLY <3>2, <4>3 DEF CohortsOf
      <4>4. CASE Members(d) \cap Members(c) # {}
        <5>1. d = c
          BY ONLY <3>2, <4>4, <2>0f, Safety, SafetyMembership
             DEF MembershipSafety, GroupPartition
        <5> QED BY ONLY <5>1
      <4> QED BY ONLY <4>2, <4>3, <4>4
    <3> QED BY ONLY <3>3, <3>4
  <2>0j. Members(c) \cap s.discarded = {}
    <3> SUFFICES ASSUME NEW t \in Members(c) \cap s.discarded
                 PROVE FALSE
      OBVIOUS
    <3>1. t \in Members(c) \cap s.collected
      BY ONLY Safety, SafetyMembership
         DEF MembershipSafety, TerminalMembership
    <3>2. c \in CohortsOf(s.collected)
      BY ONLY <2>0f, <3>1 DEF CohortsOf
    <3> QED BY ONLY <3>2, <2>0g
  <2>0k. c \notin s.ready
    BY ONLY <2>0f, Safety, SafetyOwnership DEF Ownership
  <2>0l. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
             \subseteq Allocated'
    <3>1. s'.owned \cup (CohortsOf(s.authority \cup s.exported))' \subseteq
             s.owned \cup CohortsOf(s.authority \cup s.exported)
      BY ONLY <2>0b, <2>0d, <2>0i DEF StateFields
    <3>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))') \subseteq
             Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
      BY ONLY <3>1 DEF Batches
    <3>3. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
             \subseteq Allocated
      BY ONLY Safety, SafetyOwnership DEF Ownership
    <3> QED BY ONLY <3>2, <3>3, <2>0h
  <2>1. TypeOK'
    <3>0. TypeOK
      BY ONLY Safety, SafetyTypeOK
    <3>1. StateShape'
      BY ONLY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, MemberStateTypes, StateFields
    <3>3. PreparationMapTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, PreparationMapTypes, StateFields
    <3>4. CohortStateTypes'
      <4>1. /\ s'.sealed \subseteq CohortDomain
             /\ s'.ready \subseteq CohortDomain
             /\ s'.issued \subseteq CohortDomain
             /\ s'.stored \subseteq CohortDomain
             /\ s'.retired \subseteq CohortDomain
             /\ s'.excluded \subseteq CohortDomain
             /\ s'.prepareFailed \subseteq CohortDomain
             /\ s'.batchFailed \subseteq CohortDomain
             /\ s'.validated \subseteq CohortDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, CohortStateTypes, StateFields
      <4>2. s'.published \subseteq CohortDomain
        <5>1. CASE entered
          BY ONLY <5>1, <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
             DEF TypeOK, CohortStateTypes
        <5>2. CASE ~entered
          BY ONLY <5>2, <2>0b, <3>0 DEF TypeOK, CohortStateTypes
        <5> QED BY ONLY <5>1, <5>2
      <4>3. s'.abandoned \subseteq CohortDomain
        <5>1. CASE ~entered /\ ~uncertain
          BY ONLY <5>1, <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
             DEF TypeOK, CohortStateTypes
        <5>2. CASE ~(~entered /\ ~uncertain)
          BY ONLY <5>2, <2>0b, <3>0 DEF TypeOK, CohortStateTypes
        <5> QED BY ONLY <5>1, <5>2
      <4>4. s'.projection \subseteq CohortDomain
        <5>1. CASE entered /\ ~uncertain
          BY ONLY <5>1, <2>0b, <3>0 DEF TypeOK, CohortStateTypes
        <5>2. CASE ~(entered /\ ~uncertain)
          BY ONLY <5>2, <2>0b, FS_EmptySet
        <5> QED BY ONLY <5>1, <5>2
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4 DEF CohortStateTypes
    <3>5. PublicationStateTypes'
      <4>1. /\ s'.batchCalls \subseteq CohortDomain
             /\ s'.headCalls \subseteq CohortDomain
             /\ s'.batchBorrow \subseteq CohortDomain
             /\ s'.headBorrow \subseteq CohortDomain
             /\ s'.owned \subseteq CohortDomain
        BY ONLY <2>0b, <3>0, FS_EmptySet
           DEF TypeOK, PublicationStateTypes, StateFields
      <4>2. s'.accepted \subseteq CohortDomain
        <5>1. CASE entered /\ ~uncertain
          BY ONLY <5>1, <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
             DEF TypeOK, PublicationStateTypes
        <5>2. CASE ~(entered /\ ~uncertain)
          BY ONLY <5>2, <2>0b, <3>0 DEF TypeOK, PublicationStateTypes
        <5> QED BY ONLY <5>1, <5>2
      <4>3. s'.unknown \subseteq CohortDomain
        <5>1. CASE uncertain
          BY ONLY <5>1, <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
             DEF TypeOK, PublicationStateTypes
        <5>2. CASE ~uncertain
          BY ONLY <5>2, <2>0b, <3>0 DEF TypeOK, PublicationStateTypes
        <5> QED BY ONLY <5>1, <5>2
      <4>4. s'.absent \subseteq CohortDomain
        <5>1. CASE ~entered /\ ~uncertain
          BY ONLY <5>1, <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
             DEF TypeOK, PublicationStateTypes
        <5>2. CASE ~(~entered /\ ~uncertain)
          BY ONLY <5>2, <2>0b, <3>0 DEF TypeOK, PublicationStateTypes
        <5> QED BY ONLY <5>1, <5>2
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4 DEF PublicationStateTypes
    <3>6. AuthorityStateTypes'
      <4>1. s'.authority \subseteq MemberDomain
        <5>1. CASE uncertain
          BY ONLY <5>1, <2>0b, <2>0g, <3>0, FS_AddElement, FS_Subset
             DEF TypeOK, AuthorityStateTypes
        <5>2. CASE ~uncertain
          BY ONLY <5>2, <2>0b, <3>0 DEF TypeOK, AuthorityStateTypes
        <5> QED BY ONLY <5>1, <5>2
      <4>2. /\ s'.exported \subseteq MemberDomain
             /\ s'.ack \subseteq MemberDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, AuthorityStateTypes, StateFields
      <4> QED BY ONLY <4>1, <4>2 DEF AuthorityStateTypes
    <3>7. LifecycleStateTypes'
      BY ONLY <2>0b, <2>0c, <3>0 DEF TypeOK, LifecycleStateTypes, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>0. MembershipSafety
      BY ONLY Safety, SafetyMembership
    <3>1. AdmissionMembership'
      BY ONLY <2>0b, <3>0 DEF MembershipSafety, AdmissionMembership, StateFields
    <3>2. BoundMembership'
      BY ONLY <2>0b, <2>0h, <3>0
         DEF MembershipSafety, BoundMembership, StateFields
    <3>3. GroupPartition'
      <4>1. (\A d \in CohortDomain : (d \in s.issued <=> Members(d) # {}))'
        BY ONLY <2>0b, <2>0h, <3>0
           DEF MembershipSafety, GroupPartition, Members, StateFields
      <4>2. (\A d, e \in CohortDomain :
                 d # e => Members(d) \cap Members(e) = {})'
        BY ONLY <2>0h, <3>0 DEF MembershipSafety, GroupPartition, Members
      <4>3. (\A d \in s.issued : Cardinality(Members(d)) <= MemberCapacity)'
        BY ONLY <2>0b, <2>0h, <3>0
           DEF MembershipSafety, GroupPartition, Members, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF GroupPartition
    <3>4. AuthorityMembership'
      <4>1. s'.authority \cup s'.exported \cup s'.ack \subseteq BoundMembers'
        <5>1. CASE uncertain
          <6>1. s.authority \cup s.exported \cup s.ack \subseteq BoundMembers
            BY ONLY <3>0 DEF MembershipSafety, AuthorityMembership
          <6>2. Members(c) \subseteq BoundMembers
            BY ONLY <2>0g
          <6>3. /\ s'.authority = s.authority \cup Members(c)
                 /\ s'.exported = s.exported
                 /\ s'.ack = s.ack
                 /\ BoundMembers' = BoundMembers
            BY ONLY <5>1, <2>0b, <2>0h DEF StateFields
          <6> QED BY ONLY <6>1, <6>2, <6>3
        <5>2. CASE ~uncertain
          BY ONLY <5>2, <2>0b, <2>0h, <3>0
             DEF MembershipSafety, AuthorityMembership, StateFields
        <5> QED BY ONLY <5>1, <5>2
      <4>2. s'.rejected \cap BoundMembers' = {}
        BY ONLY <2>0b, <2>0h, <3>0
           DEF MembershipSafety, AuthorityMembership, StateFields
      <4> QED BY ONLY <4>1, <4>2 DEF AuthorityMembership
    <3>5. TerminalMembership'
      BY ONLY <2>0b, <2>0h, <3>0, FS_EmptySet
         DEF MembershipSafety, TerminalMembership, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>0. PublicationSafety
      BY ONLY Safety, SafetyPublication
    <3>1. PublicationOrder'
      <4>1. s'.retired \subseteq s'.published
        BY ONLY <2>0b, <3>0, FS_AddElement
           DEF PublicationSafety, PublicationOrder, StateFields
      <4>2. s'.published \subseteq s'.headCalls
        <5>1. CASE entered
          BY ONLY <5>1, <2>0b, <2>0d, <3>0, FS_AddElement, FS_Subset
             DEF PublicationSafety, PublicationOrder, StateFields
        <5>2. CASE ~entered
          BY ONLY <5>2, <2>0b, <3>0
             DEF PublicationSafety, PublicationOrder, StateFields
        <5> QED BY ONLY <5>1, <5>2
      <4>3. /\ s'.headCalls \subseteq s'.validated
             /\ s'.validated \subseteq s'.stored
             /\ s'.stored \subseteq s'.batchCalls
             /\ s'.batchCalls \subseteq s'.sealed
             /\ s'.sealed \subseteq s'.issued
        BY ONLY <2>0b, <3>0
           DEF PublicationSafety, PublicationOrder, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF PublicationOrder
    <3>2. PublicationExclusion'
      <4>1. /\ s'.excluded \subseteq s'.issued
             /\ s'.excluded \cap s'.owned = {}
        BY ONLY <2>0b, <3>0
           DEF PublicationSafety, PublicationExclusion, StateFields
      <4>2. CASE entered
        BY ONLY <4>2, <2>0b, <2>0d, <2>0g, <3>0, FS_AddElement
           DEF PublicationSafety, PublicationExclusion, StateFields
      <4>3. CASE ~entered /\ uncertain
        BY ONLY <4>3, <2>0b, <3>0
           DEF PublicationSafety, PublicationExclusion, StateFields
      <4>4. CASE ~entered /\ ~uncertain
        BY ONLY <4>4, <2>0b, <2>0d, <3>0, FS_AddElement
           DEF PublicationSafety, PublicationExclusion, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3, <4>4 DEF PublicationExclusion
    <3>3. PublicationPredecessorOrder'
      BY ONLY <2>0b, <3>0
         DEF PublicationSafety, PublicationPredecessorOrder, StateFields
    <3>4. PublicationAcknowledgement'
      BY ONLY <2>0b, <2>0h, <3>0, FS_AddElement
         DEF PublicationSafety, PublicationAcknowledgement, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY ONLY Safety, SafetyOwnership
    <3>1. s'.owned \subseteq s'.issued
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
             \subseteq Allocated'
      BY ONLY <2>0l DEF CohortsOf, Members
    <3>3. s'.ready \subseteq
             (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
      BY ONLY <2>0b, <2>0c, <2>0k, <3>0, FS_AddElement
         DEF Ownership, StateFields
    <3>4. /\ s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
           /\ s'.batchBorrow \subseteq s'.batchCalls
           /\ s'.headBorrow \subseteq s'.headCalls
           /\ s'.batchBorrow \cap s'.stored = {}
           /\ s'.headBorrow \cap s'.published = {}
      BY ONLY <2>0b, <3>0, FS_EmptySet DEF Ownership, StateFields
    <3>5. s'.accepted \subseteq
             (s'.owned \cap s'.published) \ s'.headBorrow
      <4>1. CASE entered /\ ~uncertain
        <5>1. /\ s'.accepted = {c}
               /\ s'.owned = s.owned
               /\ s'.published = s.published \cup {c}
               /\ s'.headBorrow = {}
          BY ONLY <4>1, <2>0b, <2>0c, <2>0e DEF StateFields
        <5>2. c \in s'.owned \cap s'.published
          BY ONLY <2>0d, <5>1
        <5> QED BY ONLY <5>1, <5>2
      <4>2. CASE ~(entered /\ ~uncertain)
        BY ONLY <4>2, <2>0b, <2>0c, <2>0e, FS_EmptySet
      <4> QED BY ONLY <4>1, <4>2
    <3>6. s'.unknown \subseteq
             (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
      <4>1. CASE uncertain
        <5>1a. s'.unknown = {c}
          BY ONLY <4>1, <2>0b, <2>0d, FS_AddElement, FS_EmptySet
        <5>1b. s'.owned = s.owned
          BY ONLY <2>0b DEF StateFields
        <5>1c. s'.headCalls = s.headCalls
          BY ONLY <2>0b DEF StateFields
        <5>1d. s'.headBorrow = {}
          BY ONLY <2>0b
        <5>1e. s'.accepted = {}
          BY ONLY <4>1, <2>0b, <2>0e
        <5>2. c \in s'.owned \cap s'.headCalls
          BY ONLY <2>0d, <5>1b, <5>1c
        <5> QED BY ONLY <5>1a, <5>1b, <5>1c, <5>1d, <5>1e, <5>2
      <4>2. CASE ~uncertain
        BY ONLY <4>2, <2>0b, <2>0c, <2>0d, FS_EmptySet
      <4> QED BY ONLY <4>1, <4>2
    <3>7. s'.absent \subseteq s'.headCalls \ s'.headBorrow
      <4>1. CASE ~entered /\ ~uncertain
        <5>1a. s'.absent = s.absent \cup {c}
          BY ONLY <4>1, <2>0b
        <5>1b. s'.headCalls = s.headCalls
          BY ONLY <2>0b DEF StateFields
        <5>1c. s'.headBorrow = {}
          BY ONLY <2>0b
        <5>2. s.absent \subseteq s.headCalls
          BY ONLY Safety, SafetyOwnership DEF Ownership
        <5>3. s'.absent \subseteq s'.headCalls
          BY ONLY <2>0d, <5>1a, <5>1b, <5>2, FS_AddElement
        <5> QED BY ONLY <5>1c, <5>3
      <4>2. CASE ~(~entered /\ ~uncertain)
        BY ONLY <4>2, <2>0b, <2>0c, <3>0, FS_EmptySet
           DEF Ownership, StateFields
      <4> QED BY ONLY <4>1, <4>2
    <3>8. /\ s'.prepareFailed \subseteq
                s'.owned \ (s'.sealed \cup s'.batchCalls)
           /\ Batches(s'.prepareFailed) \subseteq
                s'.prepareCalls \ s'.prepareBorrow
           /\ s'.batchFailed \subseteq
                (s'.owned \cap s'.batchCalls) \
                   (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>9. /\ s'.projection \subseteq
                (s'.owned \cap s'.validated) \ s'.abandoned
           /\ s'.headBorrow \cup s'.accepted \subseteq s'.projection
           /\ (s'.unknown \cup s'.absent) \cap s'.projection = {}
      <4>1. CASE entered /\ ~uncertain
        <5>1. /\ s'.projection = {c}
               /\ s'.headBorrow = {}
               /\ s'.accepted = {c}
               /\ s'.unknown = {}
               /\ s'.absent = s.absent
          BY ONLY <4>1, <2>0b, <2>0d, <2>0e, FS_AddElement, FS_EmptySet
        <5>2. /\ s'.owned = s.owned
               /\ s'.validated = s.validated
               /\ s'.abandoned = s.abandoned
          BY ONLY <4>1, <2>0b DEF StateFields
        <5>3. s'.projection \subseteq
                 (s'.owned \cap s'.validated) \ s'.abandoned
          BY ONLY <2>0d, <2>0f, <2>0g, <5>1, <5>2, FS_Singleton
        <5>4. s'.headBorrow \cup s'.accepted \subseteq s'.projection
          BY ONLY <5>1, FS_EmptySet, FS_Singleton
        <5>5. (s'.unknown \cup s'.absent) \cap s'.projection = {}
          BY ONLY <2>0d, <5>1, FS_EmptySet, FS_Singleton
        <5> QED BY ONLY <5>3, <5>4, <5>5
      <4>2. CASE uncertain
        <5>1. /\ s'.projection = {}
               /\ s'.headBorrow = {}
               /\ s'.accepted = {}
          BY ONLY <4>2, <2>0b, <2>0e
        <5> QED BY ONLY <5>1, FS_EmptySet
      <4>3. CASE ~entered /\ ~uncertain
        <5>1. /\ s'.projection = {}
               /\ s'.headBorrow = {}
               /\ s'.accepted = {}
          BY ONLY <4>3, <2>0b, <2>0e
        <5> QED BY ONLY <5>1, FS_EmptySet
      <4> QED BY ONLY <4>1, <4>2, <4>3
    <3>10. s'.headBorrow # {} => s'.unknown = {}
      BY ONLY <2>0b, FS_EmptySet
    <3>11a. s.online
      BY ONLY <2>0c, <3>0 DEF Ownership
    <3>11. ~s'.online =>
            s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
            s'.batchBorrow = {} /\ s'.headBorrow = {} /\
            s'.admitted = s'.collected
      BY ONLY <2>0b, <3>11a DEF StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7, <3>8,
       <3>9, <3>10, <3>11 DEF Ownership
  <2>5. PreparationOwnership'
    BY <2>0b, <2>0h, SafetyPreparationOwnership
       DEF PreparationOwnership, StateFields
  <2>6. ResourceBounds'
    BY <2>0b, <2>0e, <2>0h, SafetyResourceBounds, FS_EmptySet, FS_Singleton,
       FS_CardinalityType
       DEF ResourceBounds, StateFields
  <2>7. AuthoritySafety'
    <3>0. AuthoritySafety
      BY ONLY Safety, SafetyAuthority
    <3>1. (CohortsOf(s.authority \cup s.exported) \subseteq
             s.headCalls \ s.headBorrow)'
      BY ONLY <2>0b, <2>0d, <2>0i, <3>0, FS_EmptySet, FS_Subset
         DEF AuthoritySafety, StateFields
    <3>2. (s.headBorrow \cap s.abandoned = {})'
      BY ONLY <2>0b, FS_EmptySet
    <3>3. (s.unknownEpisode => s.halted)'
      BY ONLY <2>0b, <2>0c, <3>0 DEF AuthoritySafety, StateFields
    <3>4. (s.exported \subseteq s.delivered /\ s.delivered \subseteq s.collected)'
      BY ONLY <2>0b, <3>0 DEF AuthoritySafety, StateFields
    <3>5. (s.authority \cap s.discarded = {})'
      <4>1. CASE uncertain
        BY ONLY <4>1, <2>0b, <2>0c, <2>0j, <3>0
           DEF AuthoritySafety, StateFields
      <4>2. CASE ~uncertain
        BY ONLY <4>2, <2>0b, <2>0c, <3>0
           DEF AuthoritySafety, StateFields
      <4> QED BY ONLY <4>1, <4>2
    <3>6. (s.resolutionWrites = 0)'
      BY ONLY <2>0b, <3>0 DEF AuthoritySafety, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6 DEF AuthoritySafety
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1>5. CASE Retire(c, entered)
  <2>0a. DOMAIN s = StateFields
    BY SafetyTypeOK DEF TypeOK, StateShape
  <2>0b. /\ DOMAIN s' = StateFields
           /\ s'.accepted = s.accepted \ {c}
           /\ s'.owned = s.owned \ {c}
           /\ s'.retired = s.retired \cup {c}
           /\ s'.projection = {}
           /\ s'.ack = s.ack \cup Members(c)
           /\ s'.fenced = (s.fenced \/ entered)
           /\ s'.halted = (s.halted \/ entered)
           /\ \A field \in StateFields \
                {"accepted", "owned", "retired", "projection", "ack", "fenced", "halted"} :
                s'[field] = s[field]
    BY <1>5, <2>0a, RetireProjection
  <2>0c. /\ c \in s.accepted
           /\ c \in s.published
           /\ entered \in BOOLEAN
    BY <1>5 DEF Retire
  <2>0d. /\ c \in s.owned
           /\ c \notin s.headBorrow
           /\ c \in s.projection
           /\ c \notin s.unknown
           /\ c \notin s.absent
    BY <2>0c, SafetyOwnership DEF Ownership
  <2>0e. /\ s.projection = {c}
           /\ s.accepted = {c}
    <3>1. IsFiniteSet(CohortDomain)
      BY ONLY ConstantsOK DEF ConstantsOK
    <3>2. s.projection \subseteq CohortDomain
      BY ONLY Safety, SafetyTypeOK DEF TypeOK, CohortStateTypes
    <3>3. IsFiniteSet(s.projection)
      BY ONLY <3>1, <3>2, FS_Subset
    <3>4. {c} \subseteq s.projection
      BY ONLY <2>0d
    <3>5. /\ Cardinality({c}) = 1
           /\ Cardinality(s.projection) <= 1
      BY ONLY Safety, SafetyResourceBounds, FS_Singleton DEF ResourceBounds
    <3>6. Cardinality({c}) = Cardinality(s.projection)
      BY ONLY <3>3, <3>4, <3>5, FS_Subset, FS_CardinalityType
    <3>7. s.projection = {c}
      BY ONLY <3>3, <3>4, <3>6, FS_Subset
    <3>8. s.accepted = {c}
      <4>1. {c} \subseteq s.accepted
        BY ONLY <2>0c
      <4>2. s.accepted \subseteq {c}
        BY ONLY <3>7, Safety, SafetyOwnership DEF Ownership
      <4> QED BY ONLY <4>1, <4>2, FS_Subset
    <3> QED BY ONLY <3>7, <3>8
  <2>0f. /\ c \in s.headCalls
           /\ c \in s.validated
           /\ c \in s.stored
           /\ c \in s.batchCalls
           /\ c \in s.sealed
           /\ c \in s.issued
           /\ c \notin s.excluded
           /\ c \notin s.abandoned
    BY <2>0c, SafetyPublication DEF PublicationSafety, PublicationOrder,
       PublicationExclusion
  <2>0g. /\ c \notin s.ready
           /\ c \notin s.batchBorrow
           /\ c \notin s.prepareFailed
           /\ c \notin s.batchFailed
           /\ Batch(c) \notin s.prepareBorrow
    BY <2>0d, <2>0f, SafetyOwnership, SafetyPreparationOwnership
       DEF Ownership, PreparationOwnership
  <2>0h. /\ Allocated' = Allocated
           /\ BoundMembers' = BoundMembers
           /\ LiveMembers' = LiveMembers
           /\ UsedBytes' = UsedBytes
           /\ (CohortsOf(s.collected))' = CohortsOf(s.collected)
           /\ (CohortsOf(s.authority \cup s.exported))' =
                CohortsOf(s.authority \cup s.exported)
           /\ \A d \in CohortDomain : Members(d)' = Members(d)
    BY <2>0b DEF StateFields, Allocated, BoundMembers, LiveMembers, UsedBytes,
       CohortsOf, Members
  <2>0i. (CohortsOf(s.ack))' \subseteq CohortsOf(s.ack) \cup {c}
    <3> SUFFICES ASSUME NEW d \in (CohortsOf(s.ack))'
                 PROVE d \in CohortsOf(s.ack) \cup {c}
      OBVIOUS
    <3>1. /\ d \in s'.issued
           /\ Members(d)' \cap s'.ack # {}
      BY ONLY DEF CohortsOf
    <3>2. /\ d \in CohortDomain
           /\ d \in s.issued
           /\ Members(d)' = Members(d)
      BY ONLY <3>1, <2>0b, <2>0h, Safety, SafetyTypeOK
         DEF TypeOK, CohortStateTypes, StateFields
    <3>3. s'.ack = s.ack \cup Members(c)
      BY ONLY <2>0b
    <3>4. Members(d) \cap (s.ack \cup Members(c)) # {}
      BY ONLY <3>1, <3>2, <3>3
    <3>5. CASE Members(d) \cap s.ack # {}
      BY ONLY <3>2, <3>5 DEF CohortsOf
    <3>6. CASE Members(d) \cap Members(c) # {}
      <4>1. d = c
        BY ONLY <3>2, <3>6, <2>0f, Safety, SafetyMembership
           DEF MembershipSafety, GroupPartition
      <4> QED BY ONLY <4>1
    <3> QED BY ONLY <3>4, <3>5, <3>6
  <2>1. TypeOK'
    <3>0. TypeOK
      BY ONLY Safety, SafetyTypeOK
    <3>1. StateShape'
      BY ONLY <2>0b DEF StateShape
    <3>2. MemberStateTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, MemberStateTypes, StateFields
    <3>3. PreparationMapTypes'
      BY ONLY <2>0b, <3>0 DEF TypeOK, PreparationMapTypes, StateFields
    <3>4. CohortStateTypes'
      <4>1. /\ s'.sealed \subseteq CohortDomain
             /\ s'.ready \subseteq CohortDomain
             /\ s'.issued \subseteq CohortDomain
             /\ s'.stored \subseteq CohortDomain
             /\ s'.published \subseteq CohortDomain
             /\ s'.excluded \subseteq CohortDomain
             /\ s'.abandoned \subseteq CohortDomain
             /\ s'.prepareFailed \subseteq CohortDomain
             /\ s'.batchFailed \subseteq CohortDomain
             /\ s'.validated \subseteq CohortDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, CohortStateTypes, StateFields
      <4>2. s'.retired \subseteq CohortDomain
        BY ONLY <2>0b, <2>0c, <3>0, FS_AddElement, FS_Subset
           DEF TypeOK, CohortStateTypes
      <4>3. s'.projection \subseteq CohortDomain
        BY ONLY <2>0b, FS_EmptySet
      <4> QED BY ONLY <4>1, <4>2, <4>3 DEF CohortStateTypes
    <3>5. PublicationStateTypes'
      BY ONLY <2>0b, <3>0, FS_RemoveElement, FS_Subset
         DEF TypeOK, PublicationStateTypes, StateFields
    <3>6. AuthorityStateTypes'
      <4>1. Members(c) \subseteq MemberDomain
        BY ONLY <2>0f, <3>0 DEF TypeOK, PreparationMapTypes, Members
      <4>2. s'.ack \subseteq MemberDomain
        BY ONLY <2>0b, <4>1, <3>0, FS_AddElement, FS_Subset
           DEF TypeOK, AuthorityStateTypes
      <4>3. /\ s'.authority \subseteq MemberDomain
             /\ s'.exported \subseteq MemberDomain
        BY ONLY <2>0b, <3>0 DEF TypeOK, AuthorityStateTypes, StateFields
      <4> QED BY ONLY <4>2, <4>3 DEF AuthorityStateTypes
    <3>7. LifecycleStateTypes'
      BY ONLY <2>0b, <2>0c, <3>0 DEF TypeOK, LifecycleStateTypes, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7 DEF TypeOK
  <2>2. MembershipSafety'
    <3>0. MembershipSafety
      BY ONLY Safety, SafetyMembership
    <3>1. AdmissionMembership'
      BY ONLY <2>0b, <3>0 DEF MembershipSafety, AdmissionMembership, StateFields
    <3>2. BoundMembership'
      BY ONLY <2>0b, <2>0h, <3>0
         DEF MembershipSafety, BoundMembership, StateFields
    <3>3. GroupPartition'
      BY ONLY <2>0b, <2>0h, <3>0
         DEF MembershipSafety, GroupPartition, Members, StateFields
    <3>4. AuthorityMembership'
      <4>1. Members(c) \subseteq BoundMembers
        BY ONLY <2>0f DEF BoundMembers
      <4>2. s'.authority \cup s'.exported \cup s'.ack \subseteq BoundMembers'
        BY ONLY <2>0b, <2>0h, <4>1, <3>0, FS_AddElement
           DEF MembershipSafety, AuthorityMembership, StateFields
      <4>3. s'.rejected \cap BoundMembers' = {}
        BY ONLY <2>0b, <2>0h, <3>0
           DEF MembershipSafety, AuthorityMembership, StateFields
      <4> QED BY ONLY <4>2, <4>3 DEF AuthorityMembership
    <3>5. TerminalMembership'
      BY ONLY <2>0b, <2>0h, <3>0
         DEF MembershipSafety, TerminalMembership, CohortsOf, Members, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5 DEF MembershipSafety
  <2>3. PublicationSafety'
    <3>0. PublicationSafety
      BY ONLY Safety, SafetyPublication
    <3>1. PublicationOrder'
      <4>1. s'.retired \subseteq s'.published
        BY ONLY <2>0b, <2>0c, <3>0, FS_AddElement
           DEF PublicationSafety, PublicationOrder, StateFields
      <4>2. /\ s'.published \subseteq s'.headCalls
             /\ s'.headCalls \subseteq s'.validated
             /\ s'.validated \subseteq s'.stored
             /\ s'.stored \subseteq s'.batchCalls
             /\ s'.batchCalls \subseteq s'.sealed
             /\ s'.sealed \subseteq s'.issued
        BY ONLY <2>0b, <3>0 DEF PublicationSafety, PublicationOrder, StateFields
      <4> QED BY ONLY <4>1, <4>2 DEF PublicationOrder
    <3>2. PublicationExclusion'
      BY ONLY <2>0b, <3>0, FS_RemoveElement
         DEF PublicationSafety, PublicationExclusion, StateFields
    <3>3. PublicationPredecessorOrder'
      BY ONLY <2>0b, <3>0, FS_AddElement
         DEF PublicationSafety, PublicationPredecessorOrder, StateFields
    <3>4. PublicationAcknowledgement'
      <4>1. CohortsOf(s.ack) \subseteq s.published
        BY ONLY <3>0 DEF PublicationSafety, PublicationAcknowledgement
      <4>2. (CohortsOf(s.ack))' \subseteq s'.published
        BY ONLY <2>0b, <2>0c, <2>0i, <4>1, FS_AddElement DEF StateFields
      <4> QED BY ONLY <4>2 DEF PublicationAcknowledgement
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4 DEF PublicationSafety
  <2>4. Ownership'
    <3>0. Ownership
      BY ONLY Safety, SafetyOwnership
    <3>0a. s.headBorrow = {}
      <4>1. s.headBorrow \subseteq {c}
        BY ONLY <2>0e, <3>0 DEF Ownership
      <4>2. c \notin s.headBorrow
        BY ONLY <2>0d
      <4> QED BY ONLY <4>1, <4>2, FS_Singleton
    <3>1. s'.owned \subseteq s'.issued
      BY ONLY <2>0b, <3>0, FS_RemoveElement DEF Ownership, StateFields
    <3>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
             \subseteq Allocated'
      <4>1. s'.owned \cup (CohortsOf(s.authority \cup s.exported))' \subseteq
               s.owned \cup CohortsOf(s.authority \cup s.exported)
        BY ONLY <2>0b, <2>0h, FS_RemoveElement DEF StateFields
      <4>2. Batches(s'.owned \cup (CohortsOf(s.authority \cup s.exported))')
               \subseteq Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
        BY ONLY <4>1 DEF Batches
      <4>3. Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
               \subseteq Allocated
        BY ONLY <3>0 DEF Ownership
      <4> QED BY ONLY <4>2, <4>3, <2>0h
    <3>3. s'.ready \subseteq
             (s'.owned \cap s'.sealed) \ (s'.batchCalls \cup s'.abandoned)
      BY ONLY <2>0b, <2>0g, <3>0, FS_RemoveElement
         DEF Ownership, StateFields
    <3>4. /\ s'.batchBorrow \cup s'.headBorrow \subseteq s'.owned
           /\ s'.batchBorrow \subseteq s'.batchCalls
           /\ s'.headBorrow \subseteq s'.headCalls
           /\ s'.batchBorrow \cap s'.stored = {}
           /\ s'.headBorrow \cap s'.published = {}
      <4>1. s'.batchBorrow \subseteq s'.owned
        BY ONLY <2>0b, <2>0g, <3>0, FS_RemoveElement
           DEF Ownership, StateFields
      <4>2. s'.headBorrow = {}
        BY ONLY <2>0b, <3>0a DEF StateFields
      <4>3. /\ s'.batchBorrow \subseteq s'.batchCalls
             /\ s'.headBorrow \subseteq s'.headCalls
             /\ s'.batchBorrow \cap s'.stored = {}
             /\ s'.headBorrow \cap s'.published = {}
        BY ONLY <2>0b, <3>0, <4>2 DEF Ownership, StateFields
      <4> QED BY ONLY <4>1, <4>2, <4>3, FS_EmptySet
    <3>5. s'.accepted \subseteq
             (s'.owned \cap s'.published) \ s'.headBorrow
      BY ONLY <2>0b, <2>0e, FS_EmptySet
    <3>6. s'.unknown \subseteq
             (s'.owned \cap s'.headCalls) \ (s'.headBorrow \cup s'.accepted)
      BY ONLY <2>0b, <2>0d, <2>0e, <3>0, FS_RemoveElement, FS_EmptySet
         DEF Ownership, StateFields
    <3>7. s'.absent \subseteq s'.headCalls \ s'.headBorrow
      BY ONLY <2>0b, <3>0 DEF Ownership, StateFields
    <3>8. /\ s'.prepareFailed \subseteq
                s'.owned \ (s'.sealed \cup s'.batchCalls)
           /\ Batches(s'.prepareFailed) \subseteq
                s'.prepareCalls \ s'.prepareBorrow
           /\ s'.batchFailed \subseteq
                (s'.owned \cap s'.batchCalls) \
                   (s'.batchBorrow \cup s'.stored \cup s'.headCalls)
      BY ONLY <2>0b, <2>0g, <3>0, FS_RemoveElement
         DEF Ownership, StateFields
    <3>9. /\ s'.projection \subseteq
                (s'.owned \cap s'.validated) \ s'.abandoned
           /\ s'.headBorrow \cup s'.accepted \subseteq s'.projection
           /\ (s'.unknown \cup s'.absent) \cap s'.projection = {}
      BY ONLY <2>0b, <2>0e, <3>0a, FS_EmptySet DEF StateFields
    <3>10. s'.headBorrow # {} => s'.unknown = {}
      BY ONLY <2>0b, <3>0a DEF StateFields
    <3>11. ~s'.online =>
            s'.pending = {} /\ s'.owned = {} /\ s'.prepareBorrow = {} /\
            s'.batchBorrow = {} /\ s'.headBorrow = {} /\
            s'.admitted = s'.collected
      BY ONLY <2>0b, <3>0, FS_RemoveElement DEF Ownership, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7, <3>8,
       <3>9, <3>10, <3>11 DEF Ownership
  <2>5. PreparationOwnership'
    <3>0. PreparationOwnership
      BY ONLY Safety, SafetyPreparationOwnership
    <3>1. s'.prepareBorrow \subseteq s'.prepareCalls \cap Allocated'
      BY ONLY <2>0b, <2>0h, <3>0 DEF PreparationOwnership, StateFields
    <3>2. \A t \in MemberDomain :
               Fragment(t) \in s'.prepareBorrow =>
                 Input(t) \in Allocated' /\ t \in s'.admitted \ BoundMembers'
      BY ONLY <2>0b, <2>0h, <3>0 DEF PreparationOwnership, StateFields
    <3>3. \A d \in CohortDomain :
               Batch(d) \in s'.prepareBorrow =>
                 d \in s'.owned /\ Fragments(Members(d)') \subseteq Allocated'
      <4> SUFFICES ASSUME NEW d \in CohortDomain,
                           Batch(d) \in s'.prepareBorrow
                   PROVE d \in s'.owned /\
                         Fragments(Members(d)') \subseteq Allocated'
        OBVIOUS
      <4>1a. Batch(d) \in s.prepareBorrow
        BY <2>0b DEF StateFields
      <4>1b. /\ d \in s.owned
              /\ Fragments(Members(d)) \subseteq Allocated
        BY ONLY <4>1a, <3>0 DEF PreparationOwnership
      <4>2. d # c
        BY ONLY <4>1a, <2>0g
      <4> QED BY ONLY <2>0b, <2>0h, <4>1a, <4>1b, <4>2, FS_RemoveElement
         DEF StateFields
    <3>4. \A t \in s'.prepared :
               Fragment(t) \in s'.prepareCalls \ s'.prepareBorrow
      BY ONLY <2>0b, <3>0 DEF PreparationOwnership, StateFields
    <3>5. \A t \in s'.prepared : Input(t) \notin Allocated'
      BY ONLY <2>0b, <2>0h, <3>0 DEF PreparationOwnership, StateFields
    <3>6. \A d \in s'.sealed :
               Batch(d) \in s'.prepareCalls \ s'.prepareBorrow
      BY ONLY <2>0b, <3>0 DEF PreparationOwnership, StateFields
    <3>7. \A t \in MemberDomain :
               Input(t) \in Allocated' =>
                 t \in s'.pending \/ Fragment(t) \in s'.prepareBorrow
      BY ONLY <2>0b, <2>0h, <3>0 DEF PreparationOwnership, StateFields
    <3> QED BY ONLY <3>1, <3>2, <3>3, <3>4, <3>5, <3>6, <3>7
       DEF PreparationOwnership
  <2>6. ResourceBounds'
    <3>0. ResourceBounds
      BY ONLY Safety, SafetyResourceBounds
    <3>1. IsFiniteSet(CohortDomain)
      BY ONLY ConstantsOK DEF ConstantsOK
    <3>2. s.owned \subseteq CohortDomain
      BY ONLY Safety, SafetyTypeOK DEF TypeOK, PublicationStateTypes
    <3>3. IsFiniteSet(s.owned)
      BY ONLY <3>1, <3>2, FS_Subset
    <3>4. Cardinality(s'.owned) <= Capacity
      <4>1. s'.owned \subseteq s.owned
        BY ONLY <2>0b
      <4>2. Cardinality(s'.owned) <= Cardinality(s.owned)
        BY ONLY <3>3, <4>1, FS_Subset
      <4>3. Cardinality(s.owned) <= Capacity
        BY ONLY <3>0 DEF ResourceBounds
      <4>4. IsFiniteSet(s'.owned)
        BY ONLY <3>3, <4>1, FS_Subset
      <4>5. Cardinality(s'.owned) \in Nat
        BY ONLY <4>4, FS_CardinalityType
      <4>6. Cardinality(s.owned) \in Nat
        BY ONLY <3>3, FS_CardinalityType
      <4>7. Capacity \in Nat
        BY ONLY ConstantsOK DEF ConstantsOK
      <4> QED BY ONLY <4>2, <4>3, <4>5, <4>6, <4>7
    <3>5. Cardinality(s'.projection) <= 1
      BY ONLY <2>0b, FS_EmptySet
    <3>6. /\ Cardinality(LiveMembers') <= QueueCapacity
           /\ Cardinality(s'.ready) <= Capacity
           /\ Cardinality(s'.headBorrow) <= 1
           /\ Cardinality(s'.prepareBorrow) <= PrepareCapacity
           /\ Cardinality(UsedBytes') <= Cardinality(ByteDomain)
      BY ONLY <2>0b, <2>0h, <3>0 DEF ResourceBounds, StateFields
    <3>7. \A left, right \in Resources :
               left # right => s'.buffers[left] \cap s'.buffers[right] = {}
      BY ONLY <2>0b, <3>0 DEF ResourceBounds, StateFields
    <3> QED BY ONLY <3>4, <3>5, <3>6, <3>7 DEF ResourceBounds
  <2>7. AuthoritySafety'
    BY <2>0b, <2>0f, <2>0h, SafetyAuthority
       DEF AuthoritySafety, StateFields
  <2> QED BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7 DEF Safety
<1> QED BY <1>1, <1>2, <1>3, <1>3a, <1>4, <1>5

THEOREM DrainResolutionPreserves ==
    ASSUME NEW c \in CohortDomain,
        NEW t \in MemberDomain,
        ConstantsOK,
        Safety,
        AbandonPending \/ FailPreparedFront(c) \/ FailBatchFront(c) \/ MarkAbandoned(c) \/
            DrainAbandoned(c) \/ ResolveFront(t, c) \/ ResolveDetached(t, c) \/
            ConcludeAbsent(t, c) \/ ResolveRejected(t, c) \/ DetachUnknown(c)
    PROVE Safety'
<1>1. CASE AbandonPending
  BY <1>1, AbandonPendingPreserves
<1>2. CASE MarkAbandoned(c)
  <2>1. c \notin s.published
    BY <1>2, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion, MarkAbandoned
  <2>2. /\ DOMAIN s' = StateFields
          /\ s'.abandoned = s.abandoned \cup {c}
          /\ s'.ready = s.ready \ {c}
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"abandoned", "ready", "halted"} :
               s'[field] = s[field]
    BY <1>2, SafetyTypeOK, MarkAbandonedProjection DEF TypeOK, StateShape
  <2> QED BY <1>2, <2>1, <2>2, MarkUnpublishedPreserves DEF MarkAbandoned
<1>2a. CASE FailPreparedFront(c)
  <2>1. c \notin s.ready \cup s.projection \cup s.published
    BY <1>2a, SafetyPublication, SafetyOwnership
       DEF PublicationSafety, PublicationOrder, Ownership, FailPreparedFront
  <2>2a. /\ DOMAIN s' = StateFields
           /\ s'.abandoned = s.abandoned \cup {c}
           /\ s'.ready = s.ready
           /\ s'.halted = TRUE
           /\ \A field \in StateFields \ {"abandoned", "halted"} :
                s'[field] = s[field]
    BY <1>2a, SafetyTypeOK, FailPreparedFrontProjection DEF TypeOK, StateShape
  <2>2. /\ DOMAIN s' = StateFields
          /\ s'.abandoned = s.abandoned \cup {c}
          /\ s'.ready = s.ready \ {c}
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"abandoned", "ready", "halted"} :
               s'[field] = s[field]
    BY <2>1, <2>2a
  <2> QED BY <2>1, <2>2, MarkUnpublishedPreserves
<1>2b. CASE FailBatchFront(c)
  <2>1. c \notin s.ready \cup s.published
    BY <1>2b, SafetyPublication, SafetyOwnership
       DEF PublicationSafety, PublicationOrder, Ownership, FailBatchFront
  <2>2a. /\ DOMAIN s' = StateFields
           /\ s'.abandoned = s.abandoned \cup {c}
           /\ s'.ready = s.ready
           /\ s'.halted = TRUE
           /\ \A field \in StateFields \ {"abandoned", "halted"} :
                s'[field] = s[field]
    BY <1>2b, SafetyTypeOK, FailBatchFrontProjection DEF TypeOK, StateShape
  <2>2. /\ DOMAIN s' = StateFields
          /\ s'.abandoned = s.abandoned \cup {c}
          /\ s'.ready = s.ready \ {c}
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"abandoned", "ready", "halted"} :
               s'[field] = s[field]
    BY <2>1, <2>2a
  <2> QED BY <1>2b, <2>1, <2>2, MarkUnpublishedPreserves DEF FailBatchFront
<1>3. CASE DrainAbandoned(c)
  BY <1>3, DrainAbandonedPreserves
<1>4. CASE ResolveFront(t, c)
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.unknown = s.unknown \ {c}
          /\ s'.owned = s.owned \ {c}
          /\ s'.retired = s.retired \cup {c}
          /\ s'.ack = s.ack \cup {t}
          /\ s'.authority = s.authority \ {t}
          /\ \A field \in StateFields \
               {"unknown", "owned", "retired", "ack", "authority"} :
               s'[field] = s[field]
    BY <1>4, SafetyTypeOK, ResolveFrontProjection DEF TypeOK, StateShape
  <2>2. t \in BoundMembers
    BY <1>4, SafetyMembership
       DEF MembershipSafety, AuthorityMembership, ResolveFront
  <2>3. /\ c \in s.unknown \cap s.published
          /\ DrainedFor(c)
    BY <1>4 DEF ResolveFront
  <2>4. (CohortsOf(s.ack))' \subseteq CohortsOf(s.ack) \cup {c}
    <3> SUFFICES ASSUME NEW d \in (CohortsOf(s.ack))'
                 PROVE d \in CohortsOf(s.ack) \cup {c}
      OBVIOUS
    <3>1. /\ d \in s.issued
            /\ Members(d) \cap (s.ack \cup {t}) # {}
      <4>1. /\ d \in s'.issued
              /\ Members(d)' \cap s'.ack # {}
        BY DEF CohortsOf
      <4>2. /\ s'.issued = s.issued
              /\ Members(d)' = Members(d)
        BY <2>1 DEF StateFields, Members
      <4> QED BY <2>1, <4>1, <4>2
    <3>2. d \in CohortsOf(s.ack) \/ t \in Members(d)
      BY <3>1 DEF CohortsOf
    <3>3. t \in Members(d) => d = c
      <4> SUFFICES ASSUME t \in Members(d)
                   PROVE d = c
        OBVIOUS
      <4>1. d \in CohortDomain
        BY <3>1, SafetyTypeOK DEF TypeOK, CohortStateTypes
      <4>2. t \in Members(c)
        BY <1>4 DEF ResolveFront
      <4>3. t \in Members(c) \cap Members(d)
        BY <4>2
      <4> QED BY <4>1, <4>3, SafetyMembership
         DEF MembershipSafety, GroupPartition
    <3> QED BY <3>2, <3>3
  <2> QED BY <2>1, <2>2, <2>3, <2>4, ResolveFrontPreserves
<1>5. CASE ResolveDetached(t, c)
  <2>1. s' = [s EXCEPT !.ack = s.ack \cup {t}, !.authority = s.authority \ {t}]
    BY <1>5 DEF ResolveDetached
  <2>2. /\ DOMAIN s' = StateFields
          /\ s'.ack = s.ack \cup {t}
          /\ s'.authority = s.authority \ {t}
          /\ \A field \in StateFields \ {"ack", "authority"} : s'[field] = s[field]
    BY <2>1, SafetyTypeOK, ResolveAuthorityProjection DEF TypeOK, StateShape
  <2>3. t \in BoundMembers
    BY <1>5, SafetyMembership
       DEF MembershipSafety, AuthorityMembership, ResolveDetached
  <2>4. c \in s.published
    BY <1>5, SafetyPublication
       DEF PublicationSafety, PublicationOrder, ResolveDetached
  <2>5. (CohortsOf(s.ack))' \subseteq CohortsOf(s.ack) \cup {c}
    <3> SUFFICES ASSUME NEW d \in (CohortsOf(s.ack))'
                 PROVE d \in CohortsOf(s.ack) \cup {c}
      OBVIOUS
    <3>1. /\ d \in s.issued
            /\ Members(d) \cap (s.ack \cup {t}) # {}
      <4>1. /\ d \in s'.issued
              /\ Members(d)' \cap s'.ack # {}
        BY DEF CohortsOf
      <4>2. /\ s'.issued = s.issued
              /\ Members(d)' = Members(d)
        BY <2>2 DEF StateFields, Members
      <4> QED BY <2>2, <4>1, <4>2
    <3>2. d \in CohortsOf(s.ack) \/ t \in Members(d)
      BY <3>1 DEF CohortsOf
    <3>3. t \in Members(d) => d = c
      <4> SUFFICES ASSUME t \in Members(d)
                   PROVE d = c
        OBVIOUS
      <4>1. d \in CohortDomain
        BY <3>1, SafetyTypeOK DEF TypeOK, CohortStateTypes
      <4>2. t \in Members(c)
        BY <1>5 DEF ResolveDetached
      <4>3. t \in Members(c) \cap Members(d)
        BY <4>2
      <4> QED BY <4>1, <4>3, SafetyMembership
         DEF MembershipSafety, GroupPartition
    <3> QED BY <3>2, <3>3
  <2> QED BY <2>2, <2>3, <2>4, <2>5, ResolveAuthorityPreserves
<1>6. CASE ConcludeAbsent(t, c)
  <2>1. c \in s.headCalls \ s.published
    BY <1>6 DEF ConcludeAbsent
  <2>2. c \notin s.headBorrow
    BY <1>6, SafetyOwnership DEF Ownership, ConcludeAbsent, DrainedFor
  <2>3. c \notin s.projection
    BY <1>6, SafetyOwnership DEF Ownership, ConcludeAbsent, DrainedFor
  <2>4. /\ DOMAIN s' = StateFields
          /\ s'.absent = s.absent \cup {c}
          /\ s'.authority = s.authority \ {t}
          /\ s'.fenced = TRUE
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"absent", "authority", "fenced", "halted"} :
               s'[field] = s[field]
    BY <1>6, SafetyTypeOK, ConcludeAbsentProjection DEF TypeOK, StateShape
  <2> QED BY <2>1, <2>2, <2>3, <2>4, ConcludeAuthorityAbsentPreserves
<1>6a. CASE ResolveRejected(t, c)
  <2>1. s' = [s EXCEPT !.authority = s.authority \ {t}]
    BY <1>6a DEF ResolveRejected
  <2>2. /\ DOMAIN s' = StateFields
          /\ s'.authority = s.authority \ {t}
          /\ \A field \in StateFields \ {"authority"} : s'[field] = s[field]
    BY <2>1, SafetyTypeOK, AuthorityDropProjection DEF TypeOK, StateShape
  <2> QED BY <2>2, AuthorityDropPreserves
<1>7. CASE DetachUnknown(c)
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.owned = s.owned \ {c}
          /\ s'.unknown = s.unknown \ {c}
          /\ \A field \in StateFields \ {"owned", "unknown"} : s'[field] = s[field]
    BY <1>7, SafetyTypeOK, DetachUnknownProjection DEF TypeOK, StateShape
  <2> QED BY <1>7, <2>1, DetachUnknownPreserves DEF DetachUnknown
<1> QED BY <1>1, <1>2, <1>2a, <1>2b, <1>3, <1>4, <1>5, <1>6, <1>6a, <1>7

THEOREM LifecyclePreserves ==
    ASSUME NEW t \in MemberDomain,
        NEW c \in CohortDomain,
        ConstantsOK,
        Safety,
        CollectTerminal(t) \/ DeliverReceipt(t) \/ Export(t) \/ Import(t) \/ Drop(t) \/
            DiscardCollected(t) \/ Collect(c) \/
            RequestCancellation \/ BeginClose \/ Close \/ CrashAfterReturn \/ Reopen
    PROVE Safety'
<1>1. CASE CollectTerminal(t)
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.collected = s.collected \cup {t}
          /\ \A field \in StateFields \ {"collected"} : s'[field] = s[field]
    BY <1>1, SafetyTypeOK DEF CollectTerminal, TypeOK, StateShape, StateFields
  <2>2. /\ t \in s.admitted \ s.collected
          /\ t \in s.ack \cup s.rejected \cup s.authority \cup
               UNION {Members(c0) : c0 \in s.excluded}
    BY <1>1 DEF CollectTerminal
  <2>3. t \notin s.pending
    BY <2>2, SafetyMembership, SafetyPublication
       DEF MembershipSafety, BoundMembership, GroupPartition, AuthorityMembership,
           TerminalMembership, PublicationSafety, PublicationExclusion, BoundMembers, Members
  <2>4a. t \in s.ack => CohortsOf({t}) \subseteq s.headCalls
    BY SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationAcknowledgement, CohortsOf, Members
  <2>4b. t \in s.authority => CohortsOf({t}) \subseteq s.headCalls
    BY SafetyAuthority DEF AuthoritySafety, CohortsOf, Members
  <2>4c. t \in s.rejected => CohortsOf({t}) = {}
    BY SafetyMembership
       DEF MembershipSafety, GroupPartition, AuthorityMembership, BoundMembers, CohortsOf, Members
  <2>4d. t \in UNION {Members(c0) : c0 \in s.excluded} =>
          CohortsOf({t}) \subseteq s.excluded
    <3> SUFFICES ASSUME t \in UNION {Members(c0) : c0 \in s.excluded},
            NEW d \in CohortsOf({t})
        PROVE d \in s.excluded
      OBVIOUS
    <3>1. \E e \in s.excluded : t \in Members(e)
      BY DEF Members
    <3>2. PICK e \in s.excluded : t \in Members(e)
      BY <3>1
    <3>3. /\ d \in s.issued /\ t \in Members(d)
      BY DEF CohortsOf, Members
    <3>4. /\ d \in CohortDomain /\ e \in CohortDomain
      BY <3>2, <3>3, SafetyTypeOK, SafetyPublication
         DEF TypeOK, CohortStateTypes, PublicationSafety, PublicationExclusion
    <3>5a. d # e => Members(d) \cap Members(e) = {}
      BY <3>4, SafetyMembership DEF MembershipSafety, GroupPartition
    <3>5b. t \in Members(d) \cap Members(e)
      BY <3>2, <3>3
    <3>5. d = e
      BY <3>5a, <3>5b
    <3> QED BY <3>2, <3>5
  <2>4. CohortsOf({t}) \subseteq s.headCalls \cup s.excluded
    BY <2>2, <2>4a, <2>4b, <2>4c, <2>4d
  <2>5. (CohortsOf(s.collected))' = CohortsOf(s.collected) \cup CohortsOf({t})
    BY <2>1 DEF CohortsOf, Members, StateFields
  <2>6. LiveMembers' = LiveMembers \ {t}
    BY <2>1, <2>2 DEF LiveMembers, StateFields
  <2>7. TypeOK'
    BY <2>1, <2>2, SafetyTypeOK
       DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
           PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
  <2>8. MembershipSafety'
    BY <1>1, <2>1, <2>3, <2>4, <2>5, SafetyMembership
       DEF CollectTerminal, MembershipSafety, AdmissionMembership, BoundMembership,
           GroupPartition, AuthorityMembership, TerminalMembership, BoundMembers, Members,
           CohortsOf, Batches, StateFields
  <2>9. PublicationSafety'
    BY <2>1, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
           PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
           StateFields
  <2>10. Ownership'
    BY <1>1, <2>1, <2>2, SafetyOwnership
       DEF CollectTerminal, Ownership, Batches, Allocated, CohortsOf, Members, StateFields
  <2>11. PreparationOwnership'
    BY <2>1, SafetyPreparationOwnership
       DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
  <2>12a. LiveMembers' \subseteq LiveMembers
    BY <2>6
  <2>12b. IsFiniteSet(LiveMembers)
    BY SafetyTypeOK, FS_Subset DEF ConstantsOK, TypeOK, MemberStateTypes, LiveMembers
  <2>12c. Cardinality(LiveMembers') <= Cardinality(LiveMembers)
    BY <2>12a, <2>12b, FS_Subset
  <2>12d. Cardinality(s'.owned) <= Capacity /\ Cardinality(s'.ready) <= Capacity
    BY <2>1, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>12e. Cardinality(s'.headBorrow) <= 1 /\ Cardinality(s'.projection) <= 1
    BY <2>1, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>12f. Cardinality(s'.prepareBorrow) <= PrepareCapacity
    BY <2>1, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>12g. UsedBytes' = UsedBytes
    BY <2>1 DEF UsedBytes, StateFields
  <2>12h. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
    BY <2>12g, SafetyResourceBounds DEF ResourceBounds
  <2>12i. \A left, right \in Resources :
          left # right => s'.buffers[left] \cap s'.buffers[right] = {}
    BY <2>1, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>12j. Cardinality(LiveMembers) <= QueueCapacity
    BY SafetyResourceBounds DEF ResourceBounds
  <2>12k0. IsFiniteSet(LiveMembers')
    BY <2>12a, <2>12b, FS_Subset
  <2>12k1. /\ Cardinality(LiveMembers') \in Nat
             /\ Cardinality(LiveMembers) \in Nat
             /\ QueueCapacity \in Nat
    BY <2>12b, <2>12k0, FS_CardinalityType DEF ConstantsOK
  <2>12k. Cardinality(LiveMembers') <= QueueCapacity
    BY ONLY <2>12c, <2>12j, <2>12k1
  <2>12. ResourceBounds'
    BY <2>12d, <2>12e, <2>12f, <2>12h, <2>12i, <2>12k DEF ResourceBounds
  <2>13. AuthoritySafety'
    BY <2>1, SafetyAuthority DEF AuthoritySafety, CohortsOf, Members, StateFields
  <2> QED BY <2>7, <2>8, <2>9, <2>10, <2>11, <2>12, <2>13 DEF Safety
<1>2. CASE DeliverReceipt(t)
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.delivered = s.delivered \cup {t}
          /\ \A field \in StateFields \ {"delivered"} : s'[field] = s[field]
    BY <1>2, SafetyTypeOK DEF DeliverReceipt, TypeOK, StateShape, StateFields
  <2>2. /\ t \in s.collected /\ t \notin s.discarded
    BY <1>2 DEF DeliverReceipt
  <2>3. TypeOK'
    BY <2>1, <2>2, SafetyTypeOK
       DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
           PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
  <2>4. MembershipSafety'
    BY <2>1, <2>2, SafetyMembership
       DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
           AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
           Batches, StateFields
  <2>5. PublicationSafety'
    BY <2>1, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
           PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
           StateFields
  <2>6. Ownership'
    BY <2>1, SafetyOwnership
       DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
  <2>7. PreparationOwnership'
    BY <2>1, SafetyPreparationOwnership
       DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
  <2>8. ResourceBounds'
    BY <2>1, SafetyResourceBounds
       DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
  <2>9. AuthoritySafety'
    BY <2>1, <2>2, SafetyAuthority DEF AuthoritySafety, CohortsOf, Members, StateFields
  <2> QED BY <2>3, <2>4, <2>5, <2>6, <2>7, <2>8, <2>9 DEF Safety
<1>3. CASE Export(t)
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.exported = s.exported \cup {t}
          /\ \A field \in StateFields \ {"exported"} : s'[field] = s[field]
    BY <1>3, SafetyTypeOK DEF Export, TypeOK, StateShape, StateFields
  <2>2a. s'.authority = s.authority
    BY <2>1 DEF StateFields
  <2>2b. t \in s.authority
    BY <1>3 DEF Export
  <2>2. s'.authority \cup s'.exported = s.authority \cup s.exported
    BY ONLY <2>1, <2>2a, <2>2b
  <2>3. (CohortsOf(s.authority \cup s.exported))' =
          CohortsOf(s.authority \cup s.exported)
    BY <2>1, <2>2 DEF CohortsOf, Members, StateFields
  <2>4. TypeOK'
    BY <1>3, <2>1, SafetyTypeOK
       DEF Export, TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
           PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
  <2>5. MembershipSafety'
    BY <2>1, <2>2, SafetyMembership
       DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
           AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
           Batches, StateFields
  <2>6. PublicationSafety'
    BY <2>1, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
           PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
           StateFields
  <2>7. Ownership'
    BY <2>1, <2>3, SafetyOwnership
       DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
  <2>8. PreparationOwnership'
    BY <2>1, SafetyPreparationOwnership
       DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
  <2>9. ResourceBounds'
    BY <2>1, SafetyResourceBounds
       DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
  <2>10. AuthoritySafety'
    BY <1>3, <2>1, <2>2, <2>3, SafetyAuthority
       DEF Export, AuthoritySafety, CohortsOf, Members, StateFields
  <2> QED BY <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10 DEF Safety
<1>4. CASE Import(t)
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.authority = s.authority \cup {t}
          /\ \A field \in StateFields \ {"authority"} : s'[field] = s[field]
    BY <1>4, SafetyTypeOK DEF Import, TypeOK, StateShape, StateFields
  <2>2a. s'.exported = s.exported
    BY <2>1 DEF StateFields
  <2>2b. t \in s.exported
    BY <1>4 DEF Import
  <2>2. s'.authority \cup s'.exported = s.authority \cup s.exported
    BY ONLY <2>1, <2>2a, <2>2b
  <2>3. (CohortsOf(s.authority \cup s.exported))' =
          CohortsOf(s.authority \cup s.exported)
    BY <2>1, <2>2 DEF CohortsOf, Members, StateFields
  <2>4. t \notin s.discarded
    BY <1>4, SafetyAuthority, SafetyMembership
       DEF Import, AuthoritySafety, MembershipSafety, TerminalMembership
  <2>5. TypeOK'
    BY <1>4, <2>1, SafetyTypeOK
       DEF Import, TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
           PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
  <2>6. MembershipSafety'
    BY <2>1, <2>2, SafetyMembership
       DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
           AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
           Batches, StateFields
  <2>7. PublicationSafety'
    BY <2>1, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
           PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
           StateFields
  <2>8. Ownership'
    BY <2>1, <2>3, SafetyOwnership
       DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
  <2>9. PreparationOwnership'
    BY <2>1, SafetyPreparationOwnership
       DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
  <2>10. ResourceBounds'
    BY <2>1, SafetyResourceBounds
       DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
  <2>11. AuthoritySafety'
    BY <1>4, <2>1, <2>2, <2>3, <2>4, SafetyAuthority
       DEF Import, AuthoritySafety, CohortsOf, Members, StateFields
  <2> QED BY <2>5, <2>6, <2>7, <2>8, <2>9, <2>10, <2>11 DEF Safety
<1>5. CASE Drop(t)
  <2>1. s' = [s EXCEPT !.authority = s.authority \ {t}]
    BY <1>5 DEF Drop
  <2>2. /\ DOMAIN s' = StateFields
          /\ s'.authority = s.authority \ {t}
          /\ \A field \in StateFields \ {"authority"} : s'[field] = s[field]
    BY <2>1, SafetyTypeOK, AuthorityDropProjection DEF TypeOK, StateShape
  <2> QED BY <2>2, AuthorityDropPreserves
<1>6. CASE DiscardCollected(t)
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.authority = s.authority \ {t}
          /\ s'.discarded = s.discarded \cup {t}
          /\ \A field \in StateFields \ {"authority", "discarded"} : s'[field] = s[field]
    BY <1>6, SafetyTypeOK DEF DiscardCollected, TypeOK, StateShape, StateFields
  <2>2. /\ t \in s.collected /\ t \notin s.delivered /\ t \notin s.discarded
    BY <1>6 DEF DiscardCollected
  <2>3. (CohortsOf(s.authority \cup s.exported))' \subseteq
          CohortsOf(s.authority \cup s.exported)
    BY <2>1 DEF CohortsOf, Members, StateFields
  <2>4. TypeOK'
    BY <2>1, <2>2, SafetyTypeOK, FS_Subset
       DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
           PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
  <2>5. MembershipSafety'
    BY <2>1, <2>2, SafetyMembership, FS_Subset
       DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
           AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
           Batches, StateFields
  <2>6. PublicationSafety'
    BY <2>1, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
           PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
           StateFields
  <2>7. Ownership'
    BY <2>1, <2>3, SafetyOwnership, FS_Subset
       DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
  <2>8. PreparationOwnership'
    BY <2>1, SafetyPreparationOwnership
       DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
  <2>9. ResourceBounds'
    BY <2>1, SafetyResourceBounds
       DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
  <2>10. AuthoritySafety'
    BY <2>1, <2>2, <2>3, SafetyAuthority, FS_Subset
       DEF AuthoritySafety, CohortsOf, Members, StateFields
  <2> QED BY <2>4, <2>5, <2>6, <2>7, <2>8, <2>9, <2>10 DEF Safety
<1>7. CASE Collect(c)
  <2>1. /\ DOMAIN s' = StateFields
          /\ DOMAIN s'.buffers = Resources
          /\ s'.buffers[Batch(c)] = {}
          /\ (\A resource \in Resources \ {Batch(c)} :
                s'.buffers[resource] = s.buffers[resource])
          /\ \A field \in StateFields \ {"buffers"} : s'[field] = s[field]
    BY <1>7, SafetyTypeOK
       DEF Collect, TypeOK, StateShape, PreparationMapTypes, StateFields, Resources, Batches,
           Batch
  <2>1a. s'.buffers = [s.buffers EXCEPT ![Batch(c)] = {}]
    BY <1>7, SafetyTypeOK, FunctionExceptAtSame
       DEF Collect, TypeOK, StateShape, StateFields
  <2>1b. Batch(c) \in Resources
    BY DEF Resources, Batches, Batch
  <2>2. \A resource \in Resources : s'.buffers[resource] \subseteq s.buffers[resource]
    BY <2>1
  <2>3. Allocated' = Allocated \ {Batch(c)}
    BY <2>1 DEF Allocated
  <2>4. UsedBytes' \subseteq UsedBytes
    BY <2>2 DEF UsedBytes
  <2>5. Batch(c) \notin Batches(s.owned \cup CohortsOf(s.authority \cup s.exported))
    BY <1>7 DEF Collect, Batches, Batch
  <2>6. \A t0 \in MemberDomain :
          Input(t0) # Batch(c) /\ Fragment(t0) # Batch(c)
    BY DEF Input, Fragment, Batch
  <2>7a. StateShape'
    BY <2>1 DEF StateShape
  <2>7b0. MemberStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>7b. MemberStateTypes'
    BY ONLY <2>1, <2>7b0 DEF MemberStateTypes, StateFields
  <2>7c0. PreparationMapTypes
    BY SafetyTypeOK DEF TypeOK
  <2>7c1. s'.groups \in [CohortDomain -> SUBSET MemberDomain]
    BY ONLY <2>1, <2>7c0 DEF PreparationMapTypes, StateFields
  <2>7c2a. \A resource \in Resources : s.buffers[resource] \subseteq ByteDomain
    BY <2>7c0 DEF PreparationMapTypes
  <2>7c2b. \A resource \in Resources : s'.buffers[resource] \subseteq ByteDomain
    BY <2>2, <2>7c2a
  <2>7c2. s'.buffers \in [Resources -> SUBSET ByteDomain]
    BY <2>1a, <2>1b, <2>7c0 DEF PreparationMapTypes
  <2>7c3. s'.prepareCalls \subseteq Work
    BY ONLY <2>1, <2>7c0 DEF PreparationMapTypes, StateFields
  <2>7c4. s'.prepareBorrow \subseteq Work
    BY ONLY <2>1, <2>7c0 DEF PreparationMapTypes, StateFields
  <2>7c. PreparationMapTypes'
    BY <2>7c1, <2>7c2, <2>7c3, <2>7c4 DEF PreparationMapTypes
  <2>7d0. CohortStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>7d. CohortStateTypes'
    BY ONLY <2>1, <2>7d0 DEF CohortStateTypes, StateFields
  <2>7e0. PublicationStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>7e. PublicationStateTypes'
    BY ONLY <2>1, <2>7e0 DEF PublicationStateTypes, StateFields
  <2>7f0. AuthorityStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>7f. AuthorityStateTypes'
    BY ONLY <2>1, <2>7f0 DEF AuthorityStateTypes, StateFields
  <2>7g0. LifecycleStateTypes
    BY SafetyTypeOK DEF TypeOK
  <2>7g. LifecycleStateTypes'
    BY ONLY <2>1, <2>7g0 DEF LifecycleStateTypes, StateFields
  <2>7. TypeOK'
    BY <2>7a, <2>7b, <2>7c, <2>7d, <2>7e, <2>7f, <2>7g DEF TypeOK
  <2>8. MembershipSafety'
    BY <2>1, SafetyMembership
       DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
           AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
           Batches, StateFields
  <2>9. PublicationSafety'
    BY <2>1, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
           PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
           StateFields
  <2>10. Ownership'
    BY <2>1, <2>3, <2>5, SafetyOwnership
       DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
  <2>11a. s'.prepareBorrow \subseteq s'.prepareCalls \cap Allocated'
    BY <1>7, <2>1, <2>3, SafetyPreparationOwnership
       DEF Collect, PreparationOwnership, StateFields
  <2>11b. \A t0 \in MemberDomain :
          Fragment(t0) \in s'.prepareBorrow =>
              Input(t0) \in Allocated' /\ t0 \in s'.admitted \ BoundMembers'
    BY <2>1, <2>3, <2>6, SafetyPreparationOwnership
       DEF PreparationOwnership, BoundMembers, Members, StateFields
  <2>11c. \A c0 \in CohortDomain :
          Batch(c0) \in s'.prepareBorrow =>
              c0 \in s'.owned /\ Fragments((Members(c0))') \subseteq Allocated'
    <3> SUFFICES ASSUME NEW c0 \in CohortDomain,
            Batch(c0) \in s'.prepareBorrow
        PROVE c0 \in s'.owned /\ Fragments((Members(c0))') \subseteq Allocated'
      OBVIOUS
    <3>1. /\ c0 \in s.owned /\ Fragments(Members(c0)) \subseteq Allocated
      BY <2>1, SafetyPreparationOwnership DEF PreparationOwnership, StateFields
    <3>2. /\ s'.owned = s.owned /\ (Members(c0))' = Members(c0)
      BY <2>1 DEF Members, StateFields
    <3>3a. {Batch(c)} = Batches({c})
      BY DEF Batches
    <3>3. Fragments(Members(c0)) \cap {Batch(c)} = {}
      BY <3>3a, BatchFragmentDisjoint
    <3>4. Fragments(Members(c0)) \subseteq Allocated'
      BY <2>3, <3>1, <3>3
    <3> QED BY <3>1, <3>2, <3>4
  <2>11d. \A t0 \in s'.prepared :
          Fragment(t0) \in s'.prepareCalls \ s'.prepareBorrow
    BY <2>1, SafetyPreparationOwnership DEF PreparationOwnership, StateFields
  <2>11e. \A t0 \in s'.prepared : Input(t0) \notin Allocated'
    BY <2>1, <2>3, SafetyPreparationOwnership DEF PreparationOwnership, StateFields
  <2>11f. \A c0 \in s'.sealed : Batch(c0) \in s'.prepareCalls \ s'.prepareBorrow
    BY <2>1, SafetyPreparationOwnership DEF PreparationOwnership, StateFields
  <2>11g. \A t0 \in MemberDomain :
          Input(t0) \in Allocated' =>
              t0 \in s'.pending \/ Fragment(t0) \in s'.prepareBorrow
    BY <2>1, <2>3, SafetyPreparationOwnership DEF PreparationOwnership, StateFields
  <2>11. PreparationOwnership'
    BY <2>11a, <2>11b, <2>11c, <2>11d, <2>11e, <2>11f, <2>11g
       DEF PreparationOwnership
  <2>12a. Cardinality(LiveMembers') <= QueueCapacity
    BY <2>1, SafetyResourceBounds DEF ResourceBounds, LiveMembers, StateFields
  <2>12b. Cardinality(s'.owned) <= Capacity /\ Cardinality(s'.ready) <= Capacity
    BY <2>1, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>12c. Cardinality(s'.headBorrow) <= 1 /\ Cardinality(s'.projection) <= 1
    BY <2>1, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>12d. Cardinality(s'.prepareBorrow) <= PrepareCapacity
    BY <2>1, SafetyResourceBounds DEF ResourceBounds, StateFields
  <2>12e. UsedBytes' \subseteq ByteDomain
    BY <2>7 DEF TypeOK, PreparationMapTypes, UsedBytes, Resources
  <2>12f. IsFiniteSet(ByteDomain)
    BY DEF ConstantsOK
  <2>12g. Cardinality(UsedBytes') <= Cardinality(ByteDomain)
    BY <2>12e, <2>12f, FS_Subset
  <2>12h. \A left, right \in Resources :
          left # right => s'.buffers[left] \cap s'.buffers[right] = {}
    BY <2>2, SafetyResourceBounds DEF ResourceBounds
  <2>12. ResourceBounds'
    BY <2>12a, <2>12b, <2>12c, <2>12d, <2>12g, <2>12h DEF ResourceBounds
  <2>13. AuthoritySafety'
    BY <2>1, SafetyAuthority DEF AuthoritySafety, CohortsOf, Members, StateFields
  <2> QED BY <2>7, <2>8, <2>9, <2>10, <2>11, <2>12, <2>13 DEF Safety
<1>8. CASE RequestCancellation
  <2>1. s' = s
    BY <1>8 DEF RequestCancellation
  <2> QED BY <2>1, SafetyStuttering
<1>9. CASE BeginClose
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.closing = TRUE
          /\ \A field \in StateFields \ {"closing"} : s'[field] = s[field]
    BY <1>9, SafetyTypeOK DEF BeginClose, TypeOK, StateShape, StateFields
  <2>2. TypeOK'
    BY <2>1, SafetyTypeOK
       DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
           PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
  <2>3. MembershipSafety'
    BY <2>1, SafetyMembership
       DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
           AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
           Batches, StateFields
  <2>4. PublicationSafety'
    BY <2>1, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
           PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
           StateFields
  <2>5. Ownership'
    BY <2>1, SafetyOwnership
       DEF Ownership, Batches, Allocated, CohortsOf, Members, StateFields
  <2>6. PreparationOwnership'
    BY <2>1, SafetyPreparationOwnership
       DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
  <2>7. ResourceBounds'
    BY <2>1, SafetyResourceBounds
       DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
  <2>8. AuthoritySafety'
    BY <2>1, SafetyAuthority DEF AuthoritySafety, CohortsOf, Members, StateFields
  <2> QED BY <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8 DEF Safety
<1>10. CASE Close
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.online = FALSE
          /\ \A field \in StateFields \ {"online"} : s'[field] = s[field]
    BY <1>10, SafetyTypeOK DEF Close, TypeOK, StateShape, StateFields
  <2>2. TypeOK'
    BY <2>1, SafetyTypeOK
       DEF TypeOK, StateShape, MemberStateTypes, PreparationMapTypes, CohortStateTypes,
           PublicationStateTypes, AuthorityStateTypes, LifecycleStateTypes, StateFields
  <2>3. MembershipSafety'
    BY <2>1, SafetyMembership
       DEF MembershipSafety, AdmissionMembership, BoundMembership, GroupPartition,
           AuthorityMembership, TerminalMembership, BoundMembers, Members, CohortsOf,
           Batches, StateFields
  <2>4. PublicationSafety'
    BY <2>1, SafetyPublication
       DEF PublicationSafety, PublicationOrder, PublicationExclusion,
           PublicationPredecessorOrder, PublicationAcknowledgement, CohortsOf, Members,
           StateFields
  <2>5. Ownership'
    BY <1>10, <2>1, SafetyOwnership
       DEF Close, Ownership, Batches, Allocated, CohortsOf, Members, StateFields
  <2>6. PreparationOwnership'
    BY <2>1, SafetyPreparationOwnership
       DEF PreparationOwnership, Allocated, BoundMembers, Members, StateFields
  <2>7. ResourceBounds'
    BY <2>1, SafetyResourceBounds
       DEF ResourceBounds, UsedBytes, LiveMembers, StateFields
  <2>8. AuthoritySafety'
    BY <2>1, SafetyAuthority DEF AuthoritySafety, CohortsOf, Members, StateFields
  <2> QED BY <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8 DEF Safety
<1>11. CASE CrashAfterReturn
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.online = FALSE
          /\ s'.closing = TRUE
          /\ s'.halted = TRUE
          /\ s'.authority = {}
          /\ \A field \in StateFields \
               {"online", "closing", "halted", "authority"} : s'[field] = s[field]
    BY <1>11, SafetyTypeOK DEF CrashAfterReturn, TypeOK, StateShape, StateFields
  <2> QED BY <1>11, <2>1, SafetyTypeOK, SafetyPublication, LifecycleFramePreserves
      DEF CrashAfterReturn, TypeOK, LifecycleStateTypes, PublicationSafety, PublicationOrder,
          StateFields
<1>12. CASE Reopen
  <2>1. /\ DOMAIN s' = StateFields
          /\ s'.online = TRUE
          /\ s'.retired = s.published
          /\ s'.halted = TRUE
          /\ \A field \in StateFields \ {"online", "retired", "halted"} :
               s'[field] = s[field]
    BY <1>12, SafetyTypeOK DEF Reopen, TypeOK, StateShape, StateFields
  <2> QED BY <1>12, <2>1, SafetyTypeOK, SafetyPublication, LifecycleFramePreserves
      DEF Reopen, TypeOK, LifecycleStateTypes, PublicationSafety, PublicationOrder, StateFields
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9, <1>10,
    <1>11, <1>12

THEOREM NextPreserves ==
    ASSUME ConstantsOK, Safety, Next
    PROVE Safety'
<1>1. CASE (\E t \in MemberDomain, bytes \in SUBSET ByteDomain :
               Admit(t, bytes) \/ StartTxnPrepare(t, bytes))
  BY <1>1, AdmissionPreparationPreserves
<1>2. CASE \E c \in CohortDomain, ts \in SUBSET MemberDomain, bytes \in SUBSET ByteDomain :
              Freeze(c, ts, bytes)
  BY <1>2, FreezePreserves
<1>3. CASE \E t \in MemberDomain, success \in BOOLEAN : JoinTxnPrepare(t, success)
  BY <1>3, AdmissionPreparationPreserves
<1>4. CASE \E c \in CohortDomain, success \in BOOLEAN : JoinBatchPrepare(c, success)
  BY <1>4, BatchPreparationPreserves
<1>5. CASE \E c \in CohortDomain, entered \in BOOLEAN :
              JoinBatch(c, entered) \/ ValidateFront(c, entered) \/ Retire(c, entered)
  BY <1>5, PublicationPreserves DEF ConstantsOK
<1>6. CASE \E c \in CohortDomain, entered, uncertain \in BOOLEAN :
              JoinHead(c, entered, uncertain)
  BY <1>6, PublicationPreserves
<1>7. CASE \E c \in CohortDomain : StartBatchPrepare(c)
  <2>1. PICK d \in CohortDomain : StartBatchPrepare(d)
    BY <1>7
  <2>2. FALSE \in BOOLEAN
    OBVIOUS
  <2> QED BY <2>1, <2>2, BatchPreparationPreserves DEF ConstantsOK
<1>8. CASE \E c \in CohortDomain : StartBatch(c) \/ StartHead(c)
  <2>1. PICK d \in CohortDomain : StartBatch(d) \/ StartHead(d)
    BY <1>8
  <2>2. FALSE \in BOOLEAN
    OBVIOUS
  <2> QED BY <2>1, <2>2, PublicationPreserves DEF ConstantsOK
<1>9. CASE \E c \in CohortDomain : FailPreparedFront(c) \/ FailBatchFront(c) \/
              MarkAbandoned(c) \/ DrainAbandoned(c) \/ DetachUnknown(c)
  BY <1>9, DrainResolutionPreserves DEF ConstantsOK
<1>10. CASE \E c \in CohortDomain : Collect(c)
  BY <1>10, LifecyclePreserves DEF ConstantsOK
<1>11. CASE \E t \in MemberDomain, c \in CohortDomain :
               ResolveFront(t, c) \/ ResolveDetached(t, c) \/ ConcludeAbsent(t, c) \/
               ResolveRejected(t, c)
  BY <1>11, DrainResolutionPreserves
<1>12. CASE \E t \in MemberDomain : CollectTerminal(t) \/ DeliverReceipt(t) \/ Export(t) \/
               Import(t) \/ Drop(t) \/ DiscardCollected(t)
  BY <1>12, LifecyclePreserves DEF ConstantsOK
<1>13. CASE AbandonPending
  BY <1>13, DrainResolutionPreserves DEF ConstantsOK
<1>14. CASE RequestCancellation \/ BeginClose \/ Close \/ CrashAfterReturn \/ Reopen
  BY <1>14, LifecyclePreserves DEF ConstantsOK
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9,
    <1>10, <1>11, <1>12, <1>13, <1>14 DEF Next

THEOREM StutteringPreserves ==
    ASSUME ConstantsOK, Safety, UNCHANGED vars
    PROVE Safety'
<1>1. s' = s
  BY DEF vars
<1>2. TypeOK'
  BY <1>1, SafetyTypeOK, TypeOKStuttering
<1>3. MembershipSafety'
  BY <1>1, SafetyMembership, MembershipSafetyStuttering
<1>4. PublicationSafety'
  BY <1>1, SafetyPublication, PublicationSafetyStuttering
<1>5. Ownership'
  BY <1>1, SafetyOwnership, OwnershipStuttering
<1>6. PreparationOwnership'
  BY <1>1, SafetyPreparationOwnership, PreparationOwnershipStuttering
<1>7. ResourceBounds'
  BY <1>1, SafetyResourceBounds, ResourceBoundsStuttering
<1>8. AuthoritySafety'
  BY <1>1, SafetyAuthority, AuthoritySafetyStuttering
<1> QED BY <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8 DEF Safety

THEOREM SpecSafety ==
    ASSUME ConstantsOK
    PROVE Spec => []Safety
<1>1. Init => Safety
  BY InitSafety
<1>2. Safety /\ [Next]_vars => Safety'
  BY NextPreserves, StutteringPreserves DEF vars
<1> QED BY <1>1, <1>2, PTL DEF Spec
=============================================================================
