------------------------ MODULE ObjectRetentionWitness ------------------------
EXTENDS ObjectRetention, FlyologyHarness

(***************************************************************************
This exact witness retains O0 while it is current, snapshot-pinned,
replica-pinned, and a required predecessor; retains O1 through an unresolved
publication and then as current; deletes O0 only after every pin is released;
and deletes an aged listed orphan O2 only after its unknown attempt resolves.
Discovery state is discarded and reconstructed before the orphan deletion.
***************************************************************************)

VARIABLE step
witnessVars == <<vars, step>>

InitWitness == Init /\ step = 0

S1  == step = 0  /\ ListObject(O0)        /\ step' = 1
S2  == step = 1  /\ MarkOld(O0)           /\ step' = 2
S3  == step = 2  /\ AcquireSnapshot       /\ step' = 3
S4  == step = 3  /\ PinReplica            /\ step' = 4
S5  == step = 4  /\ Store(O1)             /\ step' = 5
S6  == step = 5  /\ BeginUnknown(O1)      /\ step' = 6
S7  == step = 6  /\ ListObject(O1)        /\ step' = 7
S8  == step = 7  /\ MarkOld(O1)           /\ step' = 8
S9  == step = 8  /\ Advance({O1})         /\ step' = 9
S10 == step = 9  /\ ResolveUnknown(O1)    /\ step' = 10
S11 == step = 10 /\ ReleaseSnapshot(O0)   /\ step' = 11
S12 == step = 11 /\ ReleaseReplica(O0)    /\ step' = 12
S13 == step = 12 /\ ReleasePredecessor(O0) /\ step' = 13
S14 == step = 13 /\ DeleteEligible(O0)    /\ step' = 14
S15 == step = 14 /\ Store(O2)             /\ step' = 15
S16 == step = 15 /\ ListObject(O2)        /\ step' = 16
S17 == step = 16 /\ MarkOld(O2)           /\ step' = 17
S18 == step = 17 /\ BeginUnknown(O2)      /\ step' = 18
S19 == step = 18 /\ DiscardDiscovery      /\ step' = 19
S20 == step = 19 /\ ListObject(O2)        /\ step' = 20
S21 == step = 20 /\ MarkOld(O2)           /\ step' = 21
S22 == step = 21 /\ ResolveUnknown(O2)    /\ step' = 22
S23 == step = 22 /\ DeleteEligible(O2)    /\ step' = 23

NextWitness ==
    \/ S1 \/ S2 \/ S3 \/ S4 \/ S5 \/ S6 \/ S7 \/ S8 \/ S9 \/ S10
    \/ S11 \/ S12 \/ S13 \/ S14 \/ S15 \/ S16 \/ S17 \/ S18
    \/ S19 \/ S20 \/ S21 \/ S22 \/ S23

SpecWitness == InitWitness /\ [][NextWitness]_witnessVars

WitnessComplete ==
    /\ step = 23 /\ lastAction = "DeleteEligible"
    /\ stored = {O1} /\ current = {O1} /\ deleted = {O0, O2}
    /\ snapshotPins = {} /\ replicaPins = {} /\ predecessorPins = {}
    /\ unresolvedPins = {} /\ listed = {} /\ aged = {}

WitnessPending == ~WitnessComplete

WitnessState ==
    [action |-> lastAction, step |-> step, stored |-> stored,
     current |-> current,
     protected |-> [snapshots |-> snapshotPins, replicas |-> replicaPins,
                    predecessors |-> predecessorPins,
                    unknown |-> unresolvedPins],
     listed |-> listed, aged |-> aged, deleted |-> deleted]

WitnessAlias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
