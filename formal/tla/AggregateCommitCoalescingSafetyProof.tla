---------------- MODULE AggregateCommitCoalescingSafetyProof ----------------
EXTENDS Naturals

(***************************************************************************
Arbitrary-domain preservation kernel for shared immutable aggregate batches.
Contents and Owner describe any fixed, nonempty, disjoint grouping of
caller-unique transactions into caller-unique batches. They are abstraction
parameters, not a finite bound, allocator, runtime grouping policy, persisted
map, or proof of group selection. The finite model separately explores
selection/order and queue depth.

usedTxns and usedBatches are retained specification history enforcing the
caller's never-reuse obligation. Reopen restores localBatchIDs from published
HEAD authority only. No implementation persistence for that ghost history is
assumed. A confirmed orphan supplies an additional conditional-create barrier;
an absent object supplies none. The kernel's authority pair denotes one member
bound to its COMPLETE immutable batch, not a standalone member payload.

This kernel proves safety preservation, not byte-format correctness, concrete
authority parsing, sequence/generation arithmetic, provider correctness,
ownership, liveness, fairness, or refinement to the executable finite model.
***************************************************************************)

CONSTANTS Transactions, Batches, NoBatch, Contents, Owner

ConstantsOK ==
    /\ NoBatch \notin Batches
    /\ Contents \in [Batches -> SUBSET Transactions]
    /\ Owner \in [Transactions -> Batches \cup {NoBatch}]
    /\ \A b \in Batches :
           Contents[b] = {t \in Transactions : Owner[t] = b}
    /\ \A b \in Batches : Contents[b] # {}
    /\ \A left, right \in Batches :
           left # right => Contents[left] \intersect Contents[right] = {}

ASSUME ConstantsOK

AllMembers(bs) == {t \in Transactions : Owner[t] \in bs}
Bindings(bs) ==
    {pair \in Transactions \X Batches :
        pair[2] \in bs /\ Owner[pair[1]] = pair[2]}
Phases == {"Idle", "Frozen", "Ready", "Unknown"}

VARIABLE s
vars == <<s>>
ActiveMembers == IF s.active = NoBatch THEN {} ELSE Contents[s.active]

Init ==
    s = [admitted |-> {}, excluded |-> {}, usedTxns |-> {}, usedBatches |-> {},
         localBatchIDs |-> {}, offered |-> NoBatch, active |-> NoBatch,
         phase |-> "Idle", attempted |-> {}, stored |-> {}, headAttempted |-> {},
         published |-> {}, acknowledged |-> {}, liveAuthority |-> {},
         durableAuthority |-> {}, recovered |-> {}, online |-> TRUE,
         fenced |-> FALSE, missingBoundary |-> {}, resolutionWrites |-> 0]

Supply(b) ==
    /\ s.online /\ ~s.fenced /\ s.offered = NoBatch
    /\ b \notin s.localBatchIDs
    \* Caller obligation, not a claim about detecting absent historical IDs.
    /\ b \notin s.usedBatches
    /\ s' = [s EXCEPT !.offered = b]

Admit(t) ==
    /\ s.online /\ ~s.fenced /\ s.phase # "Unknown"
    /\ t \notin s.usedTxns \cup s.excluded
    /\ s' = [s EXCEPT !.admitted = @ \cup {t}, !.usedTxns = @ \cup {t}]

RequestCancellation(t) ==
    /\ s.online
    /\ t \in s.admitted \cup ActiveMembers
    \* The kernel has no scheduler marker. An admitted cancellation request
    \* therefore stutters the safety state and proves no progress property.
    /\ UNCHANGED s

Exclude(t) ==
    /\ s.online /\ t \notin AllMembers(s.usedBatches)
    /\ s' = [s EXCEPT !.admitted = @ \ {t}, !.excluded = @ \cup {t}]

Freeze ==
    /\ s.online /\ ~s.fenced /\ s.phase = "Idle"
    /\ s.offered # NoBatch /\ Contents[s.offered] \subseteq s.admitted
    /\ s' = [s EXCEPT !.active = s.offered, !.offered = NoBatch,
          !.phase = "Frozen", !.admitted = @ \ Contents[s.offered],
          !.usedBatches = @ \cup {s.offered},
          !.localBatchIDs = @ \cup {s.offered}]

