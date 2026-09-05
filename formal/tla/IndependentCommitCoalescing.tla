-------------------- MODULE IndependentCommitCoalescing --------------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
This finite model asks whether independently submitted singleton transactions
can retain distinct logical batch identities while sharing one authoritative
HEAD transition. T1..T4 and their scheduling are qualification geometry only.

Finite-deadline work is deliberately excluded from this experimental path.
The existing singleton implementation remains responsible for that work.
***************************************************************************)

CONSTANTS T1, T2, T3, T4, NoTxn, DB, OtherDB, NoAuthority

Txns == {T1, T2, T3, T4}
FiniteDeadlineTxns == {T3}

ASSUME Cardinality({T1, T2, T3, T4, NoTxn, DB, OtherDB, NoAuthority}) = 8

Rank(t) == CASE t = T1 -> 1 [] t = T2 -> 2 [] t = T3 -> 3 [] t = T4 -> 4
Earlier(group, t) == {u \in group : Rank(u) < Rank(t)}
Later(group, t) == {u \in group : Rank(t) < Rank(u)}
Position(group, t) == Cardinality(Earlier(group, t)) + 1

FirstMember(group) ==
    CHOOSE t \in group : \A u \in group : Rank(t) <= Rank(u)

FinalMember(group) ==
    CHOOSE t \in group : \A u \in group : Rank(u) <= Rank(t)

PreviousMember(group, t) ==
    IF Earlier(group, t) = {}
    THEN NoTxn
    ELSE FinalMember(Earlier(group, t))

TxnStates == {
    "Idle", "Admitted", "Parked", "Rejected", "Cancelled", "Expired", "Fallback",
    "Frozen", "Accepted", "Unknown", "Committed", "Failed"
}
BatchStates == {"None", "Confirmed", "Ambiguous", "Failed"}
HeadStates == {"Collecting", "Publishing", "Accepted", "Unknown", "Committed", "Rejected"}
ReceiptStates == {"None", "Unknown", "Committed", "Failed"}
AuthorityStates == {"None", "Exported", "Lost", "Imported"}

ActionNames == {
    "Init", "AdmitSingleton", "RejectConflict", "CancelBeforeAdmission",
    "ExpireBeforeAdmission", "FallbackFiniteDeadline", "FreezeCohort",
    "PublishMemberBatch", "ConfirmAmbiguousBatch", "SplitFailedMember",
    "PublishCohortHead", "LoseHeadResponse", "ObserveSuccess",
    "ObserveHeadPreconditionFailure", "RetainUnknownAtPredecessor",
    "ObserveConclusiveSuccessor", "ResolveMember", "ExportMemberAuthority",
    "CrashLoseVolatileReceipts", "ImportMemberAuthority",
    "RejectMalformedAuthority", "RejectSwappedAuthority",
    "RecoverCohortChain", "RejectMalformedRecovery", "CompleteCohort"
}

AuthorityValue ==
    [database : {DB, OtherDB}, member : Txns, sequence : Nat,
     first : Nat, last : Nat, final : Txns \cup {NoTxn}]

RecoveryImageValue ==
    [database : {DB, OtherDB},
     members : SUBSET Txns,
     member : [Txns -> Txns \cup {NoTxn}],
     sequence : [Txns -> Nat],
     previous : [Txns -> Txns \cup {NoTxn}],
     present : [Txns -> BOOLEAN],
     final : Txns \cup {NoTxn}]

EmptyRecoveryImage ==
    [database |-> OtherDB,
     members |-> {},
     member |-> [t \in Txns |-> NoTxn],
     sequence |-> [t \in Txns |-> 0],
     previous |-> [t \in Txns |-> NoTxn],
     present |-> [t \in Txns |-> FALSE],
     final |-> NoTxn]

VARIABLES
    txnState,
    cohort,
    sequence,
    latestBatch,
    memberSequence,
    memberBatch,
    batchPrevious,
    batchState,
    storedBatches,
    visible,
    publishedCohorts,
    headState,
    headAttemptEntered,
    receipt,
    durableAuthority,
    authorityState,
    importedAuthority,
    recovered,
    recoveryImage,
    batchPutCalls,
    headPutCalls,
    resolutionPutCalls,
    fenced,
    staleAdmissionObserved,
    crashObserved,
    lastAction

vars == <<
    txnState, cohort, sequence, latestBatch, memberSequence, memberBatch,
    batchPrevious, batchState, storedBatches, visible, publishedCohorts,
    headState, headAttemptEntered, receipt, durableAuthority, authorityState,
    importedAuthority, recovered, recoveryImage, batchPutCalls, headPutCalls,
    resolutionPutCalls, fenced, staleAdmissionObserved, crashObserved,
    lastAction
