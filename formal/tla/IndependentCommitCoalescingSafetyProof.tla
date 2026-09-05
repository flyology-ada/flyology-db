-------------- MODULE IndependentCommitCoalescingSafetyProof --------------
EXTENDS FiniteSets, Naturals

(***************************************************************************
This arbitrary-domain kernel proves the central safety cut for the private
independent-commit coalescing experiment. Pre-HEAD exclusion and whole-cohort
failure remain independent. A published cohort becomes visible atomically only
after all retained members exist. Acknowledgement and recovery are rooted in
authoritative visibility, and receipt resolution performs no publication.

It omits byte formats, sequence arithmetic, provider behavior, finite-deadline
scheduling, Ada ownership, progress, and refinement to the finite model or an
implementation.
***************************************************************************)

CONSTANT Transactions

ASSUME Transactions # {}

States == {
    "Idle", "Admitted", "Excluded", "Frozen", "Unknown", "Committed", "Failed"
}
HeadStates == {"Collecting", "Publishing", "Unknown", "Committed", "Rejected"}

VARIABLES
    state,
    cohort,
    stored,
    visible,
    publishedCohorts,
    acknowledged,
    excluded,
    recovered,
    authority,
    headState,
    fenced,
    staleAdmissionObserved,
    batchWrites,
    headWrites,
    resolutionWrites,
    invalidImportAccepted

vars == <<
    state, cohort, stored, visible, publishedCohorts, acknowledged, excluded,
    recovered, authority, headState, fenced, staleAdmissionObserved,
    batchWrites, headWrites, resolutionWrites, invalidImportAccepted
>>

Init ==
    /\ state = [t \in Transactions |-> "Idle"]
    /\ cohort = {}
    /\ stored = {}
    /\ visible = {}
    /\ publishedCohorts = {}
    /\ acknowledged = {}
    /\ excluded = {}
    /\ recovered = {}
    /\ authority = {}
    /\ headState = "Collecting"
    /\ fenced = FALSE
    /\ staleAdmissionObserved = FALSE
    /\ batchWrites = 0
    /\ headWrites = 0
    /\ resolutionWrites = 0
    /\ invalidImportAccepted = FALSE

Admit(t) ==
    /\ state[t] = "Idle"
    /\ headState = "Collecting"
    /\ ~fenced
    /\ state' = [state EXCEPT ![t] = "Admitted"]
    /\ staleAdmissionObserved' = staleAdmissionObserved \/ fenced
    /\ UNCHANGED <<cohort, stored, visible, publishedCohorts, acknowledged,
        excluded, recovered, authority, headState, fenced, batchWrites,
        headWrites, resolutionWrites, invalidImportAccepted>>

Exclude(t) ==
    /\ state[t] \in {"Idle", "Admitted"}
    /\ t \notin cohort
    /\ state' = [state EXCEPT ![t] = "Excluded"]
    /\ excluded' = excluded \cup {t}
    /\ UNCHANGED <<cohort, stored, visible, publishedCohorts, acknowledged,
        recovered, authority, headState, fenced, staleAdmissionObserved,
        batchWrites, headWrites, resolutionWrites, invalidImportAccepted>>

Admitted == {t \in Transactions : state[t] = "Admitted"}

Freeze ==
    /\ cohort = {}
    /\ headState = "Collecting"
    /\ Admitted # {}
    /\ ~fenced
    /\ cohort' = Admitted
    /\ state' =
        [t \in Transactions |-> IF t \in Admitted THEN "Frozen" ELSE state[t]]
    /\ headState' = "Publishing"
    /\ UNCHANGED <<stored, visible, publishedCohorts, acknowledged, excluded,
        recovered, authority, fenced, staleAdmissionObserved, batchWrites,
        headWrites, resolutionWrites, invalidImportAccepted>>

Store(t) ==
    /\ headState = "Publishing"
    /\ t \in cohort \ stored
    /\ stored' = stored \cup {t}
    /\ batchWrites' = batchWrites + 1
    /\ UNCHANGED <<state, cohort, visible, publishedCohorts, acknowledged,
        excluded, recovered, authority, headState, fenced,
        staleAdmissionObserved, headWrites, resolutionWrites,
        invalidImportAccepted>>

FailCohort(t) ==
    /\ headState = "Publishing"
    /\ t \in cohort \ stored
    /\ cohort' = {}
    /\ state' =
        [u \in Transactions |-> IF u \in cohort THEN "Failed" ELSE state[u]]
    /\ excluded' = excluded \cup cohort
    /\ headState' = "Collecting"
    /\ UNCHANGED <<stored, visible, publishedCohorts, acknowledged, recovered,
        authority, fenced, staleAdmissionObserved, batchWrites, headWrites,
        resolutionWrites, invalidImportAccepted>>

