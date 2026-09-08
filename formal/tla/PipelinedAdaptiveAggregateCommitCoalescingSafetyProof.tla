------ MODULE PipelinedAdaptiveAggregateCommitCoalescingSafetyProof ------
EXTENDS FiniteSetTheorems, Naturals, TLAPS

(***************************************************************************
Unqualified source proof kernel. Cohort/member domains and capacity are
arbitrary finite parameters, not the concrete model's three/two geometry.
MemberOf is the already-frozen disjoint membership ledger; Rank represents
the preceding admission layer's immutable order. The kernel abstracts bytes,
tokens, fallible local installation, scheduling and response transport.
ConcludeAbsent is the trusted exact-successor observation boundary, not a
missing-object observation.

Published cohorts form an ordered prefix. Borrowed buffers remain owned until
join; unknown authority is independent of pipeline ownership and survives
close/export/import. Successful active-front resolution and retirement are
atomic in this kernel; the finite model splits observation and fallible local
installation. This is a safety kernel, not a refinement or liveness proof.
***************************************************************************)

CONSTANTS CohortDomain, MemberDomain, MemberOf, Rank, Capacity
ConstantsOK ==
    /\ IsFiniteSet(CohortDomain) /\ IsFiniteSet(MemberDomain)
    /\ CohortDomain # {} /\ MemberDomain # {} /\ Capacity \in Nat \ {0}
    /\ MemberOf \in [MemberDomain -> CohortDomain] /\ Rank \in [CohortDomain -> Nat]
    /\ \A c, d \in CohortDomain : Rank[c] = Rank[d] => c = d
    /\ \A c \in CohortDomain : \E t \in MemberDomain : MemberOf[t] = c
Earlier(c) == {d \in CohortDomain : Rank[d] < Rank[c]}
Members(c) == {t \in MemberDomain : MemberOf[t] = c}
CohortsOf(members) == {MemberOf[t] : t \in members}

VARIABLE s
vars == <<s>>

Init ==
    s = [issued |-> {}, stored |-> {}, published |-> {}, retired |-> {},
         excluded |-> {}, batchCalls |-> {}, headCalls |-> {},
         batchBorrow |-> {}, headBorrow |-> {}, owned |-> {}, allocated |-> {},
         unknown |-> {}, absent |-> {}, authority |-> {}, exported |-> {}, ack |-> {},
         closing |-> FALSE, online |-> TRUE, fenced |-> FALSE, resolutionWrites |-> 0]

Freeze(c) ==
    /\ s.online /\ ~s.closing /\ ~s.fenced /\ s.unknown = {}
    /\ c \in CohortDomain \ s.issued /\ Earlier(c) \subseteq s.issued
    /\ Cardinality(s.owned) < Capacity
    /\ s' = [s EXCEPT !.issued = @ \cup {c}, !.owned = @ \cup {c}, !.allocated = @ \cup {c}]

StartBatch(c) ==
    /\ c \in s.owned \ s.batchCalls /\ ~s.closing /\ ~s.fenced
    /\ s' = [s EXCEPT !.batchCalls = @ \cup {c}, !.batchBorrow = @ \cup {c}]

JoinBatch(c, entered) ==
    /\ c \in s.batchBorrow /\ entered \in BOOLEAN
    /\ s' = [s EXCEPT !.batchBorrow = @ \ {c}, !.stored = IF entered THEN @ \cup {c} ELSE @]

StartHead(c) ==
    /\ s.online /\ ~s.closing /\ ~s.fenced /\ s.unknown = {} /\ s.headBorrow = {}
    /\ c \in s.owned \cap s.stored /\ c \notin s.headCalls \cup s.batchBorrow
    /\ Earlier(c) \subseteq s.retired
    /\ s' = [s EXCEPT !.headCalls = @ \cup {c}, !.headBorrow = {c}]

JoinHead(c, entered) ==
    /\ c \in s.headBorrow /\ entered \in BOOLEAN
    /\ s' = [s EXCEPT !.headBorrow = {}, !.unknown = @ \cup {c},
          !.published = IF entered THEN @ \cup {c} ELSE @,
          !.authority = @ \cup Members(c)]