>>

Init ==
    /\ txnState = [t \in Txns |-> "Idle"]
    /\ cohort = {}
    /\ sequence = 0
    /\ latestBatch = NoTxn
    /\ memberSequence = [t \in Txns |-> 0]
    /\ memberBatch = [t \in Txns |-> NoTxn]
    /\ batchPrevious = [t \in Txns |-> NoTxn]
    /\ batchState = [t \in Txns |-> "None"]
    /\ storedBatches = {}
    /\ visible = {}
    /\ publishedCohorts = {}
    /\ headState = "Collecting"
    /\ headAttemptEntered = FALSE
    /\ receipt = [t \in Txns |-> "None"]
    /\ durableAuthority = [t \in Txns |-> NoAuthority]
    /\ authorityState = [t \in Txns |-> "None"]
    /\ importedAuthority = [t \in Txns |-> NoAuthority]
    /\ recovered = {}
    /\ recoveryImage = EmptyRecoveryImage
    /\ batchPutCalls = 0
    /\ headPutCalls = 0
    /\ resolutionPutCalls = 0
    /\ fenced = FALSE
    /\ staleAdmissionObserved = FALSE
    /\ crashObserved = FALSE
    /\ lastAction = "Init"

AdmitSingleton(t) ==
    /\ txnState[t] = "Idle"
    /\ t \notin FiniteDeadlineTxns
    /\ headState = "Collecting"
    /\ ~fenced
    /\ txnState' = [txnState EXCEPT ![t] = "Admitted"]
    /\ staleAdmissionObserved' = staleAdmissionObserved \/ fenced
    /\ lastAction' = "AdmitSingleton"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        crashObserved>>

RejectConflict(t) ==
    /\ txnState[t] \in {"Idle", "Admitted"}
    /\ txnState' = [txnState EXCEPT ![t] = "Rejected"]
    /\ lastAction' = "RejectConflict"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

CancelBeforeAdmission(t) ==
    /\ txnState[t] = "Idle"
    /\ txnState' = [txnState EXCEPT ![t] = "Cancelled"]
    /\ lastAction' = "CancelBeforeAdmission"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

ExpireBeforeAdmission(t) ==
    /\ t \in FiniteDeadlineTxns
    /\ txnState[t] = "Idle"
    /\ txnState' = [txnState EXCEPT ![t] = "Expired"]
    /\ lastAction' = "ExpireBeforeAdmission"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

FallbackFiniteDeadline(t) ==
    /\ t \in FiniteDeadlineTxns
    /\ txnState[t] = "Idle"
    /\ txnState' = [txnState EXCEPT ![t] = "Fallback"]
    /\ lastAction' = "FallbackFiniteDeadline"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

AdmittedTxns == {t \in Txns : txnState[t] = "Admitted"}

FreezeCohort ==
    /\ headState = "Collecting"
    /\ cohort = {}
    /\ AdmittedTxns # {}
    /\ ~fenced
    /\ cohort' = AdmittedTxns
    /\ txnState' =
        [t \in Txns |-> IF t \in AdmittedTxns THEN "Frozen" ELSE txnState[t]]
    /\ memberSequence' =
        [t \in Txns |->
            IF t \in AdmittedTxns
            THEN sequence + Position(AdmittedTxns, t)
            ELSE memberSequence[t]]
    /\ memberBatch' =
        [t \in Txns |-> IF t \in AdmittedTxns THEN t ELSE memberBatch[t]]
    /\ batchPrevious' =
        [t \in Txns |->
            IF t \in AdmittedTxns
            THEN IF PreviousMember(AdmittedTxns, t) = NoTxn
                 THEN latestBatch
                 ELSE PreviousMember(AdmittedTxns, t)
            ELSE batchPrevious[t]]
    /\ headState' = "Publishing"
    /\ lastAction' = "FreezeCohort"
    /\ UNCHANGED <<sequence, latestBatch, batchState, storedBatches, visible,
        publishedCohorts, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

EarlierBatchesConfirmed(t) ==
    \A u \in Earlier(cohort, t) : batchState[u] = "Confirmed"

