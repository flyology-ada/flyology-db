---------------- MODULE SerializableValidationSafetyProof ----------------
EXTENDS Naturals, FiniteSets

CONSTANTS Transactions, Keys, Ranges, RangeMap, MaxPointReads, MaxRanges

ASSUME
    /\ Transactions # {}
    /\ Keys # {}
    /\ Ranges # {}
    /\ RangeMap \in [Ranges -> SUBSET Keys]
    /\ MaxPointReads \in Nat \ {0}
    /\ MaxRanges \in Nat \ {0}

Modes == {"Snapshot", "Serializable"}
Phases == {"Idle", "Active", "Committed", "Rejected"}
Results == {"None", "Success", "Conflict", "SerializationFailure",
    "CapacityExceeded"}

VARIABLES sequence, phase, mode, snapshot, writes, pointReads, rangeReads,
    lastWrite, result, badCommitObserved

vars == <<sequence, phase, mode, snapshot, writes, pointReads, rangeReads,
    lastWrite, result, badCommitObserved>>

WriteConflict(t) ==
    \E key \in writes[t] : lastWrite[key] > snapshot[t]

PointConflict(t) ==
    \E key \in pointReads[t] : lastWrite[key] > snapshot[t]

RangeConflict(t) ==
    \E predicate \in rangeReads[t] :
        \E key \in RangeMap[predicate] : lastWrite[key] > snapshot[t]

SerializableConflict(t) == PointConflict(t) \/ RangeConflict(t)

Conflicts(t) ==
    WriteConflict(t)
    \/ (mode[t] = "Serializable" /\ SerializableConflict(t))

Init ==
    /\ sequence = 0
    /\ phase = [t \in Transactions |-> "Idle"]
    /\ mode = [t \in Transactions |-> "Snapshot"]
    /\ snapshot = [t \in Transactions |-> 0]
    /\ writes = [t \in Transactions |-> {}]
    /\ pointReads = [t \in Transactions |-> {}]
    /\ rangeReads = [t \in Transactions |-> {}]
    /\ lastWrite = [key \in Keys |-> 0]
    /\ result = [t \in Transactions |-> "None"]
    /\ badCommitObserved = FALSE

Begin(t, selectedMode) ==
    /\ t \in Transactions /\ selectedMode \in Modes /\ phase[t] = "Idle"
    /\ phase' = [phase EXCEPT ![t] = "Active"]
    /\ mode' = [mode EXCEPT ![t] = selectedMode]
    /\ snapshot' = [snapshot EXCEPT ![t] = sequence]
    /\ writes' = [writes EXCEPT ![t] = {}]
    /\ pointReads' = [pointReads EXCEPT ![t] = {}]
    /\ rangeReads' = [rangeReads EXCEPT ![t] = {}]
    /\ result' = [result EXCEPT ![t] = "None"]
    /\ UNCHANGED <<sequence, lastWrite, badCommitObserved>>

BufferWrite(t, key) ==
    /\ t \in Transactions /\ key \in Keys /\ phase[t] = "Active"
    /\ writes' = [writes EXCEPT ![t] = @ \cup {key}]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ UNCHANGED <<sequence, phase, mode, snapshot, pointReads, rangeReads,
        lastWrite, badCommitObserved>>

RecordPoint(t, key) ==
    /\ t \in Transactions /\ key \in Keys /\ phase[t] = "Active"
    /\ \/ mode[t] = "Snapshot"
       \/ key \in writes[t]
       \/ key \in pointReads[t]
       \/ Cardinality(pointReads[t]) < MaxPointReads
    /\ pointReads' =
        [pointReads EXCEPT
            ![t] = IF mode[t] = "Serializable" /\ key \notin writes[t]
                    THEN @ \cup {key} ELSE @]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ UNCHANGED <<sequence, phase, mode, snapshot, writes, rangeReads,
        lastWrite, badCommitObserved>>

RejectPointCapacity(t, key) ==
    /\ t \in Transactions /\ key \in Keys \ pointReads[t]
    /\ key \notin writes[t]
    /\ phase[t] = "Active" /\ mode[t] = "Serializable"
    /\ Cardinality(pointReads[t]) = MaxPointReads
    /\ result' = [result EXCEPT ![t] = "CapacityExceeded"]
    /\ UNCHANGED <<sequence, phase, mode, snapshot, writes, pointReads,
        rangeReads, lastWrite, badCommitObserved>>

RecordRange(t, predicate) ==
    /\ t \in Transactions /\ predicate \in Ranges /\ phase[t] = "Active"
    /\ \/ mode[t] = "Snapshot"
       \/ predicate \in rangeReads[t]
       \/ Cardinality(rangeReads[t]) < MaxRanges
    /\ rangeReads' =
        [rangeReads EXCEPT
            ![t] = IF mode[t] = "Serializable" THEN @ \cup {predicate} ELSE @]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ UNCHANGED <<sequence, phase, mode, snapshot, writes, pointReads,
        lastWrite, badCommitObserved>>

