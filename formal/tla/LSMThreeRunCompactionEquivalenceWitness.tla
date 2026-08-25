------------ MODULE LSMThreeRunCompactionEquivalenceWitness ------------
EXTENDS LSMThreeRunCompactionEquivalence

(***************************************************************************
This witness fixes three selected consecutive runs. The first writes a value,
the middle deletes it, and the last has no mutation; the merged run therefore
retains the middle tombstone. An unchanged suffix then writes the value again,
while its transaction identity remains reserved.
***************************************************************************)

WitnessOlder == [k \in Keys |-> V1]
WitnessSelected ==
    [slot \in SelectedSlots |->
        [k \in Keys |->
            IF slot = 1 THEN V2
            ELSE IF slot = 2 THEN Tombstone
            ELSE NoMutation]]
WitnessNewer == [k \in Keys |-> NoMutation]
WitnessSuffix == [k \in Keys |-> V1]

InitWitness ==
    /\ Init
    /\ olderRun = WitnessOlder
    /\ selectedRuns = WitnessSelected
    /\ newerRun = WitnessNewer
    /\ suffixBatch = WitnessSuffix

NextWitness == BuildThreeRunMerge \/ RecoverMergedRuns
SpecWitness == InitWitness /\ [][NextWitness]_vars

WitnessComplete ==
    /\ phase = "Recovered"
    /\ lastAction = "RecoverMergedRuns"
    /\ mergedRun = [k \in Keys |-> Tombstone]
    /\ transferredSuffix = WitnessSuffix
    /\ identityRetained
    /\ beforeView = [k \in Keys |-> V1]
    /\ afterView = beforeView

WitnessPending == ~WitnessComplete

WitnessAlias ==
    [action |-> lastAction,
     phase |-> phase,
     older |-> olderRun,
     first |-> selectedRuns[1],
     middle |-> selectedRuns[2],
     last |-> selectedRuns[3],
     merged |-> mergedRun,
     newer |-> newerRun,
     suffix |-> suffixBatch,
     transferredSuffix |-> transferredSuffix,
     identityRetained |-> identityRetained,
     before |-> beforeView,
     after |-> afterView]

=============================================================================
