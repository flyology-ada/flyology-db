---------------------- MODULE SerializableValidation ----------------------
EXTENDS Naturals, FiniteSets, TLC

(***************************************************************************
This finite model freezes serializable validation independently from the Ada
API shape. Snapshot transactions reject only post-snapshot writes to their own
write set. Serializable transactions additionally retain successful/absent
point reads and normalized range predicates, then reject when later committed
writes intersect either observation. Two transactions, keys, ranges, and
one-slot point/range sets are complete qualification geometry for these
conflict and capacity paths; they are not product limits or defaults.
***************************************************************************)

CONSTANTS T1, T2, K1, K2, R1, R2

Transactions == {T1, T2}
Keys == {K1, K2}
Ranges == {R1, R2}
Modes == {"Snapshot", "Serializable"}
Phases == {"Idle", "Active", "Committed", "Rejected"}
Results == {"None", "Success", "Conflict", "SerializationFailure",
    "CapacityExceeded"}

(***************************************************************************
Modeled keys are exact (column family, byte key) identities. R1 is the
half-open predicate containing K1; R2 contains both modeled identities, so
RangeMembers already includes same-family selection. This exact ordering is
witness geometry only and does not define byte-key ordering, a public range
representation, or a scan normalization policy.
***************************************************************************)
RangeMembers(r) == IF r = R1 THEN {K1} ELSE Keys

(***************************************************************************
One retained point and one retained range are qualification-only capacities:
each admits one observation and forces the next distinct observation through
the capacity-rejection path. Persisted or caller-supplied product limits will
remain independent from this finite-model geometry.
***************************************************************************)
MaxPointReads == 1
MaxRanges == 1

VARIABLES sequence, phase, mode, snapshot, writes, pointReads, rangeReads,
    lastWrite, result, badCommitObserved, lastAction

vars == <<sequence, phase, mode, snapshot, writes, pointReads, rangeReads,
    lastWrite, result, badCommitObserved, lastAction>>

WriteConflict(t) ==
    \E key \in writes[t] : lastWrite[key] > snapshot[t]

PointConflict(t) ==
    \E key \in pointReads[t] : lastWrite[key] > snapshot[t]

RangeConflict(t) ==
    \E predicate \in rangeReads[t] :
        \E key \in RangeMembers(predicate) : lastWrite[key] > snapshot[t]

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
    /\ lastAction = "Init"

Begin(t, selectedMode) ==
    /\ t \in Transactions
    /\ selectedMode \in Modes
    /\ phase[t] = "Idle"
    /\ phase' = [phase EXCEPT ![t] = "Active"]
    /\ mode' = [mode EXCEPT ![t] = selectedMode]
    /\ snapshot' = [snapshot EXCEPT ![t] = sequence]
    /\ writes' = [writes EXCEPT ![t] = {}]
    /\ pointReads' = [pointReads EXCEPT ![t] = {}]
    /\ rangeReads' = [rangeReads EXCEPT ![t] = {}]
    /\ result' = [result EXCEPT ![t] = "None"]
    /\ lastAction' = "Begin"
    /\ UNCHANGED <<sequence, lastWrite, badCommitObserved>>

BufferWrite(t, key) ==
    /\ t \in Transactions
    /\ key \in Keys
    /\ phase[t] = "Active"
    /\ writes' = [writes EXCEPT ![t] = @ \cup {key}]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ lastAction' = "BufferWrite"
    /\ UNCHANGED <<sequence, phase, mode, snapshot, pointReads, rangeReads,
        lastWrite, badCommitObserved>>

RecordPoint(t, key) ==
    /\ t \in Transactions
    /\ key \in Keys
    /\ phase[t] = "Active"
    /\ \/ mode[t] = "Snapshot"
       \/ key \in writes[t]
       \/ key \in pointReads[t]
       \/ Cardinality(pointReads[t]) < MaxPointReads
    /\ pointReads' =
        [pointReads EXCEPT
            ![t] = IF mode[t] = "Serializable" /\ key \notin writes[t]
                    THEN @ \cup {key} ELSE @]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ lastAction' = "RecordPoint"
    /\ UNCHANGED <<sequence, phase, mode, snapshot, writes, rangeReads,
        lastWrite, badCommitObserved>>

RejectPointCapacity(t, key) ==
    /\ t \in Transactions
    /\ key \in Keys \ pointReads[t]
    /\ key \notin writes[t]
    /\ phase[t] = "Active"
    /\ mode[t] = "Serializable"
    /\ Cardinality(pointReads[t]) = MaxPointReads
    /\ result' = [result EXCEPT ![t] = "CapacityExceeded"]
    /\ lastAction' = "RejectPointCapacity"
    /\ UNCHANGED <<sequence, phase, mode, snapshot, writes, pointReads,
        rangeReads, lastWrite, badCommitObserved>>

