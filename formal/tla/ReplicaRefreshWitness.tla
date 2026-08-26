------------------------- MODULE ReplicaRefreshWitness -------------------------
EXTENDS ReplicaRefresh, FlyologyHarness

(***************************************************************************
This exact witness fences a writer after it captures epoch zero, cancels it,
publishes through a new exact-epoch writer, lets a replica load ordinal one
while authority advances to ordinal two, installs that still-valid lagging
snapshot monotonically, then catches up to the exact current pair.
***************************************************************************)

VARIABLE step
witnessVars == <<vars, step>>

InitWitness == Init /\ step = 0

S1  == step = 0  /\ ConfirmSuccessor /\ step' = 1
S2  == step = 1  /\ BeginWriter      /\ step' = 2
S3  == step = 2  /\ FenceEpoch      /\ step' = 3
S4  == step = 3  /\ CancelWriter    /\ step' = 4
S5  == step = 4  /\ BeginWriter      /\ step' = 5
S6  == step = 5  /\ Publish          /\ step' = 6
S7  == step = 6  /\ BeginRefresh     /\ step' = 7
S8  == step = 7  /\ ConfirmSuccessor /\ step' = 8
S9  == step = 8  /\ BeginWriter      /\ step' = 9
S10 == step = 9  /\ Publish          /\ step' = 10
S11 == step = 10 /\ CompleteLoad     /\ step' = 11
S12 == step = 11 /\ InstallRefresh   /\ step' = 12
S13 == step = 12 /\ BeginRefresh     /\ step' = 13
S14 == step = 13 /\ CompleteLoad     /\ step' = 14
S15 == step = 14 /\ InstallRefresh   /\ step' = 15

NextWitness ==
    \/ S1 \/ S2 \/ S3 \/ S4 \/ S5 \/ S6 \/ S7 \/ S8
    \/ S9 \/ S10 \/ S11 \/ S12 \/ S13 \/ S14 \/ S15

SpecWitness == InitWitness /\ [][NextWitness]_witnessVars

WitnessComplete ==
    /\ step = 15 /\ lastAction = "InstallRefresh"
    /\ confirmed = 0 .. 2 /\ headOrdinal = 2 /\ headEpoch = 1
    /\ replicaOrdinal = 2 /\ replicaEpoch = 1
    /\ highOrdinal = 2 /\ highEpoch = 1
    /\ refreshPhase = "Idle" /\ writerPhase = "Idle"
    /\ ~stalePublished /\ ~rollbackInstalled

WitnessPending == ~WitnessComplete

WitnessState ==
    [action |-> lastAction, step |-> step,
     authority |-> [ordinal |-> headOrdinal, epoch |-> headEpoch,
                    confirmed |-> confirmed],
     writer |-> [phase |-> writerPhase,
                 expectedOrdinal |-> writerExpectedOrdinal,
                 capturedEpoch |-> writerCapturedEpoch],
     replica |-> [ordinal |-> replicaOrdinal, epoch |-> replicaEpoch,
                  highOrdinal |-> highOrdinal, highEpoch |-> highEpoch],
     refresh |-> [phase |-> refreshPhase, ordinal |-> capturedOrdinal,
                  epoch |-> capturedEpoch]]

WitnessAlias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
