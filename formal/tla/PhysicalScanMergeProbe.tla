--------------------- MODULE PhysicalScanMergeProbe ----------------------
EXTENDS PhysicalScanMerge

(***************************************************************************
This negative probe advances only the newest winning source for key one. The
older base and suffix heads remain on that key, so a later iteration could
duplicate or resurrect stale authority. The normal merge consumes every equal
head atomically; PositionsExact must reject this partial advance.
***************************************************************************)

UnsafeAdvance ==
    LET key == NextKeyFor(capturedSources, positions)
        winner == WinningHeadFor(capturedSources, positions, key)
        entry == WinningEntryFor(capturedSources, positions, key)
        partial == [positions EXCEPT ![winner] = @ + 1]
        row == [key |-> key, value |-> entry.value]
    IN  /\ active /\ ~done
        /\ lastKey = 0
        /\ key = 1
        /\ positions' = partial
        /\ lastKey' = key
        /\ emitted' = Append(emitted, row)
        /\ page' = <<row>>
        /\ done' = FALSE
        /\ result' = "Success"
        /\ lastAction' = "UnsafeAdvance"
        /\ UNCHANGED <<currentSources, capturedSources, active>>

NextWithProbe == Next \/ UnsafeAdvance
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
