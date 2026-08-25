------------- MODULE LSMThreeRunCompactionEquivalenceProbe -------------
EXTENDS LSMThreeRunCompactionEquivalence

(***************************************************************************
This negative probe drops a middle selected tombstone when the last selected
run has no mutation for that key. The normal transition excludes this action;
TLC must reject the visible resurrection of retained older state.
***************************************************************************)

UnsafeBuild ==
    /\ phase = "Captured"
    /\ selectedRuns[2][K1] = Tombstone
    /\ selectedRuns[3][K1] = NoMutation
    /\ mergedRun' = [MergeSelectedThree(selectedRuns) EXCEPT ![K1] = NoMutation]
    /\ transferredSuffix' = suffixBatch
    /\ identityRetained' = TRUE
    /\ phase' = "Built"
    /\ lastAction' = "BuildThreeRunMerge"
    /\ UNCHANGED <<olderRun, selectedRuns, newerRun, suffixBatch,
        beforeView, afterView>>

NextWithProbe == Next \/ UnsafeBuild
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