Retire(c, localFailure) ==
    /\ c \in s.unknown \cap s.published /\ localFailure \in BOOLEAN
    /\ s' = [s EXCEPT !.unknown = @ \ {c}, !.owned = @ \ {c}, !.retired = @ \cup {c},
          !.ack = @ \cup Members(c), !.authority = @ \ Members(c), !.fenced = @ \/ localFailure]

ResolveFront(t) ==
    /\ s.online /\ t \in s.authority
    /\ MemberOf[t] \in s.unknown \cap s.published
    /\ s' = [s EXCEPT !.unknown = @ \ {MemberOf[t]},
          !.owned = @ \ {MemberOf[t]}, !.retired = @ \cup {MemberOf[t]},
          !.ack = @ \cup {t}, !.authority = @ \ {t}]

ResolveDetached(t) ==
    /\ s.online /\ t \in s.authority
    /\ MemberOf[t] \in s.retired
    /\ s' = [s EXCEPT !.ack = @ \cup {t}, !.authority = @ \ {t}]

ConcludeAbsent(c) ==
    /\ c \in s.unknown \ s.published /\ c \notin s.headBorrow
    /\ s' = [s EXCEPT !.absent = @ \cup {c}, !.fenced = TRUE]

Abandon(c) ==
    /\ c \in s.owned /\ c \notin s.batchBorrow \cup s.headBorrow
    /\ s.closing \/ s.fenced \/ Earlier(c) \cap s.excluded # {}
    /\ c \notin s.headCalls \/ c \in s.absent
    /\ s' = [s EXCEPT !.owned = @ \ {c}, !.unknown = @ \ {c}, !.excluded = @ \cup {c}]

RequestCancellation == UNCHANGED s
BeginClose == s' = [s EXCEPT !.closing = TRUE]

DetachUnknown(c) ==
    /\ s.closing /\ c \in s.unknown /\ c \notin s.batchBorrow \cup s.headBorrow
    /\ s' = [s EXCEPT !.owned = @ \ {c}, !.unknown = @ \ {c}]

Export(t) ==
    /\ t \in s.authority
    /\ s' = [s EXCEPT !.exported = @ \cup {t}]
Import(t) ==
    /\ s.online /\ t \in s.exported
    /\ s' = [s EXCEPT !.authority = @ \cup {t}]
Drop(t) ==
    /\ t \in s.authority
    /\ s' = [s EXCEPT !.authority = @ \ {t}]
Collect(c) ==
    /\ c \in s.allocated \ s.owned
    /\ c \notin CohortsOf(s.authority \cup s.exported)
    /\ c \notin s.batchBorrow \cup s.headBorrow
    /\ s' = [s EXCEPT !.allocated = @ \ {c}]

Close ==
    /\ s.closing /\ s.owned = {} /\ s.batchBorrow = {} /\ s.headBorrow = {}
    /\ s' = [s EXCEPT !.online = FALSE]
CrashAfterReturn ==
    /\ s.owned = {} /\ s.batchBorrow = {} /\ s.headBorrow = {}
    /\ s' = [s EXCEPT !.online = FALSE, !.closing = TRUE, !.authority = {}]
Reopen ==
    /\ ~s.online
    /\ s' = [s EXCEPT !.online = TRUE, !.retired = s.published]

Next ==
    \/ \E c \in CohortDomain : Freeze(c) \/ StartBatch(c) \/ StartHead(c)
         \/ ConcludeAbsent(c) \/ Abandon(c) \/ DetachUnknown(c) \/ Collect(c)
    \/ \E c \in CohortDomain, entered \in BOOLEAN :
         JoinBatch(c, entered) \/ JoinHead(c, entered) \/ Retire(c, entered)
    \/ \E t \in MemberDomain : ResolveFront(t) \/ ResolveDetached(t)
         \/ Export(t) \/ Import(t) \/ Drop(t)
    \/ RequestCancellation \/ BeginClose \/ Close \/ CrashAfterReturn \/ Reopen
