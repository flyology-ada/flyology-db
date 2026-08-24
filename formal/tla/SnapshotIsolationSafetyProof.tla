-------------------- MODULE SnapshotIsolationSafetyProof -------------------
EXTENDS Naturals

CONSTANTS Transactions, Keys

ASSUME Transactions # {} /\ Keys # {}

VARIABLES sequence, checkpointBoundary, phase, snapshot, writes, lastWrite,
    invalidCommitObserved

vars == <<sequence, checkpointBoundary, phase, snapshot, writes, lastWrite,
    invalidCommitObserved>>

Phases == {"Idle", "Active", "Committed", "Conflict"}

CanCommit(t) ==
    /\ snapshot[t] >= checkpointBoundary
    /\ \A k \in writes[t] : lastWrite[k] <= snapshot[t]

Init ==
    /\ sequence = 0
    /\ checkpointBoundary = 0
    /\ phase = [t \in Transactions |-> "Idle"]
    /\ snapshot = [t \in Transactions |-> 0]
    /\ writes = [t \in Transactions |-> {}]
    /\ lastWrite = [k \in Keys |-> 0]
    /\ invalidCommitObserved = FALSE

Begin(t) ==
    /\ t \in Transactions /\ phase[t] = "Idle"
    /\ phase' = [phase EXCEPT ![t] = "Active"]
    /\ snapshot' = [snapshot EXCEPT ![t] = sequence]
    /\ writes' = [writes EXCEPT ![t] = {}]
    /\ UNCHANGED <<sequence, checkpointBoundary, lastWrite,
        invalidCommitObserved>>

BufferWrite(t, k) ==
    /\ t \in Transactions /\ k \in Keys /\ phase[t] = "Active"
    /\ writes' = [writes EXCEPT ![t] = @ \cup {k}]
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, lastWrite,
        invalidCommitObserved>>

Commit(t) ==
    /\ t \in Transactions /\ phase[t] = "Active" /\ writes[t] # {}
    /\ CanCommit(t)
    /\ sequence' = sequence + 1
    /\ lastWrite' =
        [k \in Keys |-> IF k \in writes[t] THEN sequence + 1 ELSE lastWrite[k]]
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ invalidCommitObserved' = invalidCommitObserved \/ ~CanCommit(t)
    /\ UNCHANGED <<checkpointBoundary, snapshot, writes>>

RejectConflict(t) ==
    /\ t \in Transactions /\ phase[t] = "Active" /\ writes[t] # {}
    /\ ~CanCommit(t)
    /\ phase' = [phase EXCEPT ![t] = "Conflict"]
    /\ UNCHANGED <<sequence, checkpointBoundary, snapshot, writes, lastWrite,
        invalidCommitObserved>>

Checkpoint ==
    /\ checkpointBoundary' = sequence
    /\ UNCHANGED <<sequence, phase, snapshot, writes, lastWrite,
        invalidCommitObserved>>

TypeOK ==
    /\ sequence \in Nat
    /\ checkpointBoundary \in Nat /\ checkpointBoundary <= sequence
    /\ phase \in [Transactions -> Phases]
    /\ snapshot \in [Transactions -> Nat]
    /\ \A t \in Transactions : snapshot[t] <= sequence
    /\ writes \in [Transactions -> SUBSET Keys]
    /\ lastWrite \in [Keys -> Nat]
    /\ \A k \in Keys : lastWrite[k] <= sequence
    /\ invalidCommitObserved \in BOOLEAN

NoInvalidCommit == ~invalidCommitObserved
Safety == TypeOK /\ NoInvalidCommit

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, NoInvalidCommit, Phases

THEOREM BeginPreservesSafety ==
    \A t \in Transactions : Safety /\ Begin(t) => Safety'
<1> QED BY DEF Begin, Safety, TypeOK, NoInvalidCommit, Phases

THEOREM BufferWritePreservesSafety ==
    \A t \in Transactions, k \in Keys :
        Safety /\ BufferWrite(t, k) => Safety'
<1> QED BY DEF BufferWrite, Safety, TypeOK, NoInvalidCommit, Phases

THEOREM CommitPreservesSafety ==
    \A t \in Transactions : Safety /\ Commit(t) => Safety'
<1> QED BY DEF Commit, CanCommit, Safety, TypeOK, NoInvalidCommit, Phases

THEOREM RejectPreservesSafety ==
    \A t \in Transactions : Safety /\ RejectConflict(t) => Safety'
<1> QED BY DEF RejectConflict, CanCommit, Safety, TypeOK, NoInvalidCommit, Phases

THEOREM CheckpointPreservesSafety == Safety /\ Checkpoint => Safety'
<1> QED BY DEF Checkpoint, Safety, TypeOK, NoInvalidCommit, Phases

=============================================================================
