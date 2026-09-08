-------------- MODULE AdaptiveAggregateCommitCoalescingSafetyProof --------------
EXTENDS Naturals

(***************************************************************************
Arbitrary-domain safety kernel for adaptive durable cohorts. Freeze accepts
any nonempty subset of admitted transactions. This over-approximates the
finite scheduler's width, byte, wait, close, and oldest-prefix selection.

The physical batch identity is one member of its cohort. The finite model
separately proves that it is exactly the oldest selected member. This kernel
proves that dynamic cohort membership is installed once, remains disjoint,
and supports whole-cohort publication, fencing, valid retained authority,
complete authority for an active unknown cohort, crash recovery, and
zero-write resolution. It does not prove selection order, timer policy, byte
formats, provider correctness, liveness, performance, or refinement to Ada.
***************************************************************************)

CONSTANTS Transactions, NoTxn

ConstantsOK == Transactions # {} /\ NoTxn \notin Transactions
ASSUME ConstantsOK

Members(groups, batch) ==
    {transaction \in Transactions : <<transaction, batch>> \in groups}
AllMembers(groups, batches) ==
    {transaction \in Transactions :
        \E batch \in batches : <<transaction, batch>> \in groups}
Bindings(groups, batches) ==
    {pair \in groups : pair[2] \in batches}

Phases == {"Idle", "Frozen", "Ready", "Unknown"}

VARIABLE s
vars == <<s>>

ActiveMembers ==
    IF s.active = NoTxn THEN {} ELSE Members(s.groups, s.active)

Init ==
    s = [pending |-> {}, usedTxns |-> {}, frozenBatches |-> {}, groups |-> {},
         active |-> NoTxn, phase |-> "Idle", attempted |-> {}, stored |-> {},
         headAttempted |-> {}, published |-> {}, acknowledged |-> {},
         excluded |-> {}, liveAuthority |-> {}, durableAuthority |-> {},
         recovered |-> {}, online |-> TRUE, fenced |-> FALSE,
         resolutionWrites |-> 0]

Admit(transaction) ==
    /\ s.online /\ ~s.fenced /\ s.phase # "Unknown"
    /\ transaction \in Transactions /\ transaction \notin s.usedTxns
    /\ s' = [s EXCEPT !.pending = @ \cup {transaction},
          !.usedTxns = @ \cup {transaction}]

ExcludeQueued(transaction) ==
    /\ s.online /\ transaction \in s.pending
    /\ s' = [s EXCEPT !.pending = @ \ {transaction},
          !.excluded = @ \cup {transaction}]

RequestCancellation(transaction) ==
    /\ s.online /\ transaction \in s.pending \cup ActiveMembers
    /\ UNCHANGED s

Freeze(members, batch) ==
    /\ s.online /\ ~s.fenced /\ s.phase = "Idle"
    /\ members \in SUBSET s.pending /\ members # {}
    /\ batch \in members /\ batch \notin s.frozenBatches
    /\ s' = [s EXCEPT !.pending = @ \ members,
          !.groups = @ \cup {<<transaction, batch>> : transaction \in members},
          !.frozenBatches = @ \cup {batch},
          !.active = batch, !.phase = "Frozen"]

Store(entered) ==
    /\ s.online /\ s.phase = "Frozen" /\ s.active \notin s.attempted
    /\ entered \in BOOLEAN
    /\ s' = [s EXCEPT !.attempted = @ \cup {s.active},
          !.stored = IF entered THEN @ \cup {s.active} ELSE @,
          !.phase = IF entered THEN "Ready" ELSE "Frozen"]

FailFrozen ==
    /\ s.online /\ s.phase \in {"Frozen", "Ready"}
    /\ s' = [s EXCEPT !.excluded = @ \cup ActiveMembers,
          !.active = NoTxn, !.phase = "Idle"]

PublishHead(entered) ==
    /\ s.online /\ s.phase = "Ready" /\ s.active \in s.stored
    /\ s.active \notin s.headAttempted /\ entered \in BOOLEAN
    /\ s' = [s EXCEPT !.headAttempted = @ \cup {s.active},
          !.published = IF entered THEN @ \cup {s.active} ELSE @,
          !.liveAuthority = @ \cup Bindings(s.groups, {s.active}),
          !.phase = "Unknown"]

Acknowledge ==
    /\ s.online /\ s.phase = "Unknown" /\ s.active \in s.published
    /\ s' = [s EXCEPT !.acknowledged = @ \cup ActiveMembers,
          !.liveAuthority = @ \ Bindings(s.groups, {s.active}),
          !.active = NoTxn, !.phase = "Idle"]

AcknowledgeAndFence ==
    /\ s.online /\ s.phase = "Unknown" /\ s.active \in s.published
    /\ s' = [s EXCEPT !.acknowledged = @ \cup ActiveMembers,
          !.excluded = @ \cup s.pending, !.pending = {},
          !.liveAuthority = @ \ Bindings(s.groups, {s.active}),
          !.active = NoTxn, !.phase = "Idle", !.fenced = TRUE]