Store(entered) ==
    /\ s.online /\ s.phase = "Frozen" /\ s.active \notin s.attempted
    /\ s' = [s EXCEPT !.attempted = @ \cup {s.active},
          !.stored = IF entered THEN @ \cup {s.active} ELSE @,
          !.phase = IF entered THEN "Ready" ELSE "Frozen"]

FailFrozen ==
    /\ s.online /\ s.phase \in {"Frozen", "Ready"}
    /\ s' = [s EXCEPT !.excluded = @ \cup ActiveMembers,
          !.active = NoBatch, !.phase = "Idle"]

Head(entered) ==
    /\ s.online /\ s.phase = "Ready"
    /\ s.active \in s.stored /\ s.active \notin s.headAttempted
    /\ s' = [s EXCEPT !.headAttempted = @ \cup {s.active},
          !.published = IF entered THEN @ \cup {s.active} ELSE @,
          !.liveAuthority = @ \cup Bindings({s.active}), !.phase = "Unknown"]

Acknowledge ==
    /\ s.online /\ s.phase = "Unknown" /\ s.active \in s.published
    /\ s' = [s EXCEPT !.acknowledged = @ \cup ActiveMembers,
          !.liveAuthority = @ \ Bindings({s.active}),
          !.active = NoBatch, !.phase = "Idle"]

RejectHead ==
    /\ s.online /\ s.phase = "Ready" /\ s.active \notin s.headAttempted
    /\ s' = [s EXCEPT !.headAttempted = @ \cup {s.active},
          !.excluded = @ \cup ActiveMembers \cup s.admitted,
          !.admitted = {}, !.active = NoBatch, !.offered = NoBatch,
          !.phase = "Idle", !.fenced = TRUE]

Export(t, b) ==
    /\ s.online /\ <<t, b>> \in s.liveAuthority
    /\ s' = [s EXCEPT !.durableAuthority = @ \cup {<<t, b>>}]

Import(t, b) ==
    /\ s.online /\ <<t, b>> \in s.durableAuthority
    /\ s' = [s EXCEPT !.liveAuthority = @ \cup {<<t, b>>}]

Resolve(t, b) ==
    /\ s.online /\ <<t, b>> \in s.liveAuthority /\ b \in s.published
    /\ s' = [s EXCEPT !.acknowledged = @ \cup {t},
          !.liveAuthority = @ \ {<<t, b>>},
          !.active = IF s.active = b THEN NoBatch ELSE @,
          !.phase = IF s.active = b THEN "Idle" ELSE @]

RejectResolution(t, b) ==
    /\ s.online /\ <<t, b>> \in s.liveAuthority /\ b \notin s.published
    \* Abstract a conclusive successor. Merely observing the predecessor
    \* is not this action and leaves the authority unknown.
    /\ s.active \in {NoBatch, b}
    /\ s' = [s EXCEPT !.liveAuthority = @ \ {<<t, b>>},
          !.excluded = @ \cup {t} \cup s.admitted,
          !.admitted = {}, !.active = NoBatch, !.offered = NoBatch,
          !.phase = "Idle", !.fenced = TRUE]

Crash ==
    /\ s.online
    /\ s' = [s EXCEPT !.online = FALSE, !.admitted = {},
          !.active = NoBatch, !.offered = NoBatch, !.phase = "Idle",
          !.localBatchIDs = {}, !.liveAuthority = {}, !.recovered = {}]

Reopen ==
    /\ ~s.online
    /\ s' = [s EXCEPT !.online = TRUE, !.fenced = FALSE,
          !.localBatchIDs = s.published, !.recovered = s.published]

OrphanBarrier(b) ==
    /\ s.online /\ s.phase = "Idle"
    /\ b \in s.stored \ s.published /\ b \notin s.localBatchIDs
    \* Failed conditional create changes neither the immutable object nor
    \* HEAD. No replay is admitted by this out-of-contract collision probe.
    /\ s' = [s EXCEPT !.fenced = TRUE, !.offered = NoBatch,
          !.excluded = @ \cup s.admitted, !.admitted = {}]

MissingBoundary(b) ==
    /\ s.online /\ b \in s.usedBatches \ s.stored
    /\ b \notin s.localBatchIDs
    /\ s' = [s EXCEPT !.missingBoundary = @ \cup {b}]