RecordRange(t, predicate) ==
    /\ t \in Transactions
    /\ predicate \in Ranges
    /\ phase[t] = "Active"
    /\ \/ mode[t] = "Snapshot"
       \/ predicate \in rangeReads[t]
       \/ Cardinality(rangeReads[t]) < MaxRanges
    /\ rangeReads' =
        [rangeReads EXCEPT
            ![t] = IF mode[t] = "Serializable" THEN @ \cup {predicate} ELSE @]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ lastAction' = "RecordRange"
    /\ UNCHANGED <<sequence, phase, mode, snapshot, writes, pointReads,
        lastWrite, badCommitObserved>>

RejectRangeCapacity(t, predicate) ==
    /\ t \in Transactions
    /\ predicate \in Ranges \ rangeReads[t]
    /\ phase[t] = "Active"
    /\ mode[t] = "Serializable"
    /\ Cardinality(rangeReads[t]) = MaxRanges
    /\ result' = [result EXCEPT ![t] = "CapacityExceeded"]
    /\ lastAction' = "RejectRangeCapacity"
    /\ UNCHANGED <<sequence, phase, mode, snapshot, writes, pointReads,
        rangeReads, lastWrite, badCommitObserved>>

Commit(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ ~Conflicts(t)
    /\ phase' = [phase EXCEPT ![t] = "Committed"]
    /\ result' = [result EXCEPT ![t] = "Success"]
    /\ sequence' = IF writes[t] = {} THEN sequence ELSE sequence + 1
    /\ lastWrite' =
        IF writes[t] = {}
        THEN lastWrite
        ELSE [key \in Keys |->
                IF key \in writes[t] THEN sequence + 1 ELSE lastWrite[key]]
    /\ badCommitObserved' = badCommitObserved \/ Conflicts(t)
    /\ lastAction' = "Commit"
    /\ UNCHANGED <<mode, snapshot, writes, pointReads, rangeReads>>

RejectConflict(t) ==
    /\ t \in Transactions
    /\ phase[t] = "Active"
    /\ Conflicts(t)
    /\ phase' = [phase EXCEPT ![t] = "Rejected"]
    /\ result' =
        [result EXCEPT
            ![t] = IF mode[t] = "Serializable"
                    THEN "SerializationFailure" ELSE "Conflict"]
    /\ lastAction' = "RejectConflict"
    /\ UNCHANGED <<sequence, mode, snapshot, writes, pointReads, rangeReads,
        lastWrite, badCommitObserved>>

Quiesce == UNCHANGED vars

Next ==
    \/ \E t \in Transactions, selectedMode \in Modes : Begin(t, selectedMode)
    \/ \E t \in Transactions, key \in Keys : BufferWrite(t, key)
    \/ \E t \in Transactions, key \in Keys : RecordPoint(t, key)
    \/ \E t \in Transactions, key \in Keys : RejectPointCapacity(t, key)
    \/ \E t \in Transactions, predicate \in Ranges : RecordRange(t, predicate)
    \/ \E t \in Transactions, predicate \in Ranges : RejectRangeCapacity(t, predicate)
    \/ \E t \in Transactions : Commit(t)
    \/ \E t \in Transactions : RejectConflict(t)
    \/ Quiesce

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ sequence \in Nat
    /\ phase \in [Transactions -> Phases]
    /\ mode \in [Transactions -> Modes]
    /\ snapshot \in [Transactions -> Nat]
    /\ \A t \in Transactions : snapshot[t] <= sequence
    /\ writes \in [Transactions -> SUBSET Keys]
    /\ pointReads \in [Transactions -> SUBSET Keys]
    /\ \A t \in Transactions : Cardinality(pointReads[t]) <= MaxPointReads
    /\ rangeReads \in [Transactions -> SUBSET Ranges]
    /\ \A t \in Transactions : Cardinality(rangeReads[t]) <= MaxRanges
    /\ lastWrite \in [Keys -> Nat]
    /\ \A key \in Keys : lastWrite[key] <= sequence
    /\ result \in [Transactions -> Results]
    /\ badCommitObserved \in BOOLEAN
    /\ lastAction \in {"Init", "Begin", "BufferWrite", "RecordPoint",
        "RejectPointCapacity", "RecordRange", "RejectRangeCapacity",
        "Commit", "RejectConflict"}

NoInvalidCommit == ~badCommitObserved

Safety == TypeOK /\ NoInvalidCommit

=============================================================================
