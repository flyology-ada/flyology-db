---------------------- MODULE PagedScanShortPageProbe ---------------------
EXTENDS PagedScan

(***************************************************************************
This negative probe returns only the first row when the supplied two-row,
five-byte budget admits the first two exact rows. Ordering and prefix safety
still hold, so the dedicated maximal-page invariant must reject it.
***************************************************************************)

ShortPage == <<[key |-> 1, value |-> "A"]>>

UnsafeShortPage ==
    /\ active
    /\ ~done
    /\ ~emptyView
    /\ emitted = <<>>
    /\ page' = ShortPage
    /\ emitted' = ShortPage
    /\ done' = FALSE
    /\ predicateRecorded' = TRUE
    /\ result' = "Success"
    /\ badPageObserved' = FALSE
    /\ lastAction' = "ProducePage"
    /\ lastRowLimit' = 2
    /\ lastByteLimit' = 5
    /\ UNCHANGED <<currentNewest, snapshotNewest, emptyView, active>>

NextWithProbe == Next \/ UnsafeShortPage
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