Next ==
    \/ \E b \in Batches : Supply(b)
    \/ \E t \in Transactions : Admit(t) \/ RequestCancellation(t) \/ Exclude(t)
    \/ Freeze \/ (\E entered \in BOOLEAN : Store(entered)) \/ FailFrozen
    \/ (\E entered \in BOOLEAN : Head(entered)) \/ Acknowledge \/ RejectHead
    \/ \E t \in Transactions, b \in Batches :
           Export(t, b) \/ Import(t, b) \/ Resolve(t, b) \/ RejectResolution(t, b)
    \/ Crash \/ Reopen
    \/ \E b \in Batches : OrphanBarrier(b) \/ MissingBoundary(b)

Spec == Init /\ [][Next]_vars

TypeOK ==
    s \in [admitted : SUBSET Transactions, excluded : SUBSET Transactions,
           usedTxns : SUBSET Transactions, usedBatches : SUBSET Batches,
           localBatchIDs : SUBSET Batches,
           offered : Batches \cup {NoBatch}, active : Batches \cup {NoBatch},
           phase : Phases, attempted : SUBSET Batches, stored : SUBSET Batches,
           headAttempted : SUBSET Batches, published : SUBSET Batches,
           acknowledged : SUBSET Transactions,
           liveAuthority : SUBSET (Transactions \X Batches),
           durableAuthority : SUBSET (Transactions \X Batches),
           recovered : SUBSET Batches, missingBoundary : SUBSET Batches,
           online : BOOLEAN, fenced : BOOLEAN, resolutionWrites : Nat]

IdentityAndPhase ==
    /\ s.localBatchIDs \subseteq s.usedBatches
    /\ s.offered # NoBatch => s.offered \notin s.usedBatches
    /\ s.active # NoBatch => s.active \in s.localBatchIDs
    /\ (s.active = NoBatch) = (s.phase = "Idle")
    /\ s.phase = "Frozen" => s.active \notin s.headAttempted
    /\ s.phase = "Ready" => s.active \in s.stored \ s.headAttempted
    /\ s.phase = "Unknown" => s.active \in s.headAttempted
    /\ s.admitted \subseteq s.usedTxns
    /\ AllMembers(s.usedBatches) \subseteq s.usedTxns
    /\ s.admitted \intersect (AllMembers(s.usedBatches) \cup s.excluded) = {}
    /\ ~s.online => s.active = NoBatch

PublicationSafety ==
    /\ s.stored \subseteq s.attempted
    /\ s.headAttempted \subseteq s.stored
    /\ s.attempted \subseteq s.usedBatches
    /\ s.published \subseteq s.headAttempted
    /\ s.acknowledged \subseteq AllMembers(s.published)
    /\ s.excluded \intersect (ActiveMembers \cup AllMembers(s.published)) = {}
    /\ s.phase \in {"Frozen", "Ready"} => s.active \notin s.published

AuthorityAndRecovery ==
    /\ s.liveAuthority \subseteq Bindings(s.headAttempted)
    /\ s.durableAuthority \subseteq Bindings(s.headAttempted)
    /\ s.recovered \subseteq s.published
    /\ s.missingBoundary \subseteq s.usedBatches \ s.stored
    /\ s.missingBoundary \intersect s.localBatchIDs = {}
    /\ s.fenced => s.admitted = {} /\ s.active = NoBatch
    /\ s.resolutionWrites = 0

Safety == TypeOK /\ IdentityAndPhase /\ PublicationSafety /\ AuthorityAndRecovery

THEOREM ContentsAreTransactions ==
    \A b \in Batches : Contents[b] \subseteq Transactions
<1> USE ConstantsOK
<1> QED BY DEF ConstantsOK

THEOREM AllMembersAreTransactions ==
    \A bs \in SUBSET Batches : AllMembers(bs) \subseteq Transactions
<1> QED BY ContentsAreTransactions DEF AllMembers

THEOREM BindingsHaveExpectedType ==
    \A bs \in SUBSET Batches : Bindings(bs) \subseteq Transactions \X Batches
<1> QED BY ContentsAreTransactions DEF Bindings

THEOREM AllMembersMonotonic ==
    \A left, right \in SUBSET Batches :
        left \subseteq right => AllMembers(left) \subseteq AllMembers(right)
<1> QED BY DEF AllMembers

THEOREM BatchMembersIncluded ==
    \A b \in Batches, bs \in SUBSET Batches :
        b \in bs => Contents[b] \subseteq AllMembers(bs)