PublishMemberBatch(t, outcome, entered) ==
    /\ headState = "Publishing"
    /\ t \in cohort
    /\ batchState[t] = "None"
    /\ EarlierBatchesConfirmed(t)
    /\ outcome \in {"Confirmed", "Ambiguous", "Failed"}
    /\ entered \in BOOLEAN
    /\ (outcome = "Confirmed" => entered)
    /\ (outcome = "Failed" => ~entered)
    /\ batchState' = [batchState EXCEPT ![t] = outcome]
    /\ storedBatches' = IF entered THEN storedBatches \cup {t} ELSE storedBatches
    /\ batchPutCalls' = batchPutCalls + 1
    /\ lastAction' = "PublishMemberBatch"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, visible, publishedCohorts, headState,
        headAttemptEntered, receipt, durableAuthority, authorityState,
        importedAuthority, recovered, recoveryImage, headPutCalls,
        resolutionPutCalls, fenced, staleAdmissionObserved, crashObserved>>

ConfirmAmbiguousBatch(t) ==
    /\ headState = "Publishing"
    /\ t \in cohort
    /\ batchState[t] = "Ambiguous"
    /\ batchState' =
        [batchState EXCEPT
            ![t] = IF t \in storedBatches THEN "Confirmed" ELSE "Failed"]
    /\ lastAction' = "ConfirmAmbiguousBatch"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, storedBatches, visible, publishedCohorts,
        headState, headAttemptEntered, receipt, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

SplitFailedMember(t) ==
    LET prefix == Earlier(cohort, t)
        suffix == Later(cohort, t)
    IN
    /\ headState = "Publishing"
    /\ t \in cohort
    /\ batchState[t] = "Failed"
    /\ cohort' = prefix
    /\ txnState' =
        [u \in Txns |->
            IF u = t THEN "Failed"
            ELSE IF u \in suffix
                 THEN IF prefix = {} THEN "Admitted" ELSE "Parked"
            ELSE txnState[u]]
    /\ receipt' = [receipt EXCEPT ![t] = "Failed"]
    /\ memberSequence' =
        [u \in Txns |-> IF u \in suffix THEN 0 ELSE memberSequence[u]]
    /\ memberBatch' =
        [u \in Txns |-> IF u \in suffix THEN NoTxn ELSE memberBatch[u]]
    /\ batchPrevious' =
        [u \in Txns |-> IF u \in suffix THEN NoTxn ELSE batchPrevious[u]]
    /\ batchState' =
        [u \in Txns |-> IF u \in suffix THEN "None" ELSE batchState[u]]
    /\ headState' = IF prefix = {} THEN "Collecting" ELSE "Publishing"
    /\ lastAction' = "SplitFailedMember"
    /\ UNCHANGED <<sequence, latestBatch, storedBatches, visible,
        publishedCohorts, headAttemptEntered, durableAuthority,
        authorityState, importedAuthority, recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

CohortReady ==
    cohort # {} /\ \A t \in cohort :
        batchState[t] = "Confirmed" /\ t \in storedBatches

PublishCohortHead ==
    /\ headState = "Publishing"
    /\ CohortReady
    /\ visible' = visible \cup cohort
    /\ publishedCohorts' = publishedCohorts \cup {cohort}
    /\ sequence' = sequence + Cardinality(cohort)
    /\ latestBatch' = FinalMember(cohort)
    /\ headState' = "Accepted"
    /\ headAttemptEntered' = TRUE
    /\ txnState' =
        [t \in Txns |-> IF t \in cohort THEN "Accepted" ELSE txnState[t]]
    /\ headPutCalls' = headPutCalls + 1
    /\ lastAction' = "PublishCohortHead"
    /\ UNCHANGED <<cohort, memberSequence, memberBatch, batchPrevious,
        batchState, storedBatches, receipt, durableAuthority, authorityState,
        importedAuthority, recovered, recoveryImage, batchPutCalls,
        resolutionPutCalls, fenced, staleAdmissionObserved, crashObserved>>

LoseHeadResponse(entered) ==
    /\ headState = "Publishing"
    /\ CohortReady
    /\ entered \in BOOLEAN
    /\ visible' = IF entered THEN visible \cup cohort ELSE visible
    /\ publishedCohorts' =
        IF entered THEN publishedCohorts \cup {cohort} ELSE publishedCohorts
    /\ sequence' = IF entered THEN sequence + Cardinality(cohort) ELSE sequence
    /\ latestBatch' = IF entered THEN FinalMember(cohort) ELSE latestBatch
    /\ headState' = "Unknown"
    /\ headAttemptEntered' = entered
    /\ txnState' =
        [t \in Txns |-> IF t \in cohort THEN "Unknown" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |-> IF t \in cohort THEN "Unknown" ELSE receipt[t]]
    /\ headPutCalls' = headPutCalls + 1
    /\ lastAction' = "LoseHeadResponse"
    /\ UNCHANGED <<cohort, memberSequence, memberBatch, batchPrevious,
        batchState, storedBatches, durableAuthority, authorityState,
        importedAuthority, recovered, recoveryImage, batchPutCalls,
        resolutionPutCalls, fenced, staleAdmissionObserved, crashObserved>>

