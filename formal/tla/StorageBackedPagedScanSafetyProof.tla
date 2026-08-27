------------------ MODULE StorageBackedPagedScanSafetyProof ------------------
EXTENDS FiniteSets, Naturals, Sequences

(***************************************************************************
This action-preservation kernel abstracts a storage-backed page cursor over an
arbitrary frozen row sequence. CursorFor and HeadsFor bind each published
prefix position to exact continuation state and at most RunCount retained run
heads. PageFor is trusted only under the explicit contiguous-prefix contract.
Failure preserves the authoritative cursor, heads, emitted rows, prior page,
and predicate authority.

The finite StorageBackedPagedScan model checks concrete per-run fetching,
newest-source selection, tombstone suppression, retained heads between pages,
and a skipped-visible-row negative probe. This kernel does not prove byte
ordering, authentication, provider behavior, allocation, progress, Ada, or
refinement.
***************************************************************************)

CONSTANTS RowSet, FrozenRows, Budgets, PageFor, CursorSet, CursorFor,
    HeadSet, HeadsFor, RunCount

PageAt(position, budget) == PageFor[<<position, budget>>]
CursorAt(position) == CursorFor[position]
HeadsAt(position) == HeadsFor[position]

ConstantsOK ==
    /\ RowSet # {}
    /\ FrozenRows \in Seq(RowSet)
    /\ Budgets # {}
    /\ CursorSet # {}
    /\ HeadSet # {}
    /\ RunCount \in Nat \ {0}
    /\ PageFor \in [(0 .. Len(FrozenRows)) \X Budgets -> Seq(RowSet)]
    /\ CursorFor \in [0 .. Len(FrozenRows) -> CursorSet]
    /\ HeadsFor \in [0 .. Len(FrozenRows) -> SUBSET HeadSet]
    /\ \A position \in 0 .. Len(FrozenRows) :
        Cardinality(HeadsAt(position)) <= RunCount
    /\ \A position \in 0 .. Len(FrozenRows), budget \in Budgets :
        LET selected == PageAt(position, budget)
        IN  /\ Len(selected) <= Len(FrozenRows) - position
            /\ selected =
                SubSeq(FrozenRows, position + 1, position + Len(selected))
            /\ (position = Len(FrozenRows) => selected = <<>>)

ASSUME ConstantsOK

Results == {"None", "Success", "ReadFailed", "CapacityExceeded"}

VARIABLES position, cursor, retainedHeads, emitted, page, done,
    predicateRecorded, result

vars == <<position, cursor, retainedHeads, emitted, page, done,
    predicateRecorded, result>>

Init ==
    /\ position = 0
    /\ cursor = CursorAt(0)
    /\ retainedHeads = HeadsAt(0)
    /\ emitted = <<>>
    /\ page = <<>>
    /\ done = FALSE
    /\ predicateRecorded = FALSE
    /\ result = "None"

ProducePage(budget) ==
    /\ budget \in Budgets
    /\ position < Len(FrozenRows)
    /\ Len(PageAt(position, budget)) > 0
    /\ position' = position + Len(PageAt(position, budget))
    /\ cursor' = CursorAt(position')
    /\ retainedHeads' = HeadsAt(position')
    /\ emitted' = emitted \o PageAt(position, budget)
    /\ page' = PageAt(position, budget)
    /\ done' = (position' = Len(FrozenRows))
    /\ predicateRecorded' = TRUE
    /\ result' = "Success"

CompleteEmpty(budget) ==
    /\ budget \in Budgets
    /\ position = Len(FrozenRows)
    /\ page' = <<>>
    /\ done' = TRUE
    /\ predicateRecorded' = TRUE
    /\ result' = "Success"
    /\ UNCHANGED <<position, cursor, retainedHeads, emitted>>

RejectRead ==
    /\ result' = "ReadFailed"
    /\ UNCHANGED <<position, cursor, retainedHeads, emitted, page, done,
        predicateRecorded>>

RejectCapacity ==
    /\ result' = "CapacityExceeded"
    /\ UNCHANGED <<position, cursor, retainedHeads, emitted, page, done,
        predicateRecorded>>

TypeOK ==
    /\ position \in 0 .. Len(FrozenRows)
    /\ cursor \in CursorSet
    /\ retainedHeads \in SUBSET HeadSet
    /\ emitted \in Seq(RowSet)
    /\ page \in Seq(RowSet)
    /\ done \in BOOLEAN
    /\ predicateRecorded \in BOOLEAN
    /\ result \in Results

PrefixExact == emitted = SubSeq(FrozenRows, 1, position)
CursorExact == cursor = CursorAt(position)
HeadsBounded ==
    /\ retainedHeads = HeadsAt(position)
    /\ Cardinality(retainedHeads) <= RunCount
DoneExact == done <=> (position = Len(FrozenRows) /\ predicateRecorded)

Safety == TypeOK /\ PrefixExact /\ CursorExact /\ HeadsBounded /\ DoneExact

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1> QED BY DEF Init, Safety, TypeOK, PrefixExact, CursorExact,
    HeadsBounded, DoneExact, Results, ConstantsOK, CursorAt, HeadsAt

THEOREM ProducePagePreservesSafety ==
    \A budget \in Budgets : Safety /\ ProducePage(budget) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, ProducePage, TypeOK, PrefixExact, CursorExact,
    HeadsBounded, DoneExact, Results, ConstantsOK, PageAt, CursorAt, HeadsAt

THEOREM CompleteEmptyPreservesSafety ==
    \A budget \in Budgets : Safety /\ CompleteEmpty(budget) => Safety'
<1> QED BY DEF CompleteEmpty, Safety, TypeOK, PrefixExact, CursorExact,
    HeadsBounded, DoneExact, Results, ConstantsOK, CursorAt, HeadsAt

THEOREM RejectReadPreservesSafety == Safety /\ RejectRead => Safety'
<1> QED BY DEF RejectRead, Safety, TypeOK, PrefixExact, CursorExact,
    HeadsBounded, DoneExact, Results

THEOREM RejectCapacityPreservesSafety ==
    Safety /\ RejectCapacity => Safety'
<1> QED BY DEF RejectCapacity, Safety, TypeOK, PrefixExact, CursorExact,
    HeadsBounded, DoneExact, Results

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, PrefixExact, CursorExact, HeadsBounded,
    DoneExact, vars

=============================================================================