<1> USE ConstantsOK
<1> QED BY DEF AllMembers, ConstantsOK

THEOREM AllMembersAddBatch ==
    \A b \in Batches, bs \in SUBSET Batches :
        AllMembers(bs \cup {b}) = AllMembers(bs) \cup Contents[b]
<1> USE ConstantsOK
<1> QED BY DEF AllMembers, ConstantsOK

THEOREM BindingsMonotonic ==
    \A left, right \in SUBSET Batches :
        left \subseteq right => Bindings(left) \subseteq Bindings(right)
<1> QED BY DEF Bindings

THEOREM BindingsAddBatch ==
    \A b \in Batches, bs \in SUBSET Batches :
        Bindings(bs \cup {b}) = Bindings(bs) \cup Bindings({b})
<1> QED BY DEF Bindings

THEOREM DistinctBatchMembers ==
    \A b \in Batches, bs \in SUBSET Batches :
        b \notin bs => Contents[b] \intersect AllMembers(bs) = {}
<1> USE ConstantsOK
<1> QED BY DEF AllMembers, ConstantsOK

THEOREM BindingNamesMember ==
    \A t \in Transactions, b \in Batches, bs \in SUBSET Batches :
        <<t, b>> \in Bindings(bs) => b \in bs /\ t \in Contents[b]
<1> USE ConstantsOK
<1> QED BY DEF Bindings, ConstantsOK

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1> QED BY DEF Init, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM SupplyPreservesSafety == \A b \in Batches : Safety /\ Supply(b) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Supply, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM AdmitPreservesSafety == \A t \in Transactions : Safety /\ Admit(t) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Admit, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM RequestCancellationPreservesSafety ==
    \A t \in Transactions : Safety /\ RequestCancellation(t) => Safety'
<1> QED BY DEF RequestCancellation, Safety, TypeOK, IdentityAndPhase,
    PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
    Bindings, Phases

THEOREM ExcludePreservesSafety == \A t \in Transactions : Safety /\ Exclude(t) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Exclude, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM FreezePreservesSafety == Safety /\ Freeze => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Freeze, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM StorePreservesSafety == \A entered \in BOOLEAN : Safety /\ Store(entered) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Store, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM FailFrozenPreservesSafety == Safety /\ FailFrozen => Safety'
<1>1. Safety /\ FailFrozen => TypeOK'
  <2> USE ConstantsOK, AllMembersAreTransactions
  <2> QED BY DEF FailFrozen, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases, ConstantsOK
<1>2. Safety /\ FailFrozen => IdentityAndPhase'
  <2> USE ConstantsOK
  <2> QED BY BatchMembersIncluded DEF FailFrozen, Safety, TypeOK,
      IdentityAndPhase, PublicationSafety, AuthorityAndRecovery, ActiveMembers,
      AllMembers, Bindings, Phases, ConstantsOK
<1>3. Safety /\ FailFrozen => PublicationSafety'
  <2> USE ConstantsOK
  <2> QED BY DistinctBatchMembers DEF FailFrozen, Safety, TypeOK,
      IdentityAndPhase, PublicationSafety, AuthorityAndRecovery, ActiveMembers,
      AllMembers, Bindings, Phases, ConstantsOK
<1>4. Safety /\ FailFrozen => AuthorityAndRecovery'
  <2> QED BY DEF FailFrozen, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM HeadPreservesSafety == \A entered \in BOOLEAN : Safety /\ Head(entered) => Safety'
<1>1. \A entered \in BOOLEAN : Safety /\ Head(entered) => TypeOK'
  <2> USE ConstantsOK, BindingsHaveExpectedType
  <2> QED BY DEF Head, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
      AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases,
      ConstantsOK
<1>2. \A entered \in BOOLEAN : Safety /\ Head(entered) => IdentityAndPhase'
  <2> QED BY AllMembersMonotonic DEF Head, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases
<1>3. \A entered \in BOOLEAN : Safety /\ Head(entered) => PublicationSafety'
  <2> USE ConstantsOK
  <2> QED BY AllMembersAddBatch DEF Head, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases, ConstantsOK
