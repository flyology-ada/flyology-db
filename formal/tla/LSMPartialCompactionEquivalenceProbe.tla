--------------- MODULE LSMPartialCompactionEquivalenceProbe ---------------
EXTENDS LSMPartialCompactionEquivalence

(***************************************************************************
This negative probe drops a selected tombstone from the merged run. The
normal transition relation excludes this action; TLC must reject it because
the retained older value would become visible when no newer mutation masks it.
***************************************************************************)

UnsafeBuild ==
    /\ phase = "Captured"
    /\ selectedSecond[K1] = Tombstone
    /\ newerRun[K1] = NoMutation
    /\ mergedRun' = [MergeSelected(selectedFirst, selectedSecond)
        EXCEPT ![K1] = NoMutation]
    /\ phase' = "Built"
    /\ lastAction' = "BuildPartialMerge"
    /\ UNCHANGED <<olderRun, selectedFirst, selectedSecond, newerRun,
        beforeView, afterView>>

NextWithProbe == Next \/ UnsafeBuild
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
