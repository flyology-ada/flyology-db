--------------------- MODULE SnapshotReadsSafetyProof ---------------------
EXTENDS Naturals

CONSTANTS Transactions, Values, DefaultValue

ASSUME Transactions # {} /\ Values # {} /\ DefaultValue \in Values

CellValues == Values \cup {"Absent"}
ReadResults == CellValues \cup {"TooOld"}
Phases == {"Idle", "Active", "Committed"}
BufferKinds == {"None", "Put", "Delete"}

VARIABLES sequence, checkpointBoundary, phase, snapshot, bufferKind,
    bufferValue, latestSeq, latestValue, previousSeq, previousValue, observed,
    badReadObserved

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
The proof seed mirrors the finite scenario's one committed base value. One is
proof geometry only; it does not establish a DB initial-sequence policy.
***************************************************************************)
Init ==
    /\ sequence = 1
    /\ checkpointBoundary = 0
    /\ phase = [t \in Transactions |-> "Idle"]
    /\ snapshot = [t \in Transactions |-> 0]
    /\ bufferKind = [t \in Transactions |-> "None"]
    /\ bufferValue = [t \in Transactions |-> DefaultValue]
    /\ latestSeq = 1
    /\ latestValue = DefaultValue
    /\ previousSeq = 0
    /\ previousValue = "Absent"
    /\ observed = [t \in Transactions |-> "Absent"]
    /\ badReadObserved = FALSE

Begin(t) ==
    /\ t \in Transactions /\ phase[t] = "Idle"
    /\ phase' = [phase EXCEPT ![t] = "Active"]
    /\ snapshot' = [snapshot EXCEPT ![t] = sequence]
    /\ bufferKind' = [bufferKind EXCEPT ![t] = "None"]
    /\ UNCHANGED <<sequence, checkpointBoundary, bufferValue, latestSeq,
        latestValue, previousSeq, previousValue, observed, badReadObserved>>

BufferPut(t, value) ==
    /\ t \in Transactions /\ value \in Values /\ phase[t] = "Active"
    /\ bufferKind' = [bufferKind EXCEPT ![t] = "Put"]
    /\ bufferValue' = [bufferValue EXCEPT ![t] = value]
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, latestSeq,
        latestValue, previousSeq, previousValue, observed, badReadObserved>>

BufferDelete(t) ==
    /\ t \in Transactions /\ phase[t] = "Active"
    /\ bufferKind' = [bufferKind EXCEPT ![t] = "Delete"]
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, bufferValue,
        latestSeq, latestValue, previousSeq, previousValue, observed,
        badReadObserved>>

Commit(t) ==
    /\ t \in Transactions /\ phase[t] = "Active" /\ bufferKind[t] # "None"
    /\ sequence' = sequence + 1
    /\ previousSeq' = latestSeq
    /\ previousValue' = latestValue
    /\ latestSeq' = sequence + 1
    /\ latestValue' = IF bufferKind[t] = "Put" THEN bufferValue[t] ELSE "Absent"
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ UNCHANGED <<checkpointBoundary, snapshot, bufferKind, bufferValue,
        observed, badReadObserved>>

RecordRead(t, selected) ==
    /\ t \in Transactions /\ phase[t] = "Active"
    /\ selected \in ReadResults
    /\ observed' = [observed EXCEPT ![t] = selected]
    /\ badReadObserved' = badReadObserved \/ (selected # ExpectedRead(t))
    /\ UNCHANGED <<sequence, checkpointBoundary, phase, snapshot, bufferKind,
        bufferValue, latestSeq, latestValue, previousSeq, previousValue>>

Read(t) == RecordRead(t, ExpectedRead(t))

Checkpoint ==
    /\ checkpointBoundary' = sequence
    /\ UNCHANGED <<sequence, phase, snapshot, bufferKind, bufferValue,
        latestSeq, latestValue, previousSeq, previousValue, observed,
        badReadObserved>>

TypeOK ==
    /\ sequence \in Nat
    /\ checkpointBoundary \in Nat /\ checkpointBoundary <= sequence
    /\ phase \in [Transactions -> Phases]
    /\ snapshot \in [Transactions -> Nat]
    /\ \A t \in Transactions : snapshot[t] <= sequence
    /\ bufferKind \in [Transactions -> BufferKinds]
    /\ bufferValue \in [Transactions -> Values]
    /\ previousSeq \in Nat /\ latestSeq \in Nat
    /\ previousSeq <= latestSeq /\ latestSeq <= sequence
    /\ previousValue \in CellValues /\ latestValue \in CellValues
    /\ observed \in [Transactions -> ReadResults]
    /\ badReadObserved \in BOOLEAN

NoBadRead == ~badReadObserved
Safety == TypeOK /\ NoBadRead

THEOREM InitialSafety == DefaultValue \in Values /\ Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, NoBadRead, Phases, BufferKinds,
    CellValues, ReadResults

THEOREM BeginPreservesSafety ==
    \A t \in Transactions : Safety /\ Begin(t) => Safety'
<1> QED BY DEF Begin, Safety, TypeOK, NoBadRead, Phases, BufferKinds,
    CellValues, ReadResults

THEOREM PutPreservesSafety ==
    \A t \in Transactions, value \in Values :
        Safety /\ BufferPut(t, value) => Safety'
<1> QED BY DEF BufferPut, Safety, TypeOK, NoBadRead, Phases, BufferKinds,
    CellValues, ReadResults

THEOREM DeletePreservesSafety ==
    \A t \in Transactions : Safety /\ BufferDelete(t) => Safety'
<1> QED BY DEF BufferDelete, Safety, TypeOK, NoBadRead, Phases, BufferKinds,
    CellValues, ReadResults

THEOREM CommitPreservesSafety ==
    \A t \in Transactions : Safety /\ Commit(t) => Safety'
<1> QED BY DEF Commit, Safety, TypeOK, NoBadRead, Phases, BufferKinds,
    CellValues, ReadResults

THEOREM ReadPreservesSafety ==
    \A t \in Transactions : Safety /\ Read(t) => Safety'
<1> QED BY DEF Read, ExpectedRead, CommittedAt, Safety, TypeOK, NoBadRead,
    RecordRead, Phases, BufferKinds, CellValues, ReadResults

THEOREM CheckpointPreservesSafety == Safety /\ Checkpoint => Safety'
<1> QED BY DEF Checkpoint, Safety, TypeOK, NoBadRead, Phases, BufferKinds,
    CellValues, ReadResults

=============================================================================