Publish ==
    /\ headState = "Publishing"
    /\ cohort # {}
    /\ cohort \subseteq stored
    /\ visible' = visible \cup cohort
    /\ publishedCohorts' = publishedCohorts \cup {cohort}
    /\ state' =
        [t \in Transactions |-> IF t \in cohort THEN "Unknown" ELSE state[t]]
    /\ headState' = "Unknown"
    /\ headWrites' = headWrites + 1
    /\ UNCHANGED <<cohort, stored, acknowledged, excluded, recovered,
        authority, fenced, staleAdmissionObserved, batchWrites,
        resolutionWrites, invalidImportAccepted>>

RejectHead ==
    /\ headState = "Publishing"
    /\ cohort # {}
    /\ cohort \subseteq stored
    /\ state' =
        [t \in Transactions |-> IF t \in cohort THEN "Failed" ELSE state[t]]
    /\ excluded' = excluded \cup cohort
    /\ cohort' = {}
    /\ headState' = "Rejected"
    /\ fenced' = TRUE
    /\ headWrites' = headWrites + 1
    /\ UNCHANGED <<stored, visible, publishedCohorts, acknowledged, recovered,
        authority, staleAdmissionObserved, batchWrites, resolutionWrites,
        invalidImportAccepted>>

Acknowledge(t) ==
    /\ t \in cohort
    /\ state[t] = "Unknown"
    /\ t \in visible
    /\ state' = [state EXCEPT ![t] = "Committed"]
    /\ acknowledged' = acknowledged \cup {t}
    /\ UNCHANGED <<cohort, stored, visible, publishedCohorts, excluded,
        recovered, authority, headState, fenced, staleAdmissionObserved,
        batchWrites, headWrites, resolutionWrites, invalidImportAccepted>>

Resolve(t) ==
    /\ state[t] = "Unknown"
    /\ t \in visible
    /\ (t \in cohort => headState = "Unknown")
    /\ state' = [state EXCEPT ![t] = "Committed"]
    /\ acknowledged' = acknowledged \cup {t}
    /\ cohort' = IF t \in cohort THEN {} ELSE cohort
    /\ headState' = IF t \in cohort THEN "Collecting" ELSE headState
    /\ UNCHANGED <<stored, visible, publishedCohorts, excluded,
        recovered, authority, fenced, staleAdmissionObserved,
        batchWrites, headWrites, resolutionWrites, invalidImportAccepted>>

ExportAuthority(t, final) ==
    /\ (t \in cohort \/ t \in visible)
    /\ state[t] = "Unknown"
    /\ final \in stored
    /\ (final \in cohort \/ final \in visible)
    /\ authority' = authority \cup {<<t, final>>}
    /\ UNCHANGED <<state, cohort, stored, visible, publishedCohorts,
        acknowledged, excluded, recovered, headState, fenced,
        staleAdmissionObserved, batchWrites, headWrites, resolutionWrites,
        invalidImportAccepted>>

ImportAuthority(t, final) ==
    /\ <<t, final>> \in authority
    \* Import is a local structural bearer decode. Authoritative visibility is
    \* authenticated only by the later read-only Resolve action.
    /\ UNCHANGED vars

RejectMalformedImport == UNCHANGED vars

Crash ==
    /\ recovered' = {}
    /\ UNCHANGED <<state, cohort, stored, visible, publishedCohorts,
        acknowledged, excluded, authority, headState, fenced,
        staleAdmissionObserved, batchWrites, headWrites, resolutionWrites,
        invalidImportAccepted>>

Recover ==
    /\ visible \subseteq stored
    /\ recovered' = visible
    /\ UNCHANGED <<state, cohort, stored, visible, publishedCohorts,
        acknowledged, excluded, authority, headState, fenced,
        staleAdmissionObserved, batchWrites, headWrites, resolutionWrites,
        invalidImportAccepted>>

Complete ==
    /\ cohort # {}
    /\ \A t \in cohort : state[t] = "Committed"
    /\ cohort' = {}
    /\ headState' = "Collecting"
    /\ UNCHANGED <<state, stored, visible, publishedCohorts, acknowledged,
        excluded, recovered, authority, fenced, staleAdmissionObserved,
        batchWrites, headWrites, resolutionWrites, invalidImportAccepted>>

TypeOK ==
    /\ state \in [Transactions -> States]
    /\ cohort \subseteq Transactions
    /\ stored \subseteq Transactions
    /\ visible \subseteq Transactions
    /\ publishedCohorts \subseteq SUBSET Transactions
    /\ acknowledged \subseteq Transactions
    /\ excluded \subseteq Transactions
    /\ recovered \subseteq Transactions
    /\ authority \subseteq Transactions \X Transactions
    /\ headState \in HeadStates
    /\ fenced \in BOOLEAN
    /\ staleAdmissionObserved \in BOOLEAN
    /\ batchWrites \in Nat
    /\ headWrites \in Nat
    /\ resolutionWrites \in Nat
    /\ invalidImportAccepted \in BOOLEAN

