-------------- MODULE LSMPartialCompactionEquivalenceWitness --------------
EXTENDS LSMPartialCompactionEquivalence

(***************************************************************************
This witness merges two selected consecutive runs between retained older and
newer runs. The merge preserves a selected tombstone and the newer retained
run then overwrites it, demonstrating exact recovery order on both keys.
***************************************************************************)

WitnessOlder == [k \in Keys |-> V1]
WitnessFirst == [k \in Keys |-> IF k = K1 THEN V2 ELSE Tombstone]
WitnessSecond == [k \in Keys |-> IF k = K1 THEN Tombstone ELSE V2]
WitnessNewer == [k \in Keys |-> IF k = K1 THEN V1 ELSE NoMutation]

InitWitness ==
    /\ Init
    /\ olderRun = WitnessOlder
    /\ selectedFirst = WitnessFirst
    /\ selectedSecond = WitnessSecond
    /\ newerRun = WitnessNewer

NextWitness == BuildPartialMerge \/ RecoverMergedRuns
SpecWitness == InitWitness /\ [][NextWitness]_vars

WitnessComplete ==
    /\ phase = "Recovered"
    /\ lastAction = "RecoverMergedRuns"
    /\ mergedRun = [k \in Keys |-> IF k = K1 THEN Tombstone ELSE V2]
    /\ beforeView = [k \in Keys |-> IF k = K1 THEN V1 ELSE V2]
    /\ afterView = beforeView

WitnessPending == ~WitnessComplete

WitnessAlias ==
    [action |-> lastAction,
     phase |-> phase,
     older |-> olderRun,
     first |-> selectedFirst,
     second |-> selectedSecond,
     merged |-> mergedRun,
     newer |-> newerRun,
     before |-> beforeView,
     after |-> afterView]

=============================================================================