ObserveSuccess ==
    /\ headState = "Accepted"
    /\ headState' = "Committed"
    /\ txnState' =
        [t \in Txns |-> IF t \in cohort THEN "Committed" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |-> IF t \in cohort THEN "Committed" ELSE receipt[t]]
    /\ lastAction' = "ObserveSuccess"
    /\ UNCHANGED <<cohort, sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headAttemptEntered, durableAuthority, authorityState,
        importedAuthority, recovered, recoveryImage, batchPutCalls,
        headPutCalls, resolutionPutCalls, fenced, staleAdmissionObserved,
        crashObserved>>

ObserveHeadPreconditionFailure ==
    /\ headState = "Publishing"
    /\ CohortReady
    /\ txnState' =
        [t \in Txns |->
            IF t \in cohort \/ txnState[t] = "Parked" THEN "Failed" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |->
            IF t \in cohort \/ txnState[t] = "Parked" THEN "Failed" ELSE receipt[t]]
    /\ cohort' = {}
    /\ headState' = "Rejected"
    /\ headAttemptEntered' = FALSE
    /\ headPutCalls' = headPutCalls + 1
    /\ fenced' = TRUE
    /\ lastAction' = "ObserveHeadPreconditionFailure"
    /\ UNCHANGED <<sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        durableAuthority, authorityState, importedAuthority, recovered,
        recoveryImage, batchPutCalls, resolutionPutCalls,
        staleAdmissionObserved, crashObserved>>

RetainUnknownAtPredecessor ==
    /\ headState = "Unknown"
    /\ ~headAttemptEntered
    /\ lastAction' = "RetainUnknownAtPredecessor"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, headState, headAttemptEntered, receipt,
        durableAuthority, authorityState, importedAuthority, recovered,
        recoveryImage, batchPutCalls, headPutCalls, resolutionPutCalls,
        fenced, staleAdmissionObserved, crashObserved>>

ObserveConclusiveSuccessor ==
    /\ headState = "Unknown"
    /\ ~headAttemptEntered
    /\ txnState' =
        [t \in Txns |->
            IF t \in cohort \/ txnState[t] = "Parked" THEN "Failed" ELSE txnState[t]]
    /\ receipt' =
        [t \in Txns |->
            IF t \in cohort \/ txnState[t] = "Parked" THEN "Failed" ELSE receipt[t]]
    /\ authorityState' =
        [t \in Txns |-> IF t \in cohort THEN "None" ELSE authorityState[t]]
    /\ importedAuthority' =
        [t \in Txns |->
            IF t \in cohort THEN NoAuthority ELSE importedAuthority[t]]
    /\ cohort' = {}
    /\ headState' = "Rejected"
    /\ fenced' = TRUE
    /\ lastAction' = "ObserveConclusiveSuccessor"
    /\ UNCHANGED <<sequence, latestBatch, memberSequence, memberBatch,
        batchPrevious, batchState, storedBatches, visible, publishedCohorts,
        headAttemptEntered, durableAuthority, recovered, recoveryImage, batchPutCalls,
        headPutCalls, resolutionPutCalls, staleAdmissionObserved,
        crashObserved>>

ResolveMember(t) ==
    /\ txnState[t] = "Unknown"
    /\ receipt[t] = "Unknown"
    /\ t \in visible
    /\ txnState' =
        [u \in Txns |->
            IF u = t THEN "Committed"
            ELSE IF t \in cohort /\ txnState[u] = "Parked"
                 THEN "Admitted"
                 ELSE txnState[u]]
    /\ receipt' = [receipt EXCEPT ![t] = "Committed"]
    /\ cohort' = IF t \in cohort THEN {} ELSE cohort
    /\ headState' = IF t \in cohort THEN "Collecting" ELSE headState
    /\ headAttemptEntered' = IF t \in cohort THEN FALSE ELSE headAttemptEntered
    /\ lastAction' = "ResolveMember"
    /\ UNCHANGED <<sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, durableAuthority, authorityState, importedAuthority,
        recovered, recoveryImage,
        batchPutCalls, headPutCalls, resolutionPutCalls, fenced,
        staleAdmissionObserved, crashObserved>>

KnownCohorts == publishedCohorts \cup (IF cohort = {} THEN {} ELSE {cohort})

AuthorityCohort(t) == CHOOSE group \in KnownCohorts : t \in group

