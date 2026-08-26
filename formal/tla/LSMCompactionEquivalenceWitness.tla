----------------- MODULE LSMCompactionEquivalenceWitness -----------------
EXTENDS LSMCompactionEquivalence, FlyologyHarness

(***************************************************************************
This witness captures one live and one absent key, builds and recovers the
complete replacement, then applies a later delta that deletes the former and
puts the latter. Its TLC trace is machine-validated as an execution witness.
***************************************************************************)

WitnessSource == [k \in Keys |-> IF k = K1 THEN V1 ELSE NoValue]
WitnessDelta == [k \in Keys |-> IF k = K1 THEN Tombstone ELSE V2]

InitWitness ==
    /\ Init
    /\ sourceView = WitnessSource
    /\ laterDelta = WitnessDelta

NextWitness == BuildCompactedRun \/ RecoverCompactedRun \/ ReplayLaterDelta
SpecWitness == InitWitness /\ [][NextWitness]_vars

WitnessComplete ==
    /\ phase = "Replayed"
    /\ lastAction = "ReplayLaterDelta"
    /\ compactedRun = [k \in Keys |-> IF k = K1 THEN V1 ELSE NoMutation]
    /\ recoveredView = WitnessSource
    /\ replayedView = [k \in Keys |-> IF k = K1 THEN NoValue ELSE V2]

WitnessPending == ~WitnessComplete

WitnessState ==
    [action |-> lastAction,
     phase |-> phase,
     source |-> sourceView,
     compacted |-> compactedRun,
     recovered |-> recoveredView,
     delta |-> laterDelta,
     replayed |-> replayedView]

WitnessAlias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
