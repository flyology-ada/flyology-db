------------------------- MODULE SnapshotIsolation -------------------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
This finite model freezes the first runtime snapshot-isolation rule. A
transaction captures the global sequence at Begin, buffers a nonempty write
set, and may commit only when retained evidence proves that none of those keys
was written later. A checkpoint advances the oldest exact history boundary
without ending active transactions. Transactions older than that boundary are
rejected conservatively because a compacted delete may no longer be present in
live state. The Ada implementation is not claimed as a refinement.
***************************************************************************)

CONSTANTS T1, T2, K1, K2

Transactions == {T1, T2}
Keys == {K1, K2}
Phases == {"Idle", "Active", "Committed", "Conflict"}

VARIABLES sequence, checkpointBoundary, phase, snapshot, writes, lastWrite,
    invalidCommitObserved, lastAction

vars == <<sequence, checkpointBoundary, phase, snapshot, writes, lastWrite,
    invalidCommitObserved, lastAction>>

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
    /\ lastAction = "Init"

Begin(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Idle"
    /\ phase' = [phase EXCEPT ![t] = "Active"]
    /\ snapshot' = [snapshot EXCEPT ![t] = sequence]
    /\ writes' = [writes EXCEPT ![t] = {}]
    /\ lastAction' = "Begin"
    /\ UNCHANGED <<sequence, checkpointBoundary, lastWrite,
        invalidCommitObserved>>

BufferWrite(t, k) ==
    /\ t \in Transactions
    /\ k \in Keys
    /\ phase[t] = "Active"
    /\ writes' = [writes EXCEPT ![t] = @ \cup {k}]
    /\ lastAction' = "BufferWrite"
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, lastWrite,
        invalidCommitObserved>>

Commit(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ writes[t] # {}
    /\ CanCommit(t)
    /\ sequence' = sequence + 1
    /\ lastWrite' =
        [k \in Keys |-> IF k \in writes[t] THEN sequence + 1 ELSE lastWrite[k]]
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ invalidCommitObserved' = invalidCommitObserved \/ ~CanCommit(t)
    /\ lastAction' = "Commit"
    /\ UNCHANGED <<checkpointBoundary, snapshot, writes>>

RejectConflict(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ writes[t] # {}
    /\ ~CanCommit(t)
    /\ phase' = [phase EXCEPT ![t] = "Conflict"]
    /\ lastAction' = "RejectConflict"
    /\ UNCHANGED <<sequence, checkpointBoundary, snapshot, writes, lastWrite,
        invalidCommitObserved>>

Checkpoint ==
    /\ checkpointBoundary' = sequence
    /\ lastAction' = "Checkpoint"
    /\ UNCHANGED <<sequence, phase, snapshot, writes, lastWrite,
        invalidCommitObserved>>

Next ==
    \/ \E t \in Transactions : Begin(t)
    \/ \E t \in Transactions, k \in Keys : BufferWrite(t, k)
    \/ \E t \in Transactions : Commit(t)
    \/ \E t \in Transactions : RejectConflict(t)
    \/ Checkpoint

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ sequence \in Nat
    /\ checkpointBoundary \in Nat
    /\ checkpointBoundary <= sequence
    /\ phase \in [Transactions -> Phases]
    /\ snapshot \in [Transactions -> Nat]
    /\ \A t \in Transactions : snapshot[t] <= sequence
    /\ writes \in [Transactions -> SUBSET Keys]
    /\ lastWrite \in [Keys -> Nat]
    /\ \A k \in Keys : lastWrite[k] <= sequence
    /\ invalidCommitObserved \in BOOLEAN
    /\ lastAction \in {"Init", "Begin", "BufferWrite", "Commit",
        "RejectConflict", "Checkpoint"}

NoInvalidCommit == ~invalidCommitObserved

Safety == TypeOK /\ NoInvalidCommit

=============================================================================
