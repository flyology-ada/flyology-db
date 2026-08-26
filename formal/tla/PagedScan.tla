----------------------------- MODULE PagedScan -----------------------------
EXTENDS FiniteSets, Naturals, Sequences, TLC

(***************************************************************************
This finite model freezes caller-bounded page iteration over one fixed
transaction snapshot. Four ordered one-byte keys, three value extents, one
older row per key, and a newest tombstone expose ordering, byte/row
backpressure, tombstone masking, concurrent replacement/deletion, allocation
rollback, and exact completion. These dimensions are qualification geometry,
not database page defaults, key/value limits, or retained-history policy.

Each successful page is the maximal next prefix that fits both caller budgets.
An empty budget or an individually oversized next row reports capacity without
advancing the cursor or replacing the previous page. Allocation rejection is
equally atomic. Current authority may change after Begin, but every page is
selected from the captured snapshot. No refinement to Ada is claimed.
***************************************************************************)

Keys == 1 .. 4
Values == {"A", "B", "C"}
NewestStates == Values \cup {"Unchanged", "Tombstone"}
Rows == [key : Keys, value : Values]

OlderValues == [key \in Keys |-> "A"]
InitialNewest ==
    [key \in Keys |->
        CASE key = 1 -> "Unchanged"
          [] key = 2 -> "Tombstone"
          [] key = 3 -> "B"
          [] OTHER -> "Unchanged"]

VisibleValue(newest, key) ==
    IF newest[key] = "Unchanged" THEN OlderValues[key]
    ELSE IF newest[key] = "Tombstone" THEN "Absent"
    ELSE newest[key]