RejectHead ==
    /\ s.online /\ s.phase = "Ready" /\ s.active \notin s.headAttempted
    /\ s' = [s EXCEPT !.excluded = @ \cup ActiveMembers \cup s.pending,
          !.pending = {}, !.active = NoTxn, !.phase = "Idle",
          !.fenced = TRUE]

Export(transaction, batch) ==
    /\ s.online /\ <<transaction, batch>> \in s.liveAuthority
    /\ s' = [s EXCEPT !.durableAuthority = @ \cup {<<transaction, batch>>}]

Import(transaction, batch) ==
    /\ s.online /\ <<transaction, batch>> \in s.durableAuthority
    /\ s' = [s EXCEPT !.liveAuthority = @ \cup {<<transaction, batch>>}]

Resolve(transaction, batch) ==
    /\ s.online /\ <<transaction, batch>> \in s.liveAuthority
    /\ batch \in s.published
    /\ s' = [s EXCEPT !.acknowledged = @ \cup {transaction},
          !.liveAuthority = @ \ {<<transaction, batch>>},
          !.active = IF s.active = batch THEN NoTxn ELSE @,
          !.phase = IF s.active = batch THEN "Idle" ELSE @]

RejectResolution(transaction, batch) ==
    /\ s.online /\ <<transaction, batch>> \in s.liveAuthority
    /\ batch \notin s.published /\ s.active \in {NoTxn, batch}
    /\ s' = [s EXCEPT
          !.liveAuthority = @ \ {<<transaction, batch>>},
          !.excluded = @ \cup Members(s.groups, batch) \cup s.pending,
          !.pending = {}, !.active = NoTxn, !.phase = "Idle",
          !.fenced = TRUE]

Crash ==
    /\ s.online
    /\ s' = [s EXCEPT !.online = FALSE, !.pending = {},
          !.active = NoTxn, !.phase = "Idle", !.liveAuthority = {},
          !.recovered = {}]

Reopen ==
    /\ ~s.online
    /\ s' = [s EXCEPT !.online = TRUE, !.fenced = FALSE,
          !.recovered = AllMembers(s.groups, s.published)]

CloseUnknown ==
    /\ s.online /\ s.phase = "Unknown"
    /\ s' = [s EXCEPT !.excluded = @ \cup s.pending, !.pending = {},
          !.online = FALSE, !.active = NoTxn, !.phase = "Idle"]

Close ==
    /\ s.online /\ s.phase = "Idle" /\ s.pending = {}
    /\ s' = [s EXCEPT !.online = FALSE]

Next ==
    \/ \E transaction \in Transactions :
         Admit(transaction) \/ ExcludeQueued(transaction)
              \/ RequestCancellation(transaction)
    \/ \E members \in SUBSET Transactions, batch \in Transactions :
         Freeze(members, batch)
    \/ \E entered \in BOOLEAN : Store(entered) \/ PublishHead(entered)
    \/ FailFrozen \/ Acknowledge \/ AcknowledgeAndFence \/ RejectHead
    \/ \E transaction, batch \in Transactions :
         Export(transaction, batch) \/ Import(transaction, batch)
              \/ Resolve(transaction, batch) \/ RejectResolution(transaction, batch)
    \/ Crash \/ Reopen \/ CloseUnknown \/ Close

Spec == Init /\ [][Next]_vars

TypeOK ==
    s \in [pending : SUBSET Transactions, usedTxns : SUBSET Transactions,
           frozenBatches : SUBSET Transactions,
           groups : SUBSET (Transactions \X Transactions),
           active : Transactions \cup {NoTxn}, phase : Phases,
           attempted : SUBSET Transactions, stored : SUBSET Transactions,
           headAttempted : SUBSET Transactions, published : SUBSET Transactions,
           acknowledged : SUBSET Transactions, excluded : SUBSET Transactions,
           liveAuthority : SUBSET (Transactions \X Transactions),
           durableAuthority : SUBSET (Transactions \X Transactions),
           recovered : SUBSET Transactions, online : BOOLEAN, fenced : BOOLEAN,
           resolutionWrites : Nat]

GroupLedger ==
    /\ s.pending \subseteq s.usedTxns
    /\ s.excluded \subseteq s.usedTxns
    /\ s.frozenBatches \subseteq s.usedTxns
    /\ s.groups = Bindings(s.groups, s.frozenBatches)
    /\ \A batch \in s.frozenBatches :
         /\ Members(s.groups, batch) # {}
         /\ batch \in Members(s.groups, batch)
         /\ Members(s.groups, batch) \subseteq s.usedTxns
    /\ \A transaction \in Transactions, left, right \in s.frozenBatches :
         /\ <<transaction, left>> \in s.groups
         /\ <<transaction, right>> \in s.groups
         => left = right
    /\ s.pending \intersect
         (AllMembers(s.groups, s.frozenBatches) \cup s.excluded) = {}
    /\ s.active # NoTxn => s.active \in s.frozenBatches
    /\ (s.active = NoTxn) = (s.phase = "Idle")
    /\ ~s.online => s.active = NoTxn

