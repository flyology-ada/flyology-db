----------------- MODULE PhysicalScanMergeWinnerProbe --------------------
EXTENDS PhysicalScanMerge

(***************************************************************************
This negative probe consumes every key-one head but publishes the oldest base
value instead of the transaction-local winner. Position advancement remains
exact, so EmittedExact must independently reject wrong precedence.
***************************************************************************)

UnsafeWinner ==
    LET key == NextKeyFor(capturedSources, positions)
        advanced == AdvanceAllFor(capturedSources, positions, key)
        row == [key |-> key, value |-> "A"]
    IN  /\ active /\ ~done
        /\ lastKey = 0
        /\ key = 1
        /\ positions' = advanced
        /\ lastKey' = key
        /\ emitted' = Append(emitted, row)
        /\ page' = <<row>>
        /\ done' = FALSE
        /\ result' = "Success"
        /\ lastAction' = "UnsafeWinner"
        /\ UNCHANGED <<currentSources, capturedSources, active>>

NextWithProbe == Next \/ UnsafeWinner
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
