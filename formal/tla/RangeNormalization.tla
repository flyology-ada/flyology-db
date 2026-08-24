------------------------- MODULE RangeNormalization -------------------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
This finite model freezes transaction-owned normalization of half-open scan
predicates. Positions 0 and 4 stand for the finite lower/upper universe
boundaries; two families and four key positions expose ordering, touching,
bridging, capacity, allocation rollback, and cross-family separation. These
dimensions are qualification geometry, not database defaults or key limits.
No refinement to Ada is claimed.
***************************************************************************)

CONSTANTS F1, F2

Families == {F1, F2}
Keys == 0 .. 3

RawRanges ==
    { [family |-> family, lower |-> lower, upper |-> upper] :
        family \in Families,
        lower \in 0 .. 3,
        upper \in 1 .. 4 }

Ranges == {range \in RawRanges : range.lower < range.upper}

QualifiedKeys ==
    { [family |-> family, key |-> key] :
        family \in Families, key \in Keys }

RangeMembers(range) ==
    { [family |-> range.family, key |-> key] :
        key \in {candidate \in Keys :
            range.lower <= candidate /\ candidate < range.upper} }

Connected(left, right) ==
    /\ left.family = right.family
    /\ ~(left.upper < right.lower \/ right.upper < left.lower)

Touching(current, candidate) ==
    {range \in current : Connected(range, candidate)}

Minimum(values) == CHOOSE value \in values : \A other \in values : value <= other
Maximum(values) == CHOOSE value \in values : \A other \in values : value >= other

MergedRange(current, candidate) ==
    [family |-> candidate.family,
     lower  |-> Minimum({candidate.lower} \cup
                   {range.lower : range \in Touching(current, candidate)}),
     upper  |-> Maximum({candidate.upper} \cup
                   {range.upper : range \in Touching(current, candidate)})]

Normalize(current, candidate) ==
    (current \ Touching(current, candidate))
        \cup {MergedRange(current, candidate)}

Coverage(current) ==
    UNION {RangeMembers(range) : range \in current}

PairwiseSeparated(current) ==
    \A left, right \in current :
        left = right
        \/ left.family # right.family
        \/ left.upper < right.lower
        \/ right.upper < left.lower

(***************************************************************************
Two retained ranges are the smallest finite capacity that admits two
separated predicates and then exercises a bridging merge. It is not a public
or persisted product value.
***************************************************************************)
MaxRanges == 2

Results == {"None", "Success", "CapacityExceeded"}
ActionNames == {
    "Init", "RecordRange", "RejectCapacity", "RejectAllocation",
    "UnsafeBridge"
}

VARIABLES storedRanges, observedCoverage, result, lastAction, lastCandidate

vars == <<storedRanges, observedCoverage, result, lastAction, lastCandidate>>

InitialCandidate == [family |-> F1, lower |-> 0, upper |-> 1]

Init ==
    /\ storedRanges = {}
    /\ observedCoverage = {}
    /\ result = "None"
    /\ lastAction = "Init"
    /\ lastCandidate = InitialCandidate

RecordRange(candidate) ==
    /\ candidate \in Ranges
    /\ Cardinality(Normalize(storedRanges, candidate)) <= MaxRanges
    /\ storedRanges' = Normalize(storedRanges, candidate)
    /\ observedCoverage' = observedCoverage \cup RangeMembers(candidate)
    /\ result' = "Success"
    /\ lastAction' = "RecordRange"
    /\ lastCandidate' = candidate

RejectCapacity(candidate) ==
    /\ candidate \in Ranges
    /\ Cardinality(Normalize(storedRanges, candidate)) > MaxRanges
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectCapacity"
    /\ lastCandidate' = candidate
    /\ UNCHANGED <<storedRanges, observedCoverage>>

RejectAllocation(candidate) ==
    /\ candidate \in Ranges
    /\ Cardinality(Normalize(storedRanges, candidate)) <= MaxRanges
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectAllocation"
    /\ lastCandidate' = candidate
    /\ UNCHANGED <<storedRanges, observedCoverage>>

Next ==
    \/ \E candidate \in Ranges : RecordRange(candidate)
    \/ \E candidate \in Ranges : RejectCapacity(candidate)
    \/ \E candidate \in Ranges : RejectAllocation(candidate)

TypeOK ==
    /\ storedRanges \subseteq Ranges
    /\ observedCoverage \subseteq QualifiedKeys
    /\ result \in Results
    /\ lastAction \in ActionNames
    /\ lastCandidate \in Ranges

CapacityBound == Cardinality(storedRanges) <= MaxRanges
Normalized == PairwiseSeparated(storedRanges)
CoverageExact == Coverage(storedRanges) = observedCoverage

Safety == TypeOK /\ CapacityBound /\ Normalized /\ CoverageExact

Spec == Init /\ [][Next]_vars

=============================================================================
