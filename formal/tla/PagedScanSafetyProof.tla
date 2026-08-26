------------------------ MODULE PagedScanSafetyProof -----------------------
EXTENDS Naturals, Sequences

(***************************************************************************
This action-preservation kernel abstracts one fixed ordered row sequence and
arbitrary caller budgets. PageFor is trusted only under the explicit contract
that every nonempty page is the exact next contiguous prefix and never extends
past FrozenRows. Empty pages before completion mean the caller budget cannot
fit the next row. Successful empty completion and nonempty page publication
record the complete scan predicate; capacity and allocation failures change no
cursor, result page, emitted rows, or predicate authority.

The finite PagedScan model checks the concrete maximal-prefix arithmetic,
tombstone masking, fixed-snapshot behavior under later writes, and a skipped
key negative probe. This kernel does not prove byte ordering, row-size
arithmetic, allocation, progress, concurrency, or refinement to Ada.
***************************************************************************)

CONSTANTS RowSet, FrozenRows, Budgets, PageFor

PageAt(position, budget) == PageFor[<<position, budget>>]

ConstantsOK ==
    /\ RowSet # {}
    /\ FrozenRows \in Seq(RowSet)
    /\ Budgets # {}
    /\ PageFor \in [(0 .. Len(FrozenRows)) \X Budgets -> Seq(RowSet)]
    /\ \A position \in 0 .. Len(FrozenRows), budget \in Budgets :
        LET selected == PageAt(position, budget)
        IN  /\ Len(selected) <= Len(FrozenRows) - position
            /\ selected =
                SubSeq(FrozenRows, position + 1, position + Len(selected))
            /\ (position = Len(FrozenRows) => selected = <<>>)

ASSUME ConstantsOK

Results == {"None", "Success", "CapacityExceeded"}

VARIABLES position, emitted, page, done, predicateRecorded, result,
    badPageObserved

vars == <<position, emitted, page, done, predicateRecorded, result,
    badPageObserved>>

Init ==
    /\ position = 0
    /\ emitted = <<>>
    /\ page = <<>>
    /\ done = FALSE
    /\ predicateRecorded = FALSE
    /\ result = "None"
    /\ badPageObserved = FALSE

ProducePage(budget) ==
    /\ budget \in Budgets
    /\ position < Len(FrozenRows)
    /\ Len(PageAt(position, budget)) > 0
    /\ page' = PageAt(position, budget)
    /\ emitted' = emitted \o PageAt(position, budget)
    /\ position' = position + Len(PageAt(position, budget))
    /\ done' = (position' = Len(FrozenRows))
    /\ predicateRecorded' = TRUE
    /\ result' = "Success"
    /\ badPageObserved' = badPageObserved

CompleteEmpty(budget) ==
    /\ budget \in Budgets
    /\ position = Len(FrozenRows)
    /\ page' = <<>>
    /\ done' = TRUE
    /\ predicateRecorded' = TRUE
    /\ result' = "Success"
    /\ UNCHANGED <<position, emitted, badPageObserved>>

RejectCapacity(budget) ==
    /\ budget \in Budgets
    /\ position < Len(FrozenRows)
    /\ PageAt(position, budget) = <<>>
    /\ result' = "CapacityExceeded"
    /\ UNCHANGED <<position, emitted, page, done, predicateRecorded,
        badPageObserved>>

RejectAllocation(budget) ==
    /\ budget \in Budgets
    /\ position < Len(FrozenRows)
    /\ Len(PageAt(position, budget)) > 0
    /\ result' = "CapacityExceeded"
    /\ UNCHANGED <<position, emitted, page, done, predicateRecorded,
        badPageObserved>>

TypeOK ==
    /\ position \in 0 .. Len(FrozenRows)
    /\ emitted \in Seq(RowSet)
    /\ page \in Seq(RowSet)
    /\ done \in BOOLEAN
    /\ predicateRecorded \in BOOLEAN
    /\ result \in Results
    /\ badPageObserved \in BOOLEAN

PrefixExact == emitted = SubSeq(FrozenRows, 1, position)
DoneExact == done <=> (position = Len(FrozenRows) /\ predicateRecorded)
NoBadPage == ~badPageObserved

Safety == TypeOK /\ PrefixExact /\ DoneExact /\ NoBadPage

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1>1. Init => TypeOK
<2> QED BY DEF Init, TypeOK, Results, ConstantsOK
<1>2. Init => PrefixExact
<2> QED BY DEF Init, PrefixExact
<1>3. Init => DoneExact
<2> QED BY DEF Init, DoneExact
<1>4. Init => NoBadPage
<2> QED BY DEF Init, NoBadPage
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM ProducePagePreservesSafety ==
    \A budget \in Budgets : Safety /\ ProducePage(budget) => Safety'
<1> USE ConstantsOK
<1>1. \A budget \in Budgets :
        Safety /\ ProducePage(budget) => TypeOK'
<2> QED BY DEF ProducePage, Safety, TypeOK, Results, ConstantsOK, PageAt
<1>2. \A budget \in Budgets :
        Safety /\ ProducePage(budget) => PrefixExact'
<2> QED BY DEF ProducePage, Safety, TypeOK, PrefixExact, ConstantsOK, PageAt
<1>3. \A budget \in Budgets :
        Safety /\ ProducePage(budget) => DoneExact'
<2> QED BY DEF ProducePage, Safety, TypeOK, DoneExact, ConstantsOK, PageAt
<1>4. \A budget \in Budgets :
        Safety /\ ProducePage(budget) => NoBadPage'
<2> QED BY DEF ProducePage, Safety, NoBadPage
<1> QED BY <1>1, <1>2, <1>3, <1>4 DEF Safety

THEOREM CompleteEmptyPreservesSafety ==
    \A budget \in Budgets : Safety /\ CompleteEmpty(budget) => Safety'
<1> QED BY DEF CompleteEmpty, Safety, TypeOK, PrefixExact, DoneExact,
    NoBadPage, Results, ConstantsOK

THEOREM RejectCapacityPreservesSafety ==
    \A budget \in Budgets : Safety /\ RejectCapacity(budget) => Safety'
<1> QED BY DEF RejectCapacity, Safety, TypeOK, PrefixExact, DoneExact,
    NoBadPage, Results, ConstantsOK

THEOREM RejectAllocationPreservesSafety ==
    \A budget \in Budgets : Safety /\ RejectAllocation(budget) => Safety'
<1> QED BY DEF RejectAllocation, Safety, TypeOK, PrefixExact, DoneExact,
    NoBadPage, Results, ConstantsOK

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, PrefixExact, DoneExact, NoBadPage, vars

=============================================================================
