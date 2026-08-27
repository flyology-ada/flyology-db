------------------------ MODULE StorageBackedPagedScan ------------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC, FlyologyHarness

(***************************************************************************
This finite model composes one-head-per-run authenticated reads with bounded
page publication. Three ordered immutable runs expose older tombstones,
newer values, newest-source precedence, a final masking tombstone, retained
heads across page calls, read/allocation rejection, and exact completion.

The three runs, four keys, three live values, and page budgets zero through
two are qualification geometry. They are not run, page, key, value, request,
retry, cache, prefetch, or allocation limits. The model assumes each fetched
head is the exact authenticated next entry for its run. It does not prove SST
parsing, provider behavior, byte accounting, progress, Ada, or refinement.
***************************************************************************)

Runs == 1 .. 3
Keys == 1 .. 4
Values == {"A", "B", "C", "Tombstone", "None"}
Entries == [key : 0 .. 4, value : Values]

Entry(key, value) == [key |-> key, value |-> value]
NoHead == Entry(0, "None")

RunEntries ==
    [run \in Runs |->
        CASE run = 1 ->
            <<Entry(1, "A"), Entry(2, "Tombstone"),
              Entry(3, "A"), Entry(4, "A")>>
          [] run = 2 ->
            <<Entry(2, "B"), Entry(3, "Tombstone"),
              Entry(4, "Tombstone")>>
          [] OTHER -> <<Entry(1, "C"), Entry(3, "B")>>]

ExpectedRows == <<Entry(1, "C"), Entry(2, "B"), Entry(3, "B")>>
InitialPositions == [run \in Runs |-> 1]
EmptyHeads == [run \in Runs |-> NoHead]
PageBudgets == 0 .. 2

HeadAt(positions, run) ==
    IF positions[run] <= Len(RunEntries[run])
    THEN RunEntries[run][positions[run]]
    ELSE NoHead

AllExhausted(positions) ==
    \A run \in Runs : positions[run] > Len(RunEntries[run])

Ready(positions, heads) ==
    \A run \in Runs :
        positions[run] > Len(RunEntries[run]) \/ heads[run] # NoHead

