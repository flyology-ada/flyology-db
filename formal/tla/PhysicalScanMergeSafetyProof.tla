------------------ MODULE PhysicalScanMergeSafetyProof -------------------
EXTENDS Naturals, Sequences

(***************************************************************************
This action-preservation kernel abstracts an arbitrary finite owned merge
position. PrefixAt maps each valid physical position to the exact logical rows
already emitted after consuming every equal-key source head and selecting the
newest winner. NextPosition is trusted only under the explicit contract that
it advances to another valid position and that finality is exact.

The finite PhysicalScanMerge model checks the concrete equal-head advancement,
newest-source precedence, tombstone suppression, fixed captured sources, and
two negative probes. This kernel proves preservation of exact logical output,
completion, and allocation-failure atomicity for arbitrary RowSet/Positions;
it does not prove the constant contract, byte ordering, source preparation,
image ownership, progress, concurrency, allocation, or refinement to Ada.
***************************************************************************)

CONSTANTS RowSet, Positions, InitialPosition, FinalPosition, NextPosition,
    PrefixAt

ConstantsOK ==
    /\ RowSet # {}
    /\ Positions # {}
    /\ InitialPosition \in Positions
    /\ FinalPosition \in Positions
    /\ NextPosition \in [Positions \ {FinalPosition} -> Positions]
    /\ PrefixAt \in [Positions -> Seq(RowSet)]
    /\ PrefixAt[InitialPosition] = <<>>
    /\ \A position \in Positions \ {FinalPosition} :
        /\ NextPosition[position] # position
        /\ Len(PrefixAt[NextPosition[position]]) >= Len(PrefixAt[position])
        /\ SubSeq(PrefixAt[NextPosition[position]], 1,
                Len(PrefixAt[position])) = PrefixAt[position]

ASSUME ConstantsOK

Results == {"None", "Success", "CapacityExceeded"}

VARIABLES position, emitted, done, result

vars == <<position, emitted, done, result>>

Init ==
    /\ position = InitialPosition
    /\ emitted = <<>>
    /\ done = (InitialPosition = FinalPosition)
    /\ result = "None"

Advance ==
    /\ position \in Positions \ {FinalPosition}
    /\ position' = NextPosition[position]
    /\ emitted' = PrefixAt[position']
    /\ done' = (position' = FinalPosition)
    /\ result' = "Success"

RejectAllocation ==
    /\ position \in Positions \ {FinalPosition}
    /\ result' = "CapacityExceeded"
    /\ UNCHANGED <<position, emitted, done>>

TypeOK ==
    /\ position \in Positions
    /\ emitted \in Seq(RowSet)
    /\ done \in BOOLEAN
    /\ result \in Results

OutputExact == emitted = PrefixAt[position]
DoneExact == done <=> (position = FinalPosition)

Safety == TypeOK /\ OutputExact /\ DoneExact

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1>1. Init => TypeOK
<2> QED BY DEF Init, TypeOK, Results, ConstantsOK
<1>2. Init => OutputExact
<2> QED BY DEF Init, OutputExact, ConstantsOK
<1>3. Init => DoneExact
<2> QED BY DEF Init, DoneExact
<1> QED BY <1>1, <1>2, <1>3 DEF Safety

THEOREM AdvancePreservesSafety == Safety /\ Advance => Safety'
<1> USE ConstantsOK
<1>1. Safety /\ Advance => TypeOK'
<2> QED BY DEF Safety, Advance, TypeOK, Results, ConstantsOK
<1>2. Safety /\ Advance => OutputExact'
<2> QED BY DEF Advance, OutputExact
<1>3. Safety /\ Advance => DoneExact'
<2> QED BY DEF Advance, DoneExact
<1> QED BY <1>1, <1>2, <1>3 DEF Safety

THEOREM RejectAllocationPreservesSafety ==
    Safety /\ RejectAllocation => Safety'
<1> QED BY DEF RejectAllocation, Safety, TypeOK, OutputExact, DoneExact,
    Results, ConstantsOK

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, OutputExact, DoneExact, vars

=============================================================================