Spec == Init /\ [][Next]_vars

TypeOK ==
    s \in [issued : SUBSET CohortDomain, stored : SUBSET CohortDomain,
           published : SUBSET CohortDomain, retired : SUBSET CohortDomain,
           excluded : SUBSET CohortDomain, batchCalls : SUBSET CohortDomain,
           headCalls : SUBSET CohortDomain, batchBorrow : SUBSET CohortDomain,
           headBorrow : SUBSET CohortDomain, owned : SUBSET CohortDomain,
           allocated : SUBSET CohortDomain, unknown : SUBSET CohortDomain,
           absent : SUBSET CohortDomain, authority : SUBSET MemberDomain,
           exported : SUBSET MemberDomain, ack : SUBSET MemberDomain,
           closing : BOOLEAN, online : BOOLEAN, fenced : BOOLEAN,
           resolutionWrites : Nat]
PublicationSafety ==
    /\ s.retired \subseteq s.published /\ s.published \subseteq s.headCalls
    /\ s.headCalls \subseteq s.stored
    /\ s.stored \subseteq s.batchCalls /\ s.batchCalls \cup s.headCalls \subseteq s.issued
    /\ s.excluded \subseteq s.issued /\ s.excluded \cap s.owned = {}
    /\ \A c \in s.headCalls : Earlier(c) \subseteq s.retired
    /\ CohortsOf(s.ack) \subseteq s.published
    /\ s.excluded \cap s.published = {} /\ s.absent \cap s.published = {}
Ownership ==
    /\ s.owned \subseteq s.issued /\ s.allocated \subseteq s.issued
    /\ s.owned \cup CohortsOf(s.authority \cup s.exported) \subseteq s.allocated
    /\ s.batchBorrow \cup s.headBorrow \subseteq s.owned
    /\ s.batchBorrow \subseteq s.batchCalls /\ s.headBorrow \subseteq s.headCalls
    /\ s.batchBorrow \cap s.stored = {} /\ s.headBorrow \cap s.published = {}
    /\ s.unknown \subseteq (s.owned \cap s.headCalls) \ s.headBorrow
    /\ s.absent \subseteq s.headCalls \ s.headBorrow
    /\ Cardinality(s.owned) <= Capacity /\ Cardinality(s.headBorrow) <= 1
    /\ s.headBorrow # {} => s.unknown = {}
    /\ ~s.online => s.owned = {} /\ s.batchBorrow = {} /\ s.headBorrow = {}
AuthoritySafety ==
    /\ CohortsOf(s.authority \cup s.exported) \subseteq s.headCalls \ s.headBorrow
    /\ s.resolutionWrites = 0
Safety == TypeOK /\ PublicationSafety /\ Ownership /\ AuthoritySafety

THEOREM CohortsOfEmpty == CohortsOf({}) = {}
BY DEF CohortsOf

THEOREM CohortsOfUnion ==
    \A left, right \in SUBSET MemberDomain :
      CohortsOf(left \cup right) = CohortsOf(left) \cup CohortsOf(right)
BY DEF CohortsOf

THEOREM CohortsOfDifference ==
    \A left, right \in SUBSET MemberDomain :
      CohortsOf(left \ right) \subseteq CohortsOf(left)
BY DEF CohortsOf

THEOREM CohortsOfMonotonic ==
    \A left, right \in SUBSET MemberDomain :
      left \subseteq right => CohortsOf(left) \subseteq CohortsOf(right)
BY DEF CohortsOf

THEOREM MembersAreMembers ==
    ConstantsOK => \A c \in CohortDomain : Members(c) \subseteq MemberDomain
BY DEF ConstantsOK, Members

THEOREM CohortsOfMembers ==
    ConstantsOK => \A c \in CohortDomain : CohortsOf(Members(c)) = {c}
BY DEF ConstantsOK, CohortsOf, Members

THEOREM CohortsOfSingleton ==
    \A t \in MemberDomain : CohortsOf({t}) = {MemberOf[t]}
BY DEF CohortsOf

