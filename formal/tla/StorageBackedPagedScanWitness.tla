--------------------- MODULE StorageBackedPagedScanWitness --------------------
EXTENDS StorageBackedPagedScan, FlyologyHarness

FirstPage == <<Entry(1, "C"), Entry(2, "B")>>
FinalPage == <<Entry(3, "B")>>

WitnessNext ==
    \/ lastAction = "Init" /\ BeginPage(2)
    \/ lastAction = "BeginPage" /\ candidateHeads[1] = NoHead /\ FetchHead(1)
    \/ lastAction = "FetchHead" /\ candidateHeads[2] = NoHead /\ FetchHead(2)
    \/ lastAction = "FetchHead" /\ candidateHeads[3] = NoHead /\ FetchHead(3)
    \/ lastAction = "FetchHead" /\ candidateHeads[1].key = 1 /\
       candidateHeads[2].key = 2 /\ candidateHeads[3].key = 1 /\ SelectValue
    \/ lastAction = "SelectValue" /\ candidateHeads[3] = NoHead /\
       candidatePositions[3] = 2 /\ FetchHead(3)
    \/ lastAction = "FetchHead" /\ candidateHeads[1].key = 2 /\
       candidateHeads[2].key = 2 /\ Len(candidateRows) = 1 /\ SelectValue
    \/ lastAction = "SelectValue" /\ candidateRows = FirstPage /\ PublishPage
    \/ lastAction = "PublishPage" /\ emitted = FirstPage /\ BeginPage(2)
    \/ lastAction = "BeginPage" /\ candidateHeads[1] = NoHead /\ FetchHead(1)
    \/ lastAction = "FetchHead" /\ candidateHeads[2] = NoHead /\ FetchHead(2)
    \/ lastAction = "FetchHead" /\ candidateHeads[1].key = 3 /\
       candidateHeads[2].key = 3 /\ candidateHeads[3].key = 3 /\ SelectValue
    \/ lastAction = "SelectValue" /\ candidateHeads[1] = NoHead /\ FetchHead(1)
    \/ lastAction = "FetchHead" /\ candidateHeads[2] = NoHead /\ FetchHead(2)
    \/ lastAction = "FetchHead" /\ candidateHeads[1].key = 4 /\
       candidateHeads[2].key = 4 /\ SelectTombstone
    \/ lastAction = "SelectTombstone" /\ PublishPage

WitnessComplete ==
    /\ lastAction = "PublishPage"
    /\ emitted = ExpectedRows
    /\ rows = FinalPage
    /\ done
    /\ predicateRecorded
    /\ positions = PositionsAfter(3, TRUE)

WitnessPending == ~WitnessComplete

WitnessSpec == Init /\ [][WitnessNext]_vars

=============================================================================
