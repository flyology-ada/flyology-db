---------------- MODULE RangeNormalizationSafetyProof ----------------
EXTENDS Naturals

(***************************************************************************
This unbounded action-preservation kernel treats endpoint normalization as a
pure operator over arbitrary range and qualified-key universes. Its contract
requires every normalized result to preserve the exact union of predicate
coverage. The state machine publishes that result only after its cardinality
guard succeeds; capacity and allocation failures change no retained authority.

The finite RangeNormalization model checks the concrete half-open endpoint
algorithm, including transitive bridges, touching endpoints, and family
separation. This kernel does not prove that algorithm, byte ordering,
allocation behavior, concurrency, progress, or refinement to Ada.
***************************************************************************)

CONSTANTS Ranges, QualifiedKeys, RangeMap, NormalizedSets, Normalizer,
          RangeCount, MaxRanges

Coverage(current) == UNION {RangeMap[range] : range \in current}
Normalize(current, candidate) == Normalizer[<<current, candidate>>]

ConstantsOK ==
    /\ Ranges # {} /\ QualifiedKeys # {}
    /\ RangeMap \in [Ranges -> SUBSET QualifiedKeys]
    /\ NormalizedSets \subseteq SUBSET Ranges
    /\ {} \in NormalizedSets
    /\ Coverage({}) = {}
    /\ \A current \in NormalizedSets :
        Coverage(current) \subseteq QualifiedKeys
    /\ Normalizer \in [(SUBSET Ranges) \X Ranges -> SUBSET Ranges]
    /\ RangeCount \in [SUBSET Ranges -> Nat]
    /\ RangeCount[{}] = 0
    /\ MaxRanges \in Nat \ {0}
    /\ \A current \in NormalizedSets, candidate \in Ranges :
        /\ Normalize(current, candidate) \in NormalizedSets
        /\ Coverage(Normalize(current, candidate)) =
            Coverage(current) \cup RangeMap[candidate]

ASSUME ConstantsOK

Results == {"None", "Success", "CapacityExceeded"}

VARIABLES storedRanges, observedCoverage, result

vars == <<storedRanges, observedCoverage, result>>

Init ==
    /\ storedRanges = {}
    /\ observedCoverage = {}
    /\ result = "None"

RecordRange(candidate) ==
    /\ candidate \in Ranges
    /\ RangeCount[Normalize(storedRanges, candidate)] <= MaxRanges
    /\ storedRanges' = Normalize(storedRanges, candidate)
    /\ observedCoverage' = observedCoverage \cup RangeMap[candidate]
    /\ result' = "Success"

RejectCapacity(candidate) ==
    /\ candidate \in Ranges
    /\ RangeCount[Normalize(storedRanges, candidate)] > MaxRanges
    /\ result' = "CapacityExceeded"
    /\ UNCHANGED <<storedRanges, observedCoverage>>

RejectAllocation(candidate) ==
    /\ candidate \in Ranges
    /\ RangeCount[Normalize(storedRanges, candidate)] <= MaxRanges
    /\ result' = "CapacityExceeded"
    /\ UNCHANGED <<storedRanges, observedCoverage>>

TypeOK ==
    /\ storedRanges \in NormalizedSets
    /\ observedCoverage \subseteq QualifiedKeys
    /\ result \in Results

CapacityBound == RangeCount[storedRanges] <= MaxRanges
CoverageExact == Coverage(storedRanges) = observedCoverage

Safety == TypeOK /\ CapacityBound /\ CoverageExact

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1>1. Init => TypeOK
<2> QED BY DEF Init, TypeOK, Results, ConstantsOK
<1>2. Init => CapacityBound
<2> QED BY DEF Init, CapacityBound, ConstantsOK
<1>3. Init => CoverageExact
<2> QED BY DEF Init, CoverageExact, ConstantsOK
<1> QED BY <1>1, <1>2, <1>3 DEF Safety

THEOREM RecordRangePreservesSafety ==
    \A candidate \in Ranges :
        Safety /\ RecordRange(candidate) => Safety'
<1> USE ConstantsOK
<1>1. \A candidate \in Ranges :
        Safety /\ RecordRange(candidate) => TypeOK'
<2> QED BY DEF RecordRange, Safety, TypeOK, Normalize, Results, ConstantsOK
<1>2. \A candidate \in Ranges :
        Safety /\ RecordRange(candidate) => CapacityBound'
<2> QED BY DEF RecordRange, Safety, CapacityBound
<1>3. \A candidate \in Ranges :
        Safety /\ RecordRange(candidate) => CoverageExact'
<2> QED BY DEF RecordRange, Safety, TypeOK, CoverageExact, Normalize,
    ConstantsOK
<1> QED BY <1>1, <1>2, <1>3 DEF Safety

THEOREM RejectCapacityPreservesSafety ==
    \A candidate \in Ranges :
        Safety /\ RejectCapacity(candidate) => Safety'
<1> QED BY DEF RejectCapacity, Safety, TypeOK, CapacityBound, CoverageExact,
    Results, ConstantsOK

THEOREM RejectAllocationPreservesSafety ==
    \A candidate \in Ranges :
        Safety /\ RejectAllocation(candidate) => Safety'
<1> QED BY DEF RejectAllocation, Safety, TypeOK, CapacityBound, CoverageExact,
    Results, ConstantsOK

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, CapacityBound, CoverageExact, vars

=============================================================================