THEOREM FiniteCohortSubset ==
    ConstantsOK => \A subset \in SUBSET CohortDomain : IsFiniteSet(subset)
BY FS_Subset DEF ConstantsOK

THEOREM AddWithinCapacity ==
    ASSUME NEW owned \in SUBSET CohortDomain,
           NEW c \in CohortDomain,
           ConstantsOK,
           c \notin owned,
           Cardinality(owned) < Capacity
    PROVE Cardinality(owned \cup {c}) <= Capacity
<1>1. IsFiniteSet(owned)
  BY FS_Subset DEF ConstantsOK
<1>2. Cardinality(owned \cup {c}) = Cardinality(owned) + 1
  BY <1>1, FS_AddElement
<1> QED BY <1>1, <1>2, FS_CardinalityType DEF ConstantsOK

THEOREM RemoveWithinCapacity ==
    ASSUME NEW owned \in SUBSET CohortDomain,
           NEW c \in CohortDomain,
           ConstantsOK,
           Cardinality(owned) <= Capacity
    PROVE Cardinality(owned \ {c}) <= Capacity
<1>1. IsFiniteSet(owned)
  BY FS_Subset DEF ConstantsOK
<1>2. Cardinality(owned \ {c}) =
        IF c \in owned THEN Cardinality(owned) - 1 ELSE Cardinality(owned)
  BY <1>1, FS_RemoveElement
<1> QED BY <1>1, <1>2, FS_CardinalityType DEF ConstantsOK

THEOREM InitSafety == ConstantsOK /\ Init => Safety
BY FS_EmptySet, CohortsOfEmpty DEF ConstantsOK, Init, Safety, TypeOK,
       PublicationSafety, Ownership, AuthoritySafety, CohortsOf, Earlier

THEOREM FreezePreserves ==
    \A c \in CohortDomain : ConstantsOK /\ Safety /\ Freeze(c) => Safety'
BY AddWithinCapacity DEF ConstantsOK, Freeze, Safety, TypeOK,
       PublicationSafety, Ownership, AuthoritySafety, CohortsOf, Earlier

THEOREM StartBatchPreserves ==
    \A c \in CohortDomain : ConstantsOK /\ Safety /\ StartBatch(c) => Safety'
BY DEF ConstantsOK, StartBatch, Safety, TypeOK, PublicationSafety, Ownership,
       AuthoritySafety, CohortsOf, Earlier

THEOREM JoinBatchPreserves ==
    \A c \in CohortDomain, entered \in BOOLEAN :
      ConstantsOK /\ Safety /\ JoinBatch(c, entered) => Safety'
BY DEF ConstantsOK, StartBatch, JoinBatch, Safety, TypeOK, PublicationSafety,
       Ownership, AuthoritySafety, CohortsOf, Earlier

THEOREM StartHeadPreserves ==
    \A c \in CohortDomain : ConstantsOK /\ Safety /\ StartHead(c) => Safety'
BY FS_EmptySet, FS_Singleton DEF ConstantsOK, StartHead, Safety, TypeOK,
       PublicationSafety, Ownership, AuthoritySafety, CohortsOf, Earlier,
       Members

THEOREM JoinHeadPreserves ==
    \A c \in CohortDomain, entered \in BOOLEAN :
      ConstantsOK /\ Safety /\ JoinHead(c, entered) => Safety'
BY FS_EmptySet, FS_Singleton DEF ConstantsOK, StartHead, JoinHead, Safety,
       TypeOK, PublicationSafety, Ownership, AuthoritySafety, CohortsOf,
       Earlier, Members

THEOREM RetirementRetainsBorrowOwnership ==
    \A c \in CohortDomain, entered \in BOOLEAN :
      ConstantsOK /\ Safety /\ Retire(c, entered) =>
        s.batchBorrow \cup s.headBorrow \subseteq s.owned \ {c}
BY DEF ConstantsOK, Retire, Safety, TypeOK, PublicationSafety, Ownership,
       AuthoritySafety

