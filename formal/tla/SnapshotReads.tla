---------------------------- MODULE SnapshotReads -------------------------
EXTENDS Naturals, TLC

(***************************************************************************
This finite model freezes fixed point reads after write validation. A read
first observes the transaction's own buffered Put/Delete. Otherwise it selects
the newest committed version no later than the Begin sequence. A transaction
older than the retained checkpoint boundary receives TooOld rather than a
value assembled from incomplete evidence. Two committed version slots are
complete for this two-transaction qualification geometry; they are not a DB
retention limit. The Ada implementation is not claimed as a refinement.
***************************************************************************)

CONSTANTS T1, T2, V1, V2

Transactions == {T1, T2}
Values == {V1, V2}
CellValues == Values \cup {"Absent"}
ReadResults == CellValues \cup {"TooOld"}
Phases == {"Idle", "Active", "Committed"}
BufferKinds == {"None", "Put", "Delete"}

VARIABLES sequence, checkpointBoundary, phase, snapshot, bufferKind,
    bufferValue, latestSeq, latestValue, previousSeq, previousValue, observed,
    badReadObserved, lastAction

vars == <<sequence, checkpointBoundary, phase, snapshot, bufferKind,
    bufferValue, latestSeq, latestValue, previousSeq, previousValue, observed,
    badReadObserved, lastAction>>

CommittedAt(t) ==
    IF snapshot[t] < checkpointBoundary THEN "TooOld"
    ELSE IF latestSeq <= snapshot[t] THEN latestValue
    ELSE IF previousSeq <= snapshot[t] THEN previousValue
    ELSE "TooOld"

ExpectedRead(t) ==
    IF bufferKind[t] = "Put" THEN bufferValue[t]
    ELSE IF bufferKind[t] = "Delete" THEN "Absent"
    ELSE CommittedAt(t)

(***************************************************************************
Sequence one and V1 seed one exact committed base value so the old-value
witness must select a real prior version. They are scenario fixtures, not a
persisted initial sequence, value default, or retention policy.
***************************************************************************)
Init ==
    /\ sequence = 1
    /\ checkpointBoundary = 0
    /\ phase = [t \in Transactions |-> "Idle"]
    /\ snapshot = [t \in Transactions |-> 0]
    /\ bufferKind = [t \in Transactions |-> "None"]
    /\ bufferValue = [t \in Transactions |-> V1]
    /\ latestSeq = 1
    /\ latestValue = V1
    /\ previousSeq = 0
    /\ previousValue = "Absent"
    /\ observed = [t \in Transactions |-> "Absent"]
    /\ badReadObserved = FALSE
    /\ lastAction = "Init"

Begin(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Idle"
    /\ phase' = [phase EXCEPT ![t] = "Active"]
    /\ snapshot' = [snapshot EXCEPT ![t] = sequence]
    /\ bufferKind' = [bufferKind EXCEPT ![t] = "None"]
    /\ lastAction' = "Begin"
    /\ UNCHANGED <<sequence, checkpointBoundary, bufferValue, latestSeq,
        latestValue, previousSeq, previousValue, observed, badReadObserved>>

BufferPut(t, value) ==
    /\ t \in Transactions
    /\ value \in Values
    /\ phase[t] = "Active"
    /\ bufferKind' = [bufferKind EXCEPT ![t] = "Put"]
    /\ bufferValue' = [bufferValue EXCEPT ![t] = value]
    /\ lastAction' = "BufferPut"
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, latestSeq,
        latestValue, previousSeq, previousValue, observed, badReadObserved>>

BufferDelete(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ bufferKind' = [bufferKind EXCEPT ![t] = "Delete"]
    /\ lastAction' = "BufferDelete"
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, bufferValue,
        latestSeq, latestValue, previousSeq, previousValue, observed,
        badReadObserved>>

Commit(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ bufferKind[t] # "None"
    /\ sequence' = sequence + 1
    /\ previousSeq' = latestSeq
    /\ previousValue' = latestValue
    /\ latestSeq' = sequence + 1
    /\ latestValue' = IF bufferKind[t] = "Put" THEN bufferValue[t] ELSE "Absent"
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ lastAction' = "Commit"
    /\ UNCHANGED <<checkpointBoundary, snapshot, bufferKind, bufferValue,
        observed, badReadObserved>>

RecordRead(t, selected) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ selected \in ReadResults
    /\ observed' = [observed EXCEPT ![t] = selected]
    /\ badReadObserved' = badReadObserved \/ (selected # ExpectedRead(t))
    /\ lastAction' = "Read"
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, bufferKind,
        bufferValue, latestSeq, latestValue, previousSeq, previousValue>>

Read(t) == RecordRead(t, ExpectedRead(t))

Checkpoint ==
    /\ checkpointBoundary' = sequence
    /\ lastAction' = "Checkpoint"
    /\ UNCHANGED <<sequence, phase, snapshot, bufferKind, bufferValue,
        latestSeq, latestValue, previousSeq, previousValue, observed,
        badReadObserved>>

Next ==
    \/ \E t \in Transactions : Begin(t)
    \/ \E t \in Transactions, value \in Values : BufferPut(t, value)
    \/ \E t \in Transactions : BufferDelete(t)
    \/ \E t \in Transactions : Commit(t)
    \/ \E t \in Transactions : Read(t)
    \/ Checkpoint

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ sequence \in Nat
    /\ checkpointBoundary \in Nat
    /\ checkpointBoundary <= sequence
    /\ phase \in [Transactions -> Phases]
    /\ snapshot \in [Transactions -> Nat]
    /\ \A t \in Transactions : snapshot[t] <= sequence
    /\ bufferKind \in [Transactions -> BufferKinds]
    /\ bufferValue \in [Transactions -> Values]
    /\ previousSeq \in Nat
    /\ latestSeq \in Nat
    /\ previousSeq <= latestSeq
    /\ latestSeq <= sequence
    /\ previousValue \in CellValues
    /\ latestValue \in CellValues
    /\ observed \in [Transactions -> ReadResults]
    /\ badReadObserved \in BOOLEAN
    /\ lastAction \in {"Init", "Begin", "BufferPut", "BufferDelete", "Commit",
        "Read", "Checkpoint"}

NoBadRead == ~badReadObserved

Safety == TypeOK /\ NoBadRead

=============================================================================
