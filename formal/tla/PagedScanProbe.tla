-------------------------- MODULE PagedScanProbe ---------------------------
EXTENDS PagedScan

(***************************************************************************
This negative probe publishes key three as the first page even though key one
is the first visible row in the frozen snapshot. The normal Next relation
excludes this skipped-key action; TLC must reject it through Safety.
***************************************************************************)

WrongPage == <<[key |-> 3, value |-> "B"]>>

UnsafePage ==
    /\ active
    /\ ~done
    /\ ~emptyView
    /\ emitted = <<>>
    /\ page' = WrongPage
    /\ emitted' = WrongPage
    /\ done' = FALSE
    /\ predicateRecorded' = TRUE
    /\ result' = "Success"
    /\ badPageObserved' = TRUE
    /\ lastAction' = "UnsafePage"
    /\ lastRowLimit' = 1
    /\ lastByteLimit' = 5
    /\ UNCHANGED <<currentNewest, snapshotNewest, emptyView, active>>

NextWithProbe == Next \/ UnsafePage
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