PublicationSafety ==
    /\ s.stored \subseteq s.attempted
    /\ s.headAttempted \subseteq s.stored
    /\ s.attempted \subseteq s.frozenBatches
    /\ s.published \subseteq s.headAttempted
    /\ s.acknowledged \subseteq AllMembers(s.groups, s.published)
    /\ s.excluded \intersect
         (ActiveMembers \cup AllMembers(s.groups, s.published)) = {}
    /\ s.phase \in {"Frozen", "Ready"} => s.active \notin s.published

AuthorityAndRecovery ==
    /\ s.liveAuthority \subseteq Bindings(s.groups, s.headAttempted)
    /\ s.durableAuthority \subseteq Bindings(s.groups, s.headAttempted)
    /\ s.phase = "Unknown" =>
         Bindings(s.groups, {s.active}) \subseteq s.liveAuthority
    /\ s.recovered \subseteq AllMembers(s.groups, s.published)
    /\ s.fenced => s.pending = {} /\ s.active = NoTxn
    /\ s.resolutionWrites = 0

Safety == TypeOK /\ GroupLedger /\ PublicationSafety /\ AuthorityAndRecovery

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1> QED BY DEF Init, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM AdmitPreservesSafety ==
    \A transaction \in Transactions : Safety /\ Admit(transaction) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Admit, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM ExcludePreservesSafety ==
    \A transaction \in Transactions : Safety /\ ExcludeQueued(transaction) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF ExcludeQueued, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM CancellationPreservesSafety ==
    \A transaction \in Transactions : Safety /\ RequestCancellation(transaction) => Safety'
<1> QED BY DEF RequestCancellation, Safety, TypeOK, GroupLedger,
    PublicationSafety, AuthorityAndRecovery, ActiveMembers, Members,
    AllMembers, Bindings, Phases, vars

THEOREM FreezePreservesSafety ==
    \A members \in SUBSET Transactions, batch \in Transactions :
      Safety /\ Freeze(members, batch) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Freeze, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM StorePreservesSafety ==
    \A entered \in BOOLEAN : Safety /\ Store(entered) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Store, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM FailFrozenPreservesSafety == Safety /\ FailFrozen => Safety'
<1> USE ConstantsOK
<1> QED BY DEF FailFrozen, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM HeadPreservesSafety ==
    \A entered \in BOOLEAN : Safety /\ PublishHead(entered) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF PublishHead, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM AcknowledgePreservesSafety == Safety /\ Acknowledge => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Acknowledge, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM LocalFailurePreservesSafety == Safety /\ AcknowledgeAndFence => Safety'
<1> USE ConstantsOK
<1> QED BY DEF AcknowledgeAndFence, Safety, TypeOK, GroupLedger,
    PublicationSafety, AuthorityAndRecovery, ActiveMembers, Members,
    AllMembers, Bindings, Phases, ConstantsOK

THEOREM RejectHeadPreservesSafety == Safety /\ RejectHead => Safety'
<1> USE ConstantsOK
<1> QED BY DEF RejectHead, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM ExportPreservesSafety ==
    \A transaction, batch \in Transactions :
      Safety /\ Export(transaction, batch) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Export, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM ImportPreservesSafety ==
    \A transaction, batch \in Transactions :
      Safety /\ Import(transaction, batch) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Import, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM ResolvePreservesSafety ==
    \A transaction, batch \in Transactions :
      Safety /\ Resolve(transaction, batch) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Resolve, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM RejectResolutionPreservesSafety ==
    \A transaction, batch \in Transactions :
      Safety /\ RejectResolution(transaction, batch) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF RejectResolution, Safety, TypeOK, GroupLedger,
    PublicationSafety, AuthorityAndRecovery, ActiveMembers, Members,
    AllMembers, Bindings, Phases, ConstantsOK

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Crash, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM ReopenPreservesSafety == Safety /\ Reopen => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Reopen, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM CloseUnknownPreservesSafety == Safety /\ CloseUnknown => Safety'
<1> USE ConstantsOK
<1> QED BY DEF CloseUnknown, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM ClosePreservesSafety == Safety /\ Close => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Close, Safety, TypeOK, GroupLedger, PublicationSafety,
    AuthorityAndRecovery, ActiveMembers, Members, AllMembers, Bindings,
    Phases, ConstantsOK

THEOREM NextPreservesSafety == Safety /\ Next => Safety'
<1> QED BY AdmitPreservesSafety, ExcludePreservesSafety,
    CancellationPreservesSafety, FreezePreservesSafety, StorePreservesSafety,
    FailFrozenPreservesSafety, HeadPreservesSafety, AcknowledgePreservesSafety,
    LocalFailurePreservesSafety, RejectHeadPreservesSafety,
    ExportPreservesSafety, ImportPreservesSafety, ResolvePreservesSafety,
    RejectResolutionPreservesSafety, CrashPreservesSafety,
    ReopenPreservesSafety, CloseUnknownPreservesSafety,
    ClosePreservesSafety DEF Next

=============================================================================
