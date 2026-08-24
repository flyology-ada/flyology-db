------------------ MODULE LSMCompactionEquivalenceProbe ------------------
EXTENDS LSMCompactionEquivalence

(***************************************************************************
This negative probe omits one captured live key from the replacement run.
The normal transition relation excludes this action; TLC must reject it
because recovery could no longer reproduce every captured point read.
***************************************************************************)

UnsafeBuild ==
    /\ phase = "Captured"
    /\ sourceView[K1] # NoValue
    /\ compactedRun' = [Compact(sourceView) EXCEPT ![K1] = NoMutation]
    /\ phase' = "Built"
    /\ lastAction' = "BuildCompactedRun"
    /\ UNCHANGED <<sourceView, laterDelta, recoveredView, replayedView>>

NextWithProbe == Next \/ UnsafeBuild
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