THEOREM RetirementRetainsAllocationOwnership ==
    \A c \in CohortDomain, entered \in BOOLEAN :
      ConstantsOK /\ Safety /\ Retire(c, entered) =>
        (s.owned \ {c}) \cup
          CohortsOf((s.authority \ Members(c)) \cup s.exported) \subseteq s.allocated
BY CohortsOfMonotonic DEF ConstantsOK, Retire, Safety, TypeOK,
       PublicationSafety, Ownership, AuthoritySafety, CohortsOf, Members

THEOREM DurableRetirementPreserves ==
    \A c \in CohortDomain, entered \in BOOLEAN :
      ConstantsOK /\ Safety /\ Retire(c, entered) => Safety'
<1>1. \A c \in CohortDomain, entered \in BOOLEAN :
       ConstantsOK /\ Safety /\ Retire(c, entered) => TypeOK'
  BY MembersAreMembers DEF ConstantsOK, Retire, Safety, TypeOK,
      PublicationSafety, Ownership, AuthoritySafety, Members
<1>2. \A c \in CohortDomain, entered \in BOOLEAN :
       ConstantsOK /\ Safety /\ Retire(c, entered) => PublicationSafety'
  BY CohortsOfUnion, CohortsOfMembers DEF ConstantsOK, Retire, Safety,
      TypeOK, PublicationSafety, Ownership, AuthoritySafety, CohortsOf,
      Earlier, Members
<1>3. \A c \in CohortDomain, entered \in BOOLEAN :
       ConstantsOK /\ Safety /\ Retire(c, entered) => Ownership'
  BY RemoveWithinCapacity, RetirementRetainsBorrowOwnership,
     RetirementRetainsAllocationOwnership
     DEF ConstantsOK, Retire, Safety, TypeOK, PublicationSafety, Ownership,
         AuthoritySafety, CohortsOf, Earlier, Members
<1>4. \A c \in CohortDomain, entered \in BOOLEAN :
       ConstantsOK /\ Safety /\ Retire(c, entered) => AuthoritySafety'
  BY CohortsOfDifference DEF ConstantsOK, Retire, Safety, TypeOK,
      PublicationSafety, Ownership, AuthoritySafety, CohortsOf, Members
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM ResolveFrontPreserves ==
    \A t \in MemberDomain :
      ConstantsOK /\ Safety /\ ResolveFront(t) => Safety'
<1>1. \A t \in MemberDomain :
       ConstantsOK /\ Safety /\ ResolveFront(t) => TypeOK'
  BY DEF ConstantsOK, ResolveFront, Safety, TypeOK, PublicationSafety, Ownership,
      AuthoritySafety, CohortsOf, Earlier, Members
<1>2. \A t \in MemberDomain :
       ConstantsOK /\ Safety /\ ResolveFront(t) => PublicationSafety'
  BY CohortsOfSingleton, CohortsOfUnion
     DEF ConstantsOK, ResolveFront, Safety, TypeOK, PublicationSafety, Ownership,
         AuthoritySafety, CohortsOf, Earlier, Members
<1>3. \A t \in MemberDomain :
       ConstantsOK /\ Safety /\ ResolveFront(t) => Ownership'
  BY RemoveWithinCapacity, CohortsOfMonotonic
     DEF ConstantsOK, ResolveFront, Safety, TypeOK, PublicationSafety, Ownership,
         AuthoritySafety, CohortsOf, Earlier, Members
<1>4. \A t \in MemberDomain :
       ConstantsOK /\ Safety /\ ResolveFront(t) => AuthoritySafety'
  BY CohortsOfMonotonic
     DEF ConstantsOK, ResolveFront, Safety, TypeOK, PublicationSafety, Ownership,
         AuthoritySafety, CohortsOf, Earlier, Members
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM ResolveDetachedPreserves ==
    \A t \in MemberDomain :
      ConstantsOK /\ Safety /\ ResolveDetached(t) => Safety'
<1>1. \A t \in MemberDomain :
       ConstantsOK /\ Safety /\ ResolveDetached(t) => TypeOK'
  BY DEF ConstantsOK, ResolveDetached, Safety, TypeOK