LowestRun(heads) ==
    CHOOSE run \in {candidate \in Runs : heads[candidate] # NoHead} :
        \A other \in Runs :
            heads[other] = NoHead \/ heads[run].key <= heads[other].key

WinnerFor(heads, lowest) ==
    CHOOSE run \in {candidate \in Runs :
        heads[candidate] # NoHead /\
        heads[candidate].key = heads[lowest].key} :
        \A other \in Runs :
            heads[other] = NoHead \/
            heads[other].key # heads[lowest].key \/ run >= other

AdvanceMatching(positions, heads, lowest) ==
    [run \in Runs |->
        IF heads[run] # NoHead /\ heads[run].key = heads[lowest].key
        THEN positions[run] + 1
        ELSE positions[run]]

ClearMatching(heads, lowest) ==
    [run \in Runs |->
        IF heads[run] # NoHead /\ heads[run].key = heads[lowest].key
        THEN NoHead
        ELSE heads[run]]

PositionsAfter(count, complete) ==
    CASE complete -> [run \in Runs |-> Len(RunEntries[run]) + 1]
      [] count = 0 -> InitialPositions
      [] count = 1 -> [run \in Runs |-> CASE run = 1 -> 2 [] run = 2 -> 1 [] OTHER -> 2]
      [] count = 2 -> [run \in Runs |-> CASE run = 1 -> 3 [] run = 2 -> 2 [] OTHER -> 2]
      [] OTHER -> [run \in Runs |-> CASE run = 1 -> 4 [] run = 2 -> 3 [] OTHER -> 3]

Results == {"None", "Started", "HeadFetched", "EntrySelected", "Success",
    "ReadFailed", "CapacityExceeded"}
Phases == {"Idle", "Active", "Done"}
ActionNames == {
    "Init", "BeginPage", "FetchHead", "SelectValue", "SelectTombstone",
    "PublishPage", "CompleteEmpty", "RejectCapacity", "RejectRead",
    "RejectAllocation", "UnsafeSkipVisible"
}

VARIABLES positions, heads, candidatePositions, candidateHeads,
    priorPositions, priorHeads, emitted, rows, candidateRows, priorRows,
    priorEmitted, phase, done, predicateRecorded, result, budget, lastAction

vars == <<positions, heads, candidatePositions, candidateHeads,
    priorPositions, priorHeads, emitted, rows, candidateRows, priorRows,
    priorEmitted, phase, done, predicateRecorded, result, budget, lastAction>>

Init ==
    /\ positions = InitialPositions
    /\ heads = EmptyHeads
    /\ candidatePositions = InitialPositions
    /\ candidateHeads = EmptyHeads
    /\ priorPositions = InitialPositions
    /\ priorHeads = EmptyHeads
    /\ emitted = <<>>
    /\ rows = <<>>
    /\ candidateRows = <<>>
    /\ priorRows = <<>>
    /\ priorEmitted = <<>>
    /\ phase = "Idle"
    /\ done = FALSE
    /\ predicateRecorded = FALSE
    /\ result = "None"
    /\ budget = 0
    /\ lastAction = "Init"

BeginPage(limit) ==
    /\ phase = "Idle"
    /\ ~done
    /\ limit \in PageBudgets
    /\ candidatePositions' = positions
    /\ candidateHeads' = heads
    /\ priorPositions' = positions
    /\ priorHeads' = heads
    /\ candidateRows' = <<>>
    /\ priorRows' = rows
    /\ priorEmitted' = emitted
    /\ phase' = "Active"
    /\ result' = "Started"
    /\ budget' = limit
    /\ lastAction' = "BeginPage"
    /\ UNCHANGED <<positions, heads, emitted, rows, done, predicateRecorded>>

FetchHead(run) ==
    /\ phase = "Active"
    /\ run \in Runs
    /\ candidatePositions[run] <= Len(RunEntries[run])
    /\ candidateHeads[run] = NoHead
    /\ candidateHeads' =
        [candidateHeads EXCEPT ![run] = HeadAt(candidatePositions, run)]
    /\ result' = "HeadFetched"
    /\ lastAction' = "FetchHead"
    /\ UNCHANGED <<positions, heads, candidatePositions, priorPositions,
        priorHeads, emitted, rows, candidateRows, priorRows, priorEmitted,
        phase, done, predicateRecorded, budget>>

SelectValue ==
    /\ phase = "Active"
    /\ Ready(candidatePositions, candidateHeads)
    /\ ~AllExhausted(candidatePositions)
    /\ LET lowest == LowestRun(candidateHeads)
           winner == WinnerFor(candidateHeads, lowest)
       IN  /\ candidateHeads[winner].value # "Tombstone"
           /\ Len(candidateRows) < budget
           /\ candidateRows' = Append(candidateRows, candidateHeads[winner])
           /\ candidatePositions' =
               AdvanceMatching(candidatePositions, candidateHeads, lowest)
           /\ candidateHeads' = ClearMatching(candidateHeads, lowest)
    /\ result' = "EntrySelected"
    /\ lastAction' = "SelectValue"
    /\ UNCHANGED <<positions, heads, priorPositions, priorHeads, emitted,
        rows, priorRows, priorEmitted, phase, done, predicateRecorded, budget>>

SelectTombstone ==
    /\ phase = "Active"
    /\ Ready(candidatePositions, candidateHeads)
    /\ ~AllExhausted(candidatePositions)
    /\ LET lowest == LowestRun(candidateHeads)
           winner == WinnerFor(candidateHeads, lowest)
       IN  /\ candidateHeads[winner].value = "Tombstone"
           /\ candidatePositions' =
               AdvanceMatching(candidatePositions, candidateHeads, lowest)
           /\ candidateHeads' = ClearMatching(candidateHeads, lowest)
    /\ result' = "EntrySelected"
    /\ lastAction' = "SelectTombstone"
    /\ UNCHANGED <<positions, heads, priorPositions, priorHeads, emitted,
        rows, candidateRows, priorRows, priorEmitted, phase, done,
        predicateRecorded, budget>>

PublishPage ==
    /\ phase = "Active"
    /\ Len(candidateRows) > 0
    /\ (Len(candidateRows) = budget \/ AllExhausted(candidatePositions))
    /\ positions' = candidatePositions
    /\ heads' = candidateHeads
    /\ emitted' = emitted \o candidateRows
    /\ rows' = candidateRows
    /\ done' = AllExhausted(candidatePositions)
    /\ predicateRecorded' = TRUE
    /\ phase' = IF done' THEN "Done" ELSE "Idle"
    /\ result' = "Success"
    /\ lastAction' = "PublishPage"
    /\ UNCHANGED <<candidatePositions, candidateHeads, priorPositions,
        priorHeads, candidateRows, priorRows, priorEmitted, budget>>

CompleteEmpty ==
    /\ phase = "Active"
    /\ candidateRows = <<>>
    /\ AllExhausted(candidatePositions)
    /\ positions' = candidatePositions
    /\ heads' = candidateHeads
    /\ rows' = <<>>
    /\ done' = TRUE
    /\ predicateRecorded' = TRUE
    /\ phase' = "Done"
    /\ result' = "Success"
    /\ lastAction' = "CompleteEmpty"
    /\ UNCHANGED <<candidatePositions, candidateHeads, priorPositions,
        priorHeads, emitted, candidateRows, priorRows, priorEmitted, budget>>

RejectCapacity ==
    /\ phase = "Active"
    /\ candidateRows = <<>>
    /\ budget = 0
    /\ Ready(candidatePositions, candidateHeads)
    /\ ~AllExhausted(candidatePositions)
    /\ candidateHeads[WinnerFor(candidateHeads, LowestRun(candidateHeads))].value #
        "Tombstone"
    /\ phase' = "Idle"
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectCapacity"
    /\ UNCHANGED <<positions, heads, candidatePositions, candidateHeads,
        priorPositions, priorHeads, emitted, rows, candidateRows, priorRows,
        priorEmitted, done, predicateRecorded, budget>>

RejectRead ==
    /\ phase = "Active"
    /\ phase' = "Idle"
    /\ result' = "ReadFailed"
    /\ lastAction' = "RejectRead"
    /\ UNCHANGED <<positions, heads, candidatePositions, candidateHeads,
        priorPositions, priorHeads, emitted, rows, candidateRows, priorRows,
        priorEmitted, done, predicateRecorded, budget>>

RejectAllocation ==
    /\ phase = "Active"
    /\ phase' = "Idle"
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectAllocation"
    /\ UNCHANGED <<positions, heads, candidatePositions, candidateHeads,
        priorPositions, priorHeads, emitted, rows, candidateRows, priorRows,
        priorEmitted, done, predicateRecorded, budget>>

UnsafeSkipVisible ==
    /\ phase = "Active"
    /\ Len(emitted) + 1 < Len(ExpectedRows)
    /\ emitted' = Append(emitted, ExpectedRows[Len(emitted) + 2])
    /\ rows' = <<ExpectedRows[Len(emitted) + 2]>>
    /\ positions' = PositionsAfter(Len(emitted) + 2, FALSE)
    /\ phase' = "Idle"
    /\ result' = "Success"
    /\ lastAction' = "UnsafeSkipVisible"
    /\ UNCHANGED <<heads, candidatePositions, candidateHeads,
        priorPositions, priorHeads, candidateRows, priorRows, priorEmitted,
        done, predicateRecorded, budget>>

Next ==
    \/ \E limit \in PageBudgets : BeginPage(limit)
    \/ \E run \in Runs : FetchHead(run)
    \/ SelectValue
    \/ SelectTombstone
    \/ PublishPage
    \/ CompleteEmpty
    \/ RejectCapacity
    \/ RejectRead
    \/ RejectAllocation

PrefixOf(prefix, complete) ==
    /\ Len(prefix) <= Len(complete)
    /\ prefix = SubSeq(complete, 1, Len(prefix))

HeadExact(positionsValue, headsValue) ==
    \A run \in Runs :
        headsValue[run] = NoHead \/
        headsValue[run] = HeadAt(positionsValue, run)

TypeOK ==
    /\ positions \in [Runs -> 1 .. 5]
    /\ heads \in [Runs -> Entries]
    /\ candidatePositions \in [Runs -> 1 .. 5]
    /\ candidateHeads \in [Runs -> Entries]
    /\ priorPositions \in [Runs -> 1 .. 5]
    /\ priorHeads \in [Runs -> Entries]
    /\ emitted \in Seq(Entries)
    /\ rows \in Seq(Entries)
    /\ candidateRows \in Seq(Entries)
    /\ priorRows \in Seq(Entries)
    /\ priorEmitted \in Seq(Entries)
    /\ phase \in Phases
    /\ done \in BOOLEAN
    /\ predicateRecorded \in BOOLEAN
    /\ result \in Results
    /\ budget \in PageBudgets
    /\ lastAction \in ActionNames

PublishedPrefix == PrefixOf(emitted, ExpectedRows)
CursorExact == positions = PositionsAfter(Len(emitted), done)
HeadsExact ==
    /\ HeadExact(positions, heads)
    /\ (phase = "Active" => HeadExact(candidatePositions, candidateHeads))
FailureAtomic ==
    result \in {"ReadFailed", "CapacityExceeded"} =>
        /\ positions = priorPositions
        /\ heads = priorHeads
        /\ rows = priorRows
        /\ emitted = priorEmitted
DoneExact ==
    done <=>
        (AllExhausted(positions) /\ emitted = ExpectedRows /\ predicateRecorded)
HeadBound == Cardinality({run \in Runs : heads[run] # NoHead}) <= Cardinality(Runs)

Safety ==
    TypeOK /\ PublishedPrefix /\ CursorExact /\ HeadsExact /\ FailureAtomic
        /\ DoneExact /\ HeadBound

HarnessState ==
    [action |-> lastAction,
     positions |-> positions,
     heads |-> heads,
     emitted |-> emitted,
     rows |-> rows,
     phase |-> phase,
     done |-> done,
     predicate |-> predicateRecorded,
     result |-> result,
     budget |-> budget]

HarnessAlias == CheckedWitnessAlias(lastAction, HarnessState)

Spec == Init /\ [][Next]_vars

=============================================================================
