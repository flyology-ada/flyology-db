-------------- MODULE LSMPartialCompactionEquivalenceWitness --------------
EXTENDS LSMPartialCompactionEquivalence, FlyologyHarness

(***************************************************************************
This witness merges two selected consecutive runs between retained older and
newer runs. The merge preserves a selected tombstone, the newer retained run
overwrites it, and an exact transferred suffix batch updates the second key.
The witness also requires the suffix transaction identity to remain reserved.
***************************************************************************)

WitnessOlder == [k \in Keys |-> V1]
WitnessFirst == [k \in Keys |-> IF k = K1 THEN V2 ELSE Tombstone]
WitnessSecond == [k \in Keys |-> IF k = K1 THEN Tombstone ELSE V2]
WitnessNewer == [k \in Keys |-> IF k = K1 THEN V1 ELSE NoMutation]
WitnessSuffix == [k \in Keys |-> IF k = K2 THEN V1 ELSE NoMutation]

InitWitness ==
    /\ Init
    /\ olderRun = WitnessOlder
    /\ selectedFirst = WitnessFirst
    /\ selectedSecond = WitnessSecond
    /\ newerRun = WitnessNewer
    /\ suffixBatch = WitnessSuffix

NextWitness == BuildPartialMerge \/ RecoverMergedRuns
SpecWitness == InitWitness /\ [][NextWitness]_vars

WitnessComplete ==
    /\ phase = "Recovered"
    /\ lastAction = "RecoverMergedRuns"
    /\ mergedRun = [k \in Keys |-> IF k = K1 THEN Tombstone ELSE V2]
    /\ transferredSuffix = WitnessSuffix
    /\ identityRetained
    /\ beforeView = [k \in Keys |-> V1]
    /\ afterView = beforeView

WitnessPending == ~WitnessComplete

WitnessState ==
    [action |-> lastAction,
     phase |-> phase,
     older |-> olderRun,
     first |-> selectedFirst,
     second |-> selectedSecond,
     merged |-> mergedRun,
     newer |-> newerRun,
     suffix |-> suffixBatch,
     transferredSuffix |-> transferredSuffix,
     identityRetained |-> identityRetained,
     before |-> beforeView,
     after |-> afterView]

WitnessAlias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
