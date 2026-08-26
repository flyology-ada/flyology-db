--------------------- MODULE RangeNormalizationWitness ---------------------
EXTENDS RangeNormalization, FlyologyHarness

(***************************************************************************
This witness records two separated family-one ranges, bridges them into one,
retains an equal-byte range independently for family two, rejects a disjoint
third component at capacity, extends family one while full, and then exercises
allocation rollback on a mergeable family-two predicate.
***************************************************************************)

Left == [family |-> F1, lower |-> 1, upper |-> 2]
Right == [family |-> F1, lower |-> 3, upper |-> 4]
Bridge == [family |-> F1, lower |-> 2, upper |-> 3]
Merged == [family |-> F1, lower |-> 1, upper |-> 4]
Other == [family |-> F2, lower |-> 1, upper |-> 2]
OtherDisjoint == [family |-> F2, lower |-> 3, upper |-> 4]
Extend == [family |-> F1, lower |-> 0, upper |-> 1]
Extended == [family |-> F1, lower |-> 0, upper |-> 4]
AllocationCandidate == [family |-> F2, lower |-> 1, upper |-> 3]

NextWitness ==
    \/ lastAction = "Init" /\ RecordRange(Left)
    \/ lastAction = "RecordRange" /\ lastCandidate = Left
       /\ RecordRange(Right)
    \/ lastAction = "RecordRange" /\ lastCandidate = Right
       /\ RecordRange(Bridge)
    \/ lastAction = "RecordRange" /\ lastCandidate = Bridge
       /\ RecordRange(Other)
    \/ lastAction = "RecordRange" /\ lastCandidate = Other
       /\ RejectCapacity(OtherDisjoint)
    \/ lastAction = "RejectCapacity" /\ lastCandidate = OtherDisjoint
       /\ RecordRange(Extend)
    \/ lastAction = "RecordRange" /\ lastCandidate = Extend
       /\ RejectAllocation(AllocationCandidate)

SpecWitness == Init /\ [][NextWitness]_vars

WitnessComplete ==
    /\ lastAction = "RejectAllocation"
    /\ lastCandidate = AllocationCandidate
    /\ result = "CapacityExceeded"
    /\ storedRanges = {Extended, Other}
    /\ observedCoverage = Coverage({Extended, Other})

WitnessPending == ~WitnessComplete

WitnessState ==
    [action |-> lastAction,
     result |-> result,
     candidate |-> lastCandidate,
     ranges |-> storedRanges,
     coverage |-> observedCoverage]

WitnessAlias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
