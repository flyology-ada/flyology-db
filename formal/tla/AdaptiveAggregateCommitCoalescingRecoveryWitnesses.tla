-------- MODULE AdaptiveAggregateCommitCoalescingRecoveryWitnesses --------
EXTENDS AdaptiveAggregateCommitCoalescingWitnesses

(***************************************************************************
These focused witness specifications retain the exact crash provenance that
cannot be inferred from a terminal state alone. They constrain only bounded
reachability evidence; the positive model, safety invariants, and scheduler
geometry remain unchanged.
***************************************************************************)

VARIABLE pc
recoveryVars == <<s, pc>>

RecoveryInit == Init /\ pc = 0

AuthorityRecoveryNext ==
    \/ /\ pc = 0 /\ Admit(T1) /\ pc' = 1
    \/ /\ pc = 1 /\ Admit(T2) /\ pc' = 2
    \/ /\ pc = 2 /\ FreezeCohort /\ pc' = 3
    \/ /\ pc = 3 /\ PublishAggregate("Confirmed") /\ pc' = 4
    \/ /\ pc = 4 /\ BeginHeadAttempt /\ pc' = 5
    \/ /\ pc = 5 /\ HeadResponseLost(TRUE) /\ pc' = 6
    \/ /\ pc = 6 /\ ExportAuthority(T1) /\ pc' = 7
    \/ /\ pc = 7 /\ ExportAuthority(T2) /\ pc' = 8
    \/ /\ pc = 8 /\ Crash(FALSE) /\ pc' = 9
    \/ /\ pc = 9 /\ ReopenFromHead /\ pc' = 10
    \/ /\ pc = 10 /\ ImportAuthority(T1) /\ pc' = 11
    \/ /\ pc = 11 /\ ImportAuthority(T2) /\ pc' = 12
    \/ /\ pc = 12 /\ ResolveMember(T1) /\ pc' = 13

AuthorityRecoverySpec == RecoveryInit /\ [][AuthorityRecoveryNext]_recoveryVars

CrashBeforeHeadRecoveryNext ==
    \/ /\ pc = 0 /\ Admit(T1) /\ pc' = 1
    \/ /\ pc = 1 /\ Admit(T2) /\ pc' = 2
    \/ /\ pc = 2 /\ FreezeCohort /\ pc' = 3
    \/ /\ pc = 3 /\ PublishAggregate("Confirmed") /\ pc' = 4
    \/ /\ pc = 4 /\ BeginHeadAttempt /\ pc' = 5
    \/ /\ pc = 5 /\ Crash(FALSE) /\ pc' = 6
    \/ /\ pc = 6 /\ ReopenFromHead /\ pc' = 7

CrashBeforeHeadRecoverySpec ==
    RecoveryInit /\ [][CrashBeforeHeadRecoveryNext]_recoveryVars

CrashAfterHeadRecoveryNext ==
    \/ /\ pc = 0 /\ Admit(T1) /\ pc' = 1
    \/ /\ pc = 1 /\ Admit(T2) /\ pc' = 2
    \/ /\ pc = 2 /\ FreezeCohort /\ pc' = 3
    \/ /\ pc = 3 /\ PublishAggregate("Confirmed") /\ pc' = 4
    \/ /\ pc = 4 /\ BeginHeadAttempt /\ pc' = 5
    \/ /\ pc = 5 /\ Crash(TRUE) /\ pc' = 6
    \/ /\ pc = 6 /\ ReopenFromHead /\ pc' = 7

CrashAfterHeadRecoverySpec ==
    RecoveryInit /\ [][CrashAfterHeadRecoveryNext]_recoveryVars

RecoveryTrace == [state |-> Trace, step |-> pc]

=============================================================================