<1>4. \A entered \in BOOLEAN : Safety /\ Head(entered) => AuthorityAndRecovery'
  <2> USE ConstantsOK
  <2> QED BY BindingsAddBatch DEF Head, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases, ConstantsOK
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM AcknowledgePreservesSafety == Safety /\ Acknowledge => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Acknowledge, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM RejectHeadPreservesSafety == Safety /\ RejectHead => Safety'
<1>1. Safety /\ RejectHead => TypeOK'
  <2> USE ConstantsOK, AllMembersAreTransactions
  <2> QED BY DEF RejectHead, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases, ConstantsOK
<1>2. Safety /\ RejectHead => IdentityAndPhase'
  <2> USE ConstantsOK
  <2> QED BY BatchMembersIncluded DEF RejectHead, Safety, TypeOK,
      IdentityAndPhase, PublicationSafety, AuthorityAndRecovery, ActiveMembers,
      AllMembers, Bindings, Phases, ConstantsOK
<1>3. Safety /\ RejectHead => PublicationSafety'
  <2> USE ConstantsOK
  <2> QED BY DistinctBatchMembers DEF RejectHead, Safety, TypeOK,
      IdentityAndPhase, PublicationSafety, AuthorityAndRecovery, ActiveMembers,
      AllMembers, Bindings, Phases, ConstantsOK
<1>4. Safety /\ RejectHead => AuthorityAndRecovery'
  <2> QED BY DEF RejectHead, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM ExportPreservesSafety ==
    \A t \in Transactions, b \in Batches : Safety /\ Export(t, b) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Export, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM ImportPreservesSafety ==
    \A t \in Transactions, b \in Batches : Safety /\ Import(t, b) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Import, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM ResolvePreservesSafety ==
    \A t \in Transactions, b \in Batches : Safety /\ Resolve(t, b) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Resolve, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM RejectResolutionPreservesSafety ==
    \A t \in Transactions, b \in Batches : Safety /\ RejectResolution(t, b) => Safety'
<1>1. \A t \in Transactions, b \in Batches :
         Safety /\ RejectResolution(t, b) => TypeOK'
  <2> QED BY DEF RejectResolution, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases
<1>2. \A t \in Transactions, b \in Batches :
         Safety /\ RejectResolution(t, b) => IdentityAndPhase'
  <2> USE ConstantsOK
  <2> QED BY BindingNamesMember, AllMembersAreTransactions DEF RejectResolution,
      Safety, TypeOK, IdentityAndPhase, PublicationSafety, AuthorityAndRecovery,
      ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK
<1>3. \A t \in Transactions, b \in Batches :
         Safety /\ RejectResolution(t, b) => PublicationSafety'
  <2> USE ConstantsOK
  <2> QED BY BindingNamesMember, DistinctBatchMembers DEF RejectResolution,
      Safety, TypeOK, IdentityAndPhase, PublicationSafety, AuthorityAndRecovery,
      ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK
<1>4. \A t \in Transactions, b \in Batches :
         Safety /\ RejectResolution(t, b) => AuthorityAndRecovery'
  <2> USE ConstantsOK
  <2> QED BY DEF RejectResolution, Safety, TypeOK, IdentityAndPhase,
      PublicationSafety, AuthorityAndRecovery, ActiveMembers, AllMembers,
      Bindings, Phases, ConstantsOK
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Crash, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM ReopenPreservesSafety == Safety /\ Reopen => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Reopen, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM OrphanBarrierPreservesSafety ==
    \A b \in Batches : Safety /\ OrphanBarrier(b) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF OrphanBarrier, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM MissingBoundaryPreservesSafety ==
    \A b \in Batches : Safety /\ MissingBoundary(b) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF MissingBoundary, Safety, TypeOK, IdentityAndPhase, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, AllMembers, Bindings, Phases, ConstantsOK

THEOREM NextPreservesSafety == Safety /\ Next => Safety'
<1> QED BY SupplyPreservesSafety, AdmitPreservesSafety, ExcludePreservesSafety,
    RequestCancellationPreservesSafety,
    FreezePreservesSafety, StorePreservesSafety, FailFrozenPreservesSafety,
    HeadPreservesSafety, AcknowledgePreservesSafety, RejectHeadPreservesSafety,
    ExportPreservesSafety, ImportPreservesSafety, ResolvePreservesSafety,
    RejectResolutionPreservesSafety, CrashPreservesSafety, ReopenPreservesSafety,
    OrphanBarrierPreservesSafety, MissingBoundaryPreservesSafety DEF Next

=============================================================================