StoredBeforeVisible == visible \subseteq stored
WholeCohortsVisible == visible = UNION publishedCohorts
AcknowledgementSound == acknowledged \subseteq visible
ExcludedStayInvisible == excluded \intersect (cohort \union visible) = {}
ResolutionDoesNotPublish == resolutionWrites = 0
FencingStopsAdmission ==
    /\ ~staleAdmissionObserved
    /\ fenced =>
        /\ cohort = {}
        /\ {t \in Transactions : state[t] \in {"Admitted", "Frozen"}} = {}
AuthorityNamesStoredFinal ==
    authority \subseteq
        {t \in Transactions : state[t] \in {"Unknown", "Committed"}} \X stored
RecoverySound == recovered \subseteq visible
MalformedImportIsNoOp == ~invalidImportAccepted

Safety ==
    /\ TypeOK
    /\ {t \in Transactions : state[t] \in {"Idle", "Admitted"}}
        \intersect visible = {}
    /\ excluded \intersect
        {t \in Transactions : state[t] \in {"Idle", "Admitted"}} = {}
    /\ ({t \in Transactions : state[t] = "Admitted"} # {} =>
        headState = "Collecting")
    /\ {t \in Transactions : state[t] = "Frozen"} \subseteq cohort
    /\ ({t \in Transactions : state[t] = "Frozen"} # {} =>
        headState = "Publishing")
    /\ (headState = "Publishing" =>
        cohort \subseteq {t \in Transactions : state[t] = "Frozen"})
    /\ (headState = "Publishing" => cohort \intersect visible = {})
    /\ StoredBeforeVisible
    /\ WholeCohortsVisible
    /\ AcknowledgementSound
    /\ ExcludedStayInvisible
    /\ ResolutionDoesNotPublish
    /\ FencingStopsAdmission
    /\ AuthorityNamesStoredFinal
    /\ RecoverySound
    /\ MalformedImportIsNoOp

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM AdmitPreservesSafety ==
    \A t \in Transactions : Safety /\ Admit(t) => Safety'
<1> QED BY DEF Admit, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM ExcludePreservesSafety ==
    \A t \in Transactions : Safety /\ Exclude(t) => Safety'
<1> QED BY DEF Exclude, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM FreezePreservesSafety == Safety /\ Freeze => Safety'
<1> QED BY DEF Freeze, Admitted, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM StorePreservesSafety ==
    \A t \in Transactions : Safety /\ Store(t) => Safety'
<1> QED BY DEF Store, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM FailCohortPreservesSafety ==
    \A t \in Transactions : Safety /\ FailCohort(t) => Safety'
<1> QED BY DEF FailCohort, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM PublishPreservesSafety == Safety /\ Publish => Safety'
<1> QED BY DEF Publish, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM RejectHeadPreservesSafety == Safety /\ RejectHead => Safety'
<1> QED BY DEF RejectHead, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM AcknowledgePreservesSafety ==
    \A t \in Transactions : Safety /\ Acknowledge(t) => Safety'
<1> QED BY DEF Acknowledge, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM ResolvePreservesSafety ==
    \A t \in Transactions : Safety /\ Resolve(t) => Safety'
<1> QED BY DEF Resolve, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM ExportAuthorityPreservesSafety ==
    \A t, final \in Transactions : Safety /\ ExportAuthority(t, final) => Safety'
<1> QED BY DEF ExportAuthority, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM ImportAuthorityPreservesSafety ==
    \A t, final \in Transactions : Safety /\ ImportAuthority(t, final) => Safety'
<1> QED BY DEF ImportAuthority, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, vars,
    States, HeadStates

THEOREM RejectMalformedImportPreservesSafety ==
    Safety /\ RejectMalformedImport => Safety'
<1> QED BY DEF RejectMalformedImport, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, vars,
    States, HeadStates

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> QED BY DEF Crash, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM RecoverPreservesSafety == Safety /\ Recover => Safety'
<1> QED BY DEF Recover, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

THEOREM CompletePreservesSafety == Safety /\ Complete => Safety'
<1> QED BY DEF Complete, Safety, TypeOK, StoredBeforeVisible,
    WholeCohortsVisible, AcknowledgementSound, ExcludedStayInvisible,
    ResolutionDoesNotPublish, FencingStopsAdmission,
    AuthorityNamesStoredFinal, RecoverySound, MalformedImportIsNoOp, States,
    HeadStates

=============================================================================