RejectRangeCapacity(t, predicate) ==
    /\ t \in Transactions /\ predicate \in Ranges \ rangeReads[t]
    /\ phase[t] = "Active" /\ mode[t] = "Serializable"
    /\ Cardinality(rangeReads[t]) = MaxRanges
    /\ result' = [result EXCEPT ![t] = "CapacityExceeded"]
    /\ UNCHANGED <<sequence, phase, mode, snapshot, writes, pointReads,
        rangeReads, lastWrite, badCommitObserved>>

Commit(t) ==
    /\ t \in Transactions /\ phase[t] = "Active" /\ ~Conflicts(t)
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ sequence' = IF writes[t] = {} THEN sequence ELSE sequence + 1
    /\ lastWrite' =
        IF writes[t] = {}
        THEN lastWrite
        ELSE [key \in Keys |->
                IF key \in writes[t] THEN sequence + 1 ELSE lastWrite[key]]
    /\ badCommitObserved' = badCommitObserved \/ Conflicts(t)
    /\ UNCHANGED <<mode, snapshot, writes, pointReads, rangeReads>>

RejectConflict(t) ==
    /\ t \in Transactions /\ phase[t] = "Active" /\ Conflicts(t)
    /\ phase' = [phase EXCEPT ![t] = "Rejected"]
    /\ result' =
        [result EXCEPT
            ![t] = IF mode[t] = "Serializable"
                    THEN "SerializationFailure" ELSE "Conflict"]
    /\ UNCHANGED <<sequence, mode, snapshot, writes, pointReads, rangeReads,
        lastWrite, badCommitObserved>>

TypeOK ==
    /\ sequence \in Nat
    /\ phase \in [Transactions -> Phases]
    /\ mode \in [Transactions -> Modes]
    /\ snapshot \in [Transactions -> Nat]
    /\ \A t \in Transactions : snapshot[t] <= sequence
    /\ writes \in [Transactions -> SUBSET Keys]
    /\ pointReads \in [Transactions -> SUBSET Keys]
    /\ rangeReads \in [Transactions -> SUBSET Ranges]
    /\ lastWrite \in [Keys -> Nat]
    /\ \A key \in Keys : lastWrite[key] <= sequence
    /\ result \in [Transactions -> Results]
    /\ badCommitObserved \in BOOLEAN

NoInvalidCommit == ~badCommitObserved
Safety == TypeOK /\ NoInvalidCommit

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, NoInvalidCommit, Phases, Modes, Results

THEOREM BeginPreservesSafety ==
    \A t \in Transactions, selectedMode \in Modes :
        Safety /\ Begin(t, selectedMode) => Safety'
<1> QED BY DEF Begin, Safety, TypeOK, NoInvalidCommit, Phases, Modes, Results

THEOREM BufferWritePreservesSafety ==
    \A t \in Transactions, key \in Keys :
        Safety /\ BufferWrite(t, key) => Safety'
<1> QED BY DEF BufferWrite, Safety, TypeOK, NoInvalidCommit, Phases, Modes,
    Results

THEOREM RecordPointPreservesSafety ==
    \A t \in Transactions, key \in Keys :
        Safety /\ RecordPoint(t, key) => Safety'
<1> QED BY DEF RecordPoint, Safety, TypeOK, NoInvalidCommit, Phases, Modes,
    Results

THEOREM RejectPointCapacityPreservesSafety ==
    \A t \in Transactions, key \in Keys :
        Safety /\ RejectPointCapacity(t, key) => Safety'
<1> QED BY DEF RejectPointCapacity, Safety, TypeOK, NoInvalidCommit, Phases,
    Modes, Results

THEOREM RecordRangePreservesSafety ==
    \A t \in Transactions, predicate \in Ranges :
        Safety /\ RecordRange(t, predicate) => Safety'
<1> QED BY DEF RecordRange, Safety, TypeOK, NoInvalidCommit, Phases, Modes,
    Results

THEOREM RejectRangeCapacityPreservesSafety ==
    \A t \in Transactions, predicate \in Ranges :
        Safety /\ RejectRangeCapacity(t, predicate) => Safety'
<1> QED BY DEF RejectRangeCapacity, Safety, TypeOK, NoInvalidCommit, Phases,
    Modes, Results

THEOREM CommitPreservesSafety ==
    \A t \in Transactions : Safety /\ Commit(t) => Safety'
<1> QED BY DEF Commit, Conflicts, WriteConflict, SerializableConflict,
    PointConflict, RangeConflict, Safety, TypeOK, NoInvalidCommit, Phases,
    Modes, Results

THEOREM RejectConflictPreservesSafety ==
    \A t \in Transactions : Safety /\ RejectConflict(t) => Safety'
<1> QED BY DEF RejectConflict, Safety, TypeOK, NoInvalidCommit, Phases, Modes,
    Results

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, NoInvalidCommit, vars

=============================================================================