ExactAuthority(t) ==
    [database |-> DB,
     member |-> t,
     sequence |-> memberSequence[t],
     first |-> memberSequence[FirstMember(AuthorityCohort(t))],
     last |-> memberSequence[FinalMember(AuthorityCohort(t))],
     final |-> FinalMember(AuthorityCohort(t))]

DefaultAuthority(t) ==
    [database |-> DB,
     member |-> t,
     sequence |-> 0,
     first |-> 0,
     last |-> 0,
     final |-> NoTxn]

BaseAuthority(t) ==
    IF durableAuthority[t] = NoAuthority
    THEN DefaultAuthority(t)
    ELSE durableAuthority[t]

MalformedAuthorityKinds == {
    "WrongDatabase", "SwappedMember", "WrongSequence", "WrongRange", "WrongFinal"
}

MalformedAuthority(t, kind) ==
    CASE kind = "WrongDatabase" ->
            [BaseAuthority(t) EXCEPT !.database = OtherDB]
      [] kind = "SwappedMember" ->
            [BaseAuthority(t) EXCEPT
                !.member = CHOOSE u \in Txns : u # t]
      [] kind = "WrongSequence" ->
            [BaseAuthority(t) EXCEPT !.sequence = @ + 1]
      [] kind = "WrongRange" ->
            [BaseAuthority(t) EXCEPT !.first = 0]
      [] OTHER -> [BaseAuthority(t) EXCEPT !.final = NoTxn]

AuthorityInputs(t) ==
    {BaseAuthority(t)} \cup
        {MalformedAuthority(t, kind) : kind \in MalformedAuthorityKinds}

AuthorityValidFor(t, candidate) ==
    /\ candidate \in AuthorityValue
    /\ candidate.database = DB
    /\ candidate.member = t
    /\ candidate.sequence = memberSequence[t]
    /\ candidate.first > 0
    /\ candidate.first <= candidate.sequence
    /\ candidate.sequence <= candidate.last
    /\ candidate.final \in storedBatches
    /\ \E group \in KnownCohorts :
        /\ t \in group
        /\ candidate.first = memberSequence[FirstMember(group)]
        /\ candidate.last = memberSequence[FinalMember(group)]
        /\ candidate.final = FinalMember(group)

ExportMemberAuthority(t) ==
    /\ (t \in cohort \/ t \in visible)
    /\ txnState[t] = "Unknown"
    /\ receipt[t] = "Unknown"
    /\ authorityState[t] = "None"
    /\ durableAuthority' = [durableAuthority EXCEPT ![t] = ExactAuthority(t)]
    /\ authorityState' = [authorityState EXCEPT ![t] = "Exported"]
    /\ lastAction' = "ExportMemberAuthority"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, headState, headAttemptEntered, receipt,
        importedAuthority, recovered, recoveryImage, batchPutCalls,
        headPutCalls, resolutionPutCalls, fenced, staleAdmissionObserved,
        crashObserved>>

CrashLoseVolatileReceipts ==
    /\ \E t \in Txns :
        txnState[t] = "Unknown" /\ authorityState[t] = "Exported"
    /\ receipt' =
        [t \in Txns |->
            IF txnState[t] = "Unknown" /\ authorityState[t] = "Exported"
            THEN "None"
            ELSE receipt[t]]
    /\ authorityState' =
        [t \in Txns |->
            IF txnState[t] = "Unknown" /\ authorityState[t] = "Exported"
            THEN "Lost"
            ELSE authorityState[t]]
    /\ crashObserved' = TRUE
    /\ recovered' = {}
    /\ lastAction' = "CrashLoseVolatileReceipts"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, headState, headAttemptEntered, durableAuthority,
        importedAuthority, recoveryImage, batchPutCalls, headPutCalls,
        resolutionPutCalls, fenced, staleAdmissionObserved>>

ImportMemberAuthority(t) ==
    /\ txnState[t] = "Unknown"
    /\ receipt[t] = "None"
    /\ authorityState[t] = "Lost"
    /\ \E candidate \in AuthorityInputs(t) :
        /\ AuthorityValidFor(t, candidate)
        /\ receipt' = [receipt EXCEPT ![t] = "Unknown"]
        /\ authorityState' = [authorityState EXCEPT ![t] = "Imported"]
        /\ importedAuthority' = [importedAuthority EXCEPT ![t] = candidate]
        /\ lastAction' = "ImportMemberAuthority"
        /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
            memberBatch, batchPrevious, batchState, storedBatches, visible,
            publishedCohorts, headState, headAttemptEntered, durableAuthority,
            recovered, recoveryImage, batchPutCalls, headPutCalls,
            resolutionPutCalls, fenced, staleAdmissionObserved, crashObserved>>

RejectMalformedAuthority(t) ==
    /\ authorityState[t] = "Lost"
    /\ \E candidate \in AuthorityInputs(t) :
        /\ ~AuthorityValidFor(t, candidate)
        /\ lastAction' = "RejectMalformedAuthority"
        /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
            memberBatch, batchPrevious, batchState, storedBatches, visible,
            publishedCohorts, headState, headAttemptEntered, receipt,
            durableAuthority, authorityState, importedAuthority, recovered,
            recoveryImage, batchPutCalls, headPutCalls, resolutionPutCalls,
            fenced, staleAdmissionObserved, crashObserved>>

RejectSwappedAuthority(t) ==
    /\ authorityState[t] = "Lost"
    /\ ~AuthorityValidFor(t, MalformedAuthority(t, "SwappedMember"))
    /\ lastAction' = "RejectSwappedAuthority"
    /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, headState, headAttemptEntered, receipt,
        durableAuthority, authorityState, importedAuthority, recovered,
        recoveryImage, batchPutCalls, headPutCalls, resolutionPutCalls,
        fenced, staleAdmissionObserved, crashObserved>>

RecoveryBase ==
    [database |-> DB,
     members |-> visible,
     member |-> memberBatch,
     sequence |-> memberSequence,
     previous |-> batchPrevious,
     present |-> [t \in Txns |-> t \in visible /\ t \in storedBatches],
     final |-> latestBatch]

FirstVisibleMember ==
    CHOOSE t \in visible : memberSequence[t] = 1

MalformedRecoveryKinds == {
    "MissingMember", "SwappedPredecessor", "DuplicateIdentity",
    "WrongDatabase", "NoncontiguousSequence", "MissingStoredBatch"
}

MalformedRecovery(kind) ==
    IF visible = {}
    THEN EmptyRecoveryImage
    ELSE
        CASE kind = "MissingMember" ->
                [RecoveryBase EXCEPT !.members = @ \ {FirstVisibleMember}]
          [] kind = "SwappedPredecessor" ->
                [RecoveryBase EXCEPT
                    !.previous[latestBatch] = latestBatch]
          [] kind = "DuplicateIdentity" ->
                [RecoveryBase EXCEPT
                    !.member[latestBatch] = FirstVisibleMember]
          [] kind = "WrongDatabase" ->
                [RecoveryBase EXCEPT !.database = OtherDB]
          [] kind = "NoncontiguousSequence" ->
                [RecoveryBase EXCEPT
                    !.sequence[latestBatch] = sequence + 1]
          [] OTHER ->
                [RecoveryBase EXCEPT !.present[latestBatch] = FALSE]

RecoveryInputs ==
    {RecoveryBase} \cup
        {MalformedRecovery(kind) : kind \in MalformedRecoveryKinds}

RecoveryImageValid(image) ==
    /\ image \in RecoveryImageValue
    /\ image.database = DB
    /\ IF visible = {}
       THEN
            /\ image.members = {}
            /\ sequence = 0
            /\ image.final = NoTxn
            /\ \A t \in Txns : ~image.present[t]
       ELSE
            /\ image.members = visible
            /\ image.final = latestBatch
            /\ Cardinality(image.members) = sequence
            /\ \A t \in image.members :
                /\ image.member[t] = t
                /\ image.present[t]
                /\ t \in storedBatches
                /\ image.sequence[t] \in 1..sequence
                /\ IF image.sequence[t] = 1
                   THEN image.previous[t] = NoTxn
                   ELSE \E u \in image.members :
                        /\ image.sequence[u] + 1 = image.sequence[t]
                        /\ image.previous[t] = image.member[u]
            /\ \A left, right \in image.members :
                left # right => image.sequence[left] # image.sequence[right]
            /\ image.sequence[image.final] = sequence

RecoverCohortChain ==
    /\ crashObserved
    /\ \E image \in RecoveryInputs :
        /\ RecoveryImageValid(image)
        /\ recovered' = image.members
        /\ recoveryImage' = image
        /\ lastAction' = "RecoverCohortChain"
        /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
            memberBatch, batchPrevious, batchState, storedBatches, visible,
            publishedCohorts, headState, headAttemptEntered, receipt,
            durableAuthority, authorityState, importedAuthority, batchPutCalls,
            headPutCalls, resolutionPutCalls, fenced, staleAdmissionObserved,
            crashObserved>>

RejectMalformedRecovery ==
    /\ crashObserved
    /\ \E image \in RecoveryInputs :
        /\ ~RecoveryImageValid(image)
        /\ lastAction' = "RejectMalformedRecovery"
        /\ UNCHANGED <<txnState, cohort, sequence, latestBatch, memberSequence,
            memberBatch, batchPrevious, batchState, storedBatches, visible,
            publishedCohorts, headState, headAttemptEntered, receipt,
            durableAuthority, authorityState, importedAuthority, recovered,
            recoveryImage, batchPutCalls, headPutCalls, resolutionPutCalls,
            fenced, staleAdmissionObserved, crashObserved>>

CompleteCohort ==
    /\ cohort # {}
    /\ headState \in {"Committed", "Unknown"}
    /\ \A t \in cohort : txnState[t] = "Committed"
    /\ cohort' = {}
    /\ headState' = "Collecting"
    /\ headAttemptEntered' = FALSE
    /\ txnState' =
        [t \in Txns |-> IF txnState[t] = "Parked" THEN "Admitted" ELSE txnState[t]]
    /\ lastAction' = "CompleteCohort"
    /\ UNCHANGED <<sequence, latestBatch, memberSequence,
        memberBatch, batchPrevious, batchState, storedBatches, visible,
        publishedCohorts, receipt, durableAuthority, authorityState,
        importedAuthority, recovered, recoveryImage, batchPutCalls,
        headPutCalls, resolutionPutCalls, fenced, staleAdmissionObserved,
        crashObserved>>

Next ==
    \/ \E t \in Txns : AdmitSingleton(t)
    \/ \E t \in Txns : RejectConflict(t)
    \/ \E t \in Txns : CancelBeforeAdmission(t)
    \/ \E t \in Txns : ExpireBeforeAdmission(t)
    \/ \E t \in Txns : FallbackFiniteDeadline(t)
    \/ FreezeCohort
    \/ \E t \in Txns,
          outcome \in {"Confirmed", "Ambiguous", "Failed"},
          entered \in BOOLEAN : PublishMemberBatch(t, outcome, entered)
    \/ \E t \in Txns : ConfirmAmbiguousBatch(t)
    \/ \E t \in Txns : SplitFailedMember(t)
    \/ PublishCohortHead
    \/ \E entered \in BOOLEAN : LoseHeadResponse(entered)
    \/ ObserveSuccess
    \/ ObserveHeadPreconditionFailure
    \/ RetainUnknownAtPredecessor
    \/ ObserveConclusiveSuccessor
    \/ \E t \in Txns : ResolveMember(t)
    \/ \E t \in Txns : ExportMemberAuthority(t)
    \/ CrashLoseVolatileReceipts
    \/ \E t \in Txns : ImportMemberAuthority(t)
    \/ \E t \in Txns : RejectMalformedAuthority(t)
    \/ \E t \in Txns : RejectSwappedAuthority(t)
    \/ RecoverCohortChain
    \/ RejectMalformedRecovery
    \/ CompleteCohort

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ txnState \in [Txns -> TxnStates]
    /\ cohort \subseteq Txns
    /\ sequence \in Nat
    /\ latestBatch \in Txns \cup {NoTxn}
    /\ memberSequence \in [Txns -> Nat]
    /\ memberBatch \in [Txns -> Txns \cup {NoTxn}]
    /\ batchPrevious \in [Txns -> Txns \cup {NoTxn}]
    /\ batchState \in [Txns -> BatchStates]
    /\ storedBatches \subseteq Txns
    /\ visible \subseteq Txns
    /\ publishedCohorts \subseteq SUBSET Txns
    /\ headState \in HeadStates
    /\ headAttemptEntered \in BOOLEAN
    /\ receipt \in [Txns -> ReceiptStates]
    /\ durableAuthority \in [Txns -> AuthorityValue \cup {NoAuthority}]
    /\ authorityState \in [Txns -> AuthorityStates]
    /\ importedAuthority \in [Txns -> AuthorityValue \cup {NoAuthority}]
    /\ recovered \subseteq Txns
    /\ recoveryImage \in RecoveryImageValue
    /\ batchPutCalls \in Nat
    /\ headPutCalls \in Nat
    /\ resolutionPutCalls \in Nat
    /\ fenced \in BOOLEAN
    /\ staleAdmissionObserved \in BOOLEAN
    /\ crashObserved \in BOOLEAN
    /\ lastAction \in ActionNames

MemberIdentityIsExact ==
    \A t \in Txns : memberBatch[t] # NoTxn => memberBatch[t] = t

PublishedChainIsExact ==
    /\ visible = UNION publishedCohorts
    /\ sequence = Cardinality(visible)
    /\ (sequence = 0 => latestBatch = NoTxn)
    /\ \A t \in visible :
        /\ t \in storedBatches
        /\ memberSequence[t] \in 1..sequence
        /\ IF memberSequence[t] = 1
           THEN batchPrevious[t] = NoTxn
           ELSE \E u \in visible :
                /\ memberSequence[u] + 1 = memberSequence[t]
                /\ batchPrevious[t] = memberBatch[u]
    /\ \A left, right \in visible :
        left # right => memberSequence[left] # memberSequence[right]
    /\ (sequence > 0 =>
        latestBatch = CHOOSE t \in visible : memberSequence[t] = sequence)

UnpublishedCohortIsContiguous ==
    cohort \intersect visible = {} =>
        /\ \A t \in cohort : memberSequence[t] = sequence + Position(cohort, t)
        /\ \A t \in cohort :
            batchPrevious[t] =
                IF PreviousMember(cohort, t) = NoTxn
                THEN latestBatch
                ELSE PreviousMember(cohort, t)

StoredBeforeVisibility == visible \subseteq storedBatches

WholeCohortVisibility ==
    /\ \A group \in publishedCohorts : group \subseteq visible
    /\ headAttemptEntered => cohort \subseteq visible

NoEarlyAcknowledgement ==
    \A t \in Txns :
        txnState[t] = "Committed" => t \in visible /\ receipt[t] = "Committed"

PreFreezeExclusion ==
    {t \in Txns :
        txnState[t] \in {"Rejected", "Cancelled", "Expired", "Fallback", "Failed"}}
        \intersect (cohort \union visible) = {}

FiniteDeadlinesStaySingleton == FiniteDeadlineTxns \intersect cohort = {}

ResolutionDoesNotReplay ==
    /\ resolutionPutCalls = 0
    /\ batchPutCalls <= Cardinality(Txns)
    /\ headPutCalls <= Cardinality(Txns)

FencingStopsAdmission ==
    /\ ~staleAdmissionObserved
    /\ fenced =>
        /\ cohort = {}
        /\ {t \in Txns : txnState[t] \in {"Admitted", "Parked", "Frozen"}} = {}

PhaseStateAlignment ==
    /\ ({t \in Txns : txnState[t] = "Admitted"} # {} => headState = "Collecting")
    /\ {t \in Txns : txnState[t] = "Frozen"} \subseteq cohort
    /\ ({t \in Txns : txnState[t] = "Frozen"} # {} => headState = "Publishing")
    /\ (headState = "Publishing" =>
        cohort \subseteq {t \in Txns : txnState[t] = "Frozen"})

ParkedSuffixWaitsForPrefix ==
    LET parked == {t \in Txns : txnState[t] = "Parked"}
    IN
        parked # {} =>
            /\ parked \intersect cohort = {}
            /\ parked \intersect visible = {}
            /\ parked \intersect storedBatches = {}
            /\ cohort # {}
            /\ cohort \subseteq storedBatches
            /\ headState \in {"Publishing", "Accepted", "Unknown", "Committed"}
            /\ ~fenced
            /\ \A t \in parked :
                /\ receipt[t] = "None"
                /\ authorityState[t] = "None"
                /\ durableAuthority[t] = NoAuthority
                /\ importedAuthority[t] = NoAuthority
                /\ memberSequence[t] = 0
                /\ memberBatch[t] = NoTxn
                /\ batchPrevious[t] = NoTxn
                /\ batchState[t] = "None"

DurableAuthorityIsExact ==
    \A t \in Txns :
        authorityState[t] # "None" =>
            /\ txnState[t] \in {"Unknown", "Committed"}
            /\ AuthorityValidFor(t, durableAuthority[t])

ImportedAuthorityIsValid ==
    \A t \in Txns :
        authorityState[t] = "Imported" =>
            /\ importedAuthority[t] \in AuthorityValue
            /\ AuthorityValidFor(t, importedAuthority[t])

RecoveryIsExact ==
    /\ recovered \subseteq visible
    /\ (lastAction = "RecoverCohortChain" =>
        recovered = visible /\ RecoveryImageValid(recoveryImage))

Safety ==
    /\ TypeOK
    /\ MemberIdentityIsExact
    /\ PublishedChainIsExact
    /\ UnpublishedCohortIsContiguous
    /\ StoredBeforeVisibility
    /\ WholeCohortVisibility
    /\ NoEarlyAcknowledgement
    /\ PreFreezeExclusion
    /\ FiniteDeadlinesStaySingleton
    /\ ResolutionDoesNotReplay
    /\ FencingStopsAdmission
    /\ PhaseStateAlignment
    /\ ParkedSuffixWaitsForPrefix
    /\ DurableAuthorityIsExact
    /\ ImportedAuthorityIsValid
    /\ RecoveryIsExact

=============================================================================