VisibleKeys(newest) ==
    SelectSeq(<<1, 2, 3, 4>>,
        LAMBDA key : VisibleValue(newest, key) # "Absent")

VisibleRows(newest) ==
    LET keys == VisibleKeys(newest)
    IN [index \in 1 .. Len(keys) |->
        [key |-> keys[index], value |-> VisibleValue(newest, keys[index])]]

ScanRows(newest, emptyView) ==
    IF emptyView THEN <<>> ELSE VisibleRows(newest)

(***************************************************************************
One byte per finite key and one/two/three bytes for A/B/C make row-byte
accounting observable independently from row count. The values are model
geometry only; production derives exact extents from caller bytes.
***************************************************************************)
ValueBytes ==
    [value \in Values |->
        CASE value = "A" -> 1
          [] value = "B" -> 2
          [] OTHER -> 3]
RowBytes(row) == 1 + ValueBytes[row.value]

RECURSIVE PrefixBytes(_, _)
PrefixBytes(rows, count) ==
    IF count = 0 THEN 0
    ELSE PrefixBytes(rows, count - 1) + RowBytes(rows[count])

PrefixCounts(rows, rowLimit, byteLimit) ==
    {count \in 0 .. Len(rows) :
        count <= rowLimit /\ PrefixBytes(rows, count) <= byteLimit}

Maximum(values) ==
    CHOOSE value \in values : \A other \in values : value >= other

PagePrefix(rows, rowLimit, byteLimit) ==
    SubSeq(rows, 1, Maximum(PrefixCounts(rows, rowLimit, byteLimit)))

RemainingRowsFor(newest, emptyView, prior) ==
    SubSeq(ScanRows(newest, emptyView), Len(prior) + 1,
        Len(ScanRows(newest, emptyView)))

CandidatePageFor(newest, emptyView, prior, rowLimit, byteLimit) ==
    PagePrefix(RemainingRowsFor(newest, emptyView, prior), rowLimit,
        byteLimit)

(***************************************************************************
Zero through two rows and zero through five bytes exercise empty budgets,
single-row progress, row-limited pages, byte-limited pages, and final pages.
They are exhaustive finite-model inputs, not public or persisted limits.
***************************************************************************)
RowLimits == 0 .. 2
ByteLimits == 0 .. 5

Results == {"None", "Started", "Success", "CapacityExceeded"}
ActionNames == {
    "Init", "Begin", "ConcurrentAdvance", "ProducePage", "CompleteEmpty",
    "RejectCapacity", "RejectAllocation", "UnsafePage"
}

VARIABLES currentNewest, snapshotNewest, emptyView, active, emitted, page, done,
    predicateRecorded, result, badPageObserved, lastAction, lastRowLimit,
    lastByteLimit

vars == <<currentNewest, snapshotNewest, emptyView, active, emitted, page, done,
    predicateRecorded, result, badPageObserved, lastAction, lastRowLimit,
    lastByteLimit>>

InitialRow == [key |-> 1, value |-> "A"]

Init ==
    /\ currentNewest = InitialNewest
    /\ snapshotNewest = InitialNewest
    /\ emptyView = FALSE
    /\ active = FALSE
    /\ emitted = <<>>
    /\ page = <<>>
    /\ done = FALSE
    /\ predicateRecorded = FALSE
    /\ result = "None"
    /\ badPageObserved = FALSE
    /\ lastAction = "Init"
    /\ lastRowLimit = 0
    /\ lastByteLimit = 0

Begin(noRows) ==
    /\ ~active
    /\ noRows \in BOOLEAN
    /\ snapshotNewest' = currentNewest
    /\ emptyView' = noRows
    /\ active' = TRUE
    /\ emitted' = <<>>
    /\ page' = <<>>
    /\ done' = FALSE
    /\ predicateRecorded' = FALSE
    /\ result' = "Started"
    /\ badPageObserved' = FALSE
    /\ lastAction' = "Begin"
    /\ lastRowLimit' = 0
    /\ lastByteLimit' = 0
    /\ UNCHANGED currentNewest

ConcurrentAdvance ==
    /\ active
    /\ currentNewest = InitialNewest
    /\ currentNewest' =
        [currentNewest EXCEPT ![1] = "C", ![2] = "C", ![3] = "Tombstone"]
    /\ lastAction' = "ConcurrentAdvance"
    /\ UNCHANGED <<snapshotNewest, emptyView, active, emitted, page, done,
        predicateRecorded, result, badPageObserved, lastRowLimit,
        lastByteLimit>>

ProducePage(rowLimit, byteLimit) ==
    LET remaining == RemainingRowsFor(snapshotNewest, emptyView, emitted)
        selected == CandidatePageFor(
            snapshotNewest, emptyView, emitted, rowLimit, byteLimit)
    IN  /\ active /\ ~done
        /\ rowLimit \in RowLimits /\ byteLimit \in ByteLimits
        /\ Len(remaining) > 0
        /\ Len(selected) > 0
        /\ page' = selected
        /\ emitted' = emitted \o selected
        /\ done' =
            (Len(emitted \o selected) =
                Len(ScanRows(snapshotNewest, emptyView)))
        /\ predicateRecorded' = TRUE
        /\ result' = "Success"
        /\ badPageObserved' = badPageObserved
        /\ lastAction' = "ProducePage"
        /\ lastRowLimit' = rowLimit
        /\ lastByteLimit' = byteLimit
        /\ UNCHANGED <<currentNewest, snapshotNewest, emptyView, active>>

CompleteEmpty(rowLimit, byteLimit) ==
    /\ active /\ ~done
    /\ rowLimit \in RowLimits /\ byteLimit \in ByteLimits
    /\ Len(RemainingRowsFor(snapshotNewest, emptyView, emitted)) = 0
    /\ page' = <<>>
    /\ done' = TRUE
    /\ predicateRecorded' = TRUE
    /\ result' = "Success"
    /\ lastAction' = "CompleteEmpty"
    /\ lastRowLimit' = rowLimit
    /\ lastByteLimit' = byteLimit
    /\ UNCHANGED <<currentNewest, snapshotNewest, emptyView, active, emitted,
        badPageObserved>>

RejectCapacity(rowLimit, byteLimit) ==
    /\ active /\ ~done
    /\ rowLimit \in RowLimits /\ byteLimit \in ByteLimits
    /\ Len(RemainingRowsFor(snapshotNewest, emptyView, emitted)) > 0
    /\ Len(CandidatePageFor(
        snapshotNewest, emptyView, emitted, rowLimit, byteLimit)) = 0
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectCapacity"
    /\ lastRowLimit' = rowLimit
    /\ lastByteLimit' = byteLimit
    /\ UNCHANGED <<currentNewest, snapshotNewest, emptyView, active,
        emitted, page, done,
        predicateRecorded, badPageObserved>>

RejectAllocation(rowLimit, byteLimit) ==
    /\ active /\ ~done
    /\ rowLimit \in RowLimits /\ byteLimit \in ByteLimits
    /\ Len(CandidatePageFor(
        snapshotNewest, emptyView, emitted, rowLimit, byteLimit)) > 0
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectAllocation"
    /\ lastRowLimit' = rowLimit
    /\ lastByteLimit' = byteLimit
    /\ UNCHANGED <<currentNewest, snapshotNewest, emptyView, active,
        emitted, page, done,
        predicateRecorded, badPageObserved>>

Next ==
    \/ \E noRows \in BOOLEAN : Begin(noRows)
    \/ ConcurrentAdvance
    \/ \E rowLimit \in RowLimits, byteLimit \in ByteLimits :
        ProducePage(rowLimit, byteLimit)
    \/ \E rowLimit \in RowLimits, byteLimit \in ByteLimits :
        CompleteEmpty(rowLimit, byteLimit)
    \/ \E rowLimit \in RowLimits, byteLimit \in ByteLimits :
        RejectCapacity(rowLimit, byteLimit)
    \/ \E rowLimit \in RowLimits, byteLimit \in ByteLimits :
        RejectAllocation(rowLimit, byteLimit)

TypeOK ==
    /\ currentNewest \in [Keys -> NewestStates]
    /\ snapshotNewest \in [Keys -> NewestStates]
    /\ emptyView \in BOOLEAN
    /\ active \in BOOLEAN
    /\ emitted \in Seq(Rows)
    /\ page \in Seq(Rows)
    /\ done \in BOOLEAN
    /\ predicateRecorded \in BOOLEAN
    /\ result \in Results
    /\ badPageObserved \in BOOLEAN
    /\ lastAction \in ActionNames
    /\ lastRowLimit \in RowLimits
    /\ lastByteLimit \in ByteLimits

EmittedPrefix ==
    \E count \in 0 .. Len(ScanRows(snapshotNewest, emptyView)) :
        emitted = SubSeq(ScanRows(snapshotNewest, emptyView), 1, count)

CursorExact == Len(emitted) <= Len(ScanRows(snapshotNewest, emptyView))
DoneExact ==
    done <=> (emitted = ScanRows(snapshotNewest, emptyView)
        /\ predicateRecorded)
PageMaximal ==
    /\ (lastAction = "ProducePage" =>
        LET prior == SubSeq(emitted, 1, Len(emitted) - Len(page))
        IN  page = CandidatePageFor(
                snapshotNewest, emptyView, prior, lastRowLimit, lastByteLimit))
    /\ (lastAction = "CompleteEmpty" => page = <<>> /\ done)
NoBadPage == ~badPageObserved
PredicateSafe == ~predicateRecorded \/ active

Safety ==
    TypeOK /\ EmittedPrefix /\ CursorExact /\ DoneExact /\ PageMaximal
        /\ NoBadPage /\ PredicateSafe

Spec == Init /\ [][Next]_vars

=============================================================================
