---------------------- MODULE RangeNormalizationProbe ----------------------
EXTENDS RangeNormalization

(***************************************************************************
This negative probe handles a bridge by merging only its left component and
leaving the right touching component behind. The normal Next relation excludes
the action; TLC must reject the non-normalized result through Safety.
***************************************************************************)

Left == [family |-> F1, lower |-> 1, upper |-> 2]
Right == [family |-> F1, lower |-> 3, upper |-> 4]
Bridge == [family |-> F1, lower |-> 2, upper |-> 3]
WrongMerged == [family |-> F1, lower |-> 1, upper |-> 3]

UnsafeBridge ==
    /\ storedRanges = {Left, Right}
    /\ storedRanges' = {WrongMerged, Right}
    /\ observedCoverage' = observedCoverage \cup RangeMembers(Bridge)
    /\ result' = "Success"
    /\ lastAction' = "UnsafeBridge"
    /\ lastCandidate' = Bridge

NextWithProbe == Next \/ UnsafeBridge
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