<1>2. \A t \in MemberDomain :
       ConstantsOK /\ Safety /\ ResolveDetached(t) => PublicationSafety'
  BY CohortsOfSingleton, CohortsOfUnion
     DEF ConstantsOK, ResolveDetached, Safety, TypeOK, PublicationSafety, Ownership,
         AuthoritySafety, CohortsOf, Earlier, Members
<1>3. \A t \in MemberDomain :
       ConstantsOK /\ Safety /\ ResolveDetached(t) => Ownership'
  BY CohortsOfMonotonic
     DEF ConstantsOK, ResolveDetached, Safety, TypeOK, PublicationSafety, Ownership,
         AuthoritySafety, CohortsOf, Earlier, Members
<1>4. \A t \in MemberDomain :
       ConstantsOK /\ Safety /\ ResolveDetached(t) => AuthoritySafety'
  BY CohortsOfMonotonic
     DEF ConstantsOK, ResolveDetached, Safety, TypeOK, PublicationSafety, Ownership,
         AuthoritySafety, CohortsOf, Earlier, Members
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM ResolutionPreserves ==
    \A t \in MemberDomain :
      ConstantsOK /\ Safety /\ (ResolveFront(t) \/ ResolveDetached(t)) => Safety'
BY ResolveFrontPreserves, ResolveDetachedPreserves

THEOREM FailurePreserves ==
    \A c \in CohortDomain :
      ConstantsOK /\ Safety /\ (ConcludeAbsent(c) \/ Abandon(c) \/ DetachUnknown(c)) => Safety'
BY RemoveWithinCapacity DEF ConstantsOK, ConcludeAbsent, Abandon,
       DetachUnknown, Safety, TypeOK, PublicationSafety, Ownership,
       AuthoritySafety, CohortsOf, Earlier

THEOREM AuthorityPreserves ==
    \A t \in MemberDomain :
      ConstantsOK /\ Safety /\ (Export(t) \/ Import(t) \/ Drop(t)) => Safety'
BY DEF ConstantsOK, Export, Import, Drop, Safety, TypeOK,
       PublicationSafety, Ownership, AuthoritySafety, CohortsOf, Earlier

THEOREM CollectPreserves ==
    \A c \in CohortDomain : ConstantsOK /\ Safety /\ Collect(c) => Safety'
BY RemoveWithinCapacity DEF ConstantsOK, Collect, Safety, TypeOK,
       PublicationSafety, Ownership, AuthoritySafety, CohortsOf, Earlier

THEOREM GlobalLifecyclePreserves ==
    ConstantsOK /\ Safety /\
      (BeginClose \/ Close \/ CrashAfterReturn \/ Reopen \/ RequestCancellation) => Safety'
BY RemoveWithinCapacity DEF ConstantsOK, Collect, BeginClose, Close,
       CrashAfterReturn, Reopen, RequestCancellation, Safety, TypeOK,
       PublicationSafety, Ownership, AuthoritySafety, CohortsOf, Earlier

THEOREM NextPreserves == ConstantsOK /\ Safety /\ Next => Safety'
BY FreezePreserves, StartBatchPreserves, JoinBatchPreserves,
   StartHeadPreserves, JoinHeadPreserves, DurableRetirementPreserves,
   ResolutionPreserves, FailurePreserves, AuthorityPreserves,
   CollectPreserves, GlobalLifecyclePreserves DEF Next

THEOREM StutteringPreserves == ConstantsOK /\ Safety /\ UNCHANGED vars => Safety'
BY DEF vars, Safety, TypeOK, PublicationSafety, Ownership, AuthoritySafety,
       CohortsOf, Earlier

THEOREM SpecSafety ==
    ASSUME ConstantsOK
    PROVE Spec => []Safety
<1>1. Init => Safety
  BY InitSafety
<1>2. Safety /\ [Next]_vars => Safety'
  BY NextPreserves, StutteringPreserves DEF vars
<1> QED BY <1>1, <1>2, PTL DEF Spec
=============================================================================
