----------------- MODULE AuthenticatedScanInitialization -----------------
EXTENDS Naturals, Sequences, TLC, FlyologyHarness

(***************************************************************************
This finite model composes exact next-visible-entry results across one ordered
manifest run slice before publishing an authenticated physical scan cursor.
Each visible run is advanced strictly by key until authenticated absence; a
future run is skipped; read or allocation failure preserves the prior cursor;
and only complete exhaustion of every run permits candidate publication.

Three runs, three keys, and three live values are finite qualification
geometry. They are not run, key, value, page, request, retry, or allocation
limits. The model assumes the one-run selector's established exact result and
does not prove byte ordering, SST authentication, parsing, provider behavior,
progress, allocation implementation, the physical merge, Ada, or refinement.
***************************************************************************)

RunIDs == 1 .. 3
Keys == 1 .. 3
Values == {"A", "B", "C", "Tombstone"}
Entries == [key : Keys, value : Values]

Entry(key, value) == [key |-> key, value |-> value]

RunEntries ==
    [run \in RunIDs |->
        CASE run = 1 -> <<Entry(1, "A"), Entry(2, "Tombstone")>>
          [] run = 2 -> <<Entry(1, "B")>>
          [] OTHER -> <<Entry(2, "C"), Entry(3, "B")>>]

FutureRuns == {2}
ExpectedLoaded ==
    [run \in RunIDs |-> IF run \in FutureRuns THEN <<>> ELSE RunEntries[run]]
EmptyLoaded == [run \in RunIDs |-> <<>>]

CursorState(kind, runs) == [kind |-> kind, runs |-> runs]
PriorCursor == CursorState("Prior", EmptyLoaded)
PublishedCursor(runs) == CursorState("Published", runs)

NextPosition(run, last) ==
    LET positions == {position \in 1 .. Len(RunEntries[run]) :
        RunEntries[run][position].key > last}
    IN  IF positions = {}
        THEN 0
        ELSE CHOOSE position \in positions :
            \A other \in positions :
                RunEntries[run][position].key <= RunEntries[run][other].key

Results == {"None", "Started", "EntryRead", "RunComplete", "Success",
    "ReadFailed", "CapacityExceeded"}
Phases == {"Idle", "Reading", "Building", "Terminal"}
ActionNames == {
    "Init", "Begin", "ReadEntry", "ReadAbsent", "SkipFuture",
    "PublishCursor", "RejectRead", "RejectAllocation", "UnsafeSkipEntry"
}

VARIABLES currentRun, lastKeys, loaded, phase, cursor, result, lastAction

vars == <<currentRun, lastKeys, loaded, phase, cursor, result, lastAction>>

Init ==
    /\ currentRun = 0
    /\ lastKeys = [run \in RunIDs |-> 0]
    /\ loaded = EmptyLoaded
    /\ phase = "Idle"
    /\ cursor = PriorCursor
    /\ result = "None"
    /\ lastAction = "Init"

Begin ==
    /\ phase = "Idle"
    /\ currentRun' = 1
    /\ lastKeys' = [run \in RunIDs |-> 0]
    /\ loaded' = EmptyLoaded
    /\ phase' = "Reading"
    /\ cursor' = cursor
    /\ result' = "Started"
    /\ lastAction' = "Begin"

ReadEntry ==
    /\ phase = "Reading"
    /\ currentRun \in RunIDs \ FutureRuns
    /\ \E position \in 1 .. Len(RunEntries[currentRun]) :
       LET item == RunEntries[currentRun][position]
       IN  /\ position = NextPosition(currentRun, lastKeys[currentRun])
           /\ loaded' = [loaded EXCEPT ![currentRun] = Append(@, item)]
           /\ lastKeys' = [lastKeys EXCEPT ![currentRun] = item.key]
           /\ result' = "EntryRead"
           /\ lastAction' = "ReadEntry"
           /\ UNCHANGED <<currentRun, phase, cursor>>

ReadAbsent ==
    /\ phase = "Reading"
    /\ currentRun \in RunIDs \ FutureRuns
    /\ NextPosition(currentRun, lastKeys[currentRun]) = 0
    /\ loaded[currentRun] = ExpectedLoaded[currentRun]
    /\ currentRun' = IF currentRun = 3 THEN currentRun ELSE currentRun + 1
    /\ phase' = IF currentRun = 3 THEN "Building" ELSE "Reading"
    /\ result' = "RunComplete"
    /\ lastAction' = "ReadAbsent"
    /\ UNCHANGED <<lastKeys, loaded, cursor>>

SkipFuture ==
    /\ phase = "Reading"
    /\ currentRun \in FutureRuns
    /\ loaded[currentRun] = <<>>
    /\ currentRun' = IF currentRun = 3 THEN currentRun ELSE currentRun + 1
    /\ phase' = IF currentRun = 3 THEN "Building" ELSE "Reading"
    /\ result' = "RunComplete"
    /\ lastAction' = "SkipFuture"
    /\ UNCHANGED <<lastKeys, loaded, cursor>>

PublishCursor ==
    /\ phase = "Building"
    /\ loaded = ExpectedLoaded
    /\ cursor' = PublishedCursor(loaded)
    /\ phase' = "Terminal"
    /\ result' = "Success"
    /\ lastAction' = "PublishCursor"
    /\ UNCHANGED <<currentRun, lastKeys, loaded>>

RejectRead ==
    /\ phase = "Reading"
    /\ phase' = "Terminal"
    /\ result' = "ReadFailed"
    /\ lastAction' = "RejectRead"
    /\ UNCHANGED <<currentRun, lastKeys, loaded, cursor>>

RejectAllocation ==
    /\ phase \in {"Reading", "Building"}
    /\ phase' = "Terminal"
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectAllocation"
    /\ UNCHANGED <<currentRun, lastKeys, loaded, cursor>>

UnsafeSkipEntry ==
    /\ phase = "Reading"
    /\ currentRun \in RunIDs \ FutureRuns
    /\ \E first \in 1 .. Len(RunEntries[currentRun]) :
       /\ first = NextPosition(currentRun, lastKeys[currentRun])
       /\ \E second \in 1 .. Len(RunEntries[currentRun]) :
          LET item == RunEntries[currentRun][second]
          IN  /\ second = NextPosition(currentRun, RunEntries[currentRun][first].key)
           /\ loaded' = [loaded EXCEPT ![currentRun] = Append(@, item)]
           /\ lastKeys' = [lastKeys EXCEPT ![currentRun] = item.key]
           /\ result' = "EntryRead"
           /\ lastAction' = "UnsafeSkipEntry"
           /\ UNCHANGED <<currentRun, phase, cursor>>

Next ==
    \/ Begin
    \/ ReadEntry
    \/ ReadAbsent
    \/ SkipFuture
    \/ PublishCursor
    \/ RejectRead
    \/ RejectAllocation

PrefixOf(prefix, complete) ==
    /\ Len(prefix) <= Len(complete)
    /\ prefix = SubSeq(complete, 1, Len(prefix))

TypeOK ==
    /\ currentRun \in 0 .. 3
    /\ lastKeys \in [RunIDs -> 0 .. 3]
    /\ loaded \in [RunIDs -> Seq(Entries)]
    /\ phase \in Phases
    /\ cursor \in [kind : {"Prior", "Published"}, runs : [RunIDs -> Seq(Entries)]]
    /\ result \in Results
    /\ lastAction \in ActionNames

ProgressExact ==
    /\ (phase = "Idle" => currentRun = 0 /\ loaded = EmptyLoaded)
    /\ (phase \in {"Reading", "Building", "Terminal"} =>
          \A run \in RunIDs : PrefixOf(loaded[run], ExpectedLoaded[run]))
    /\ (phase = "Reading" =>
          /\ currentRun \in RunIDs
          /\ \A run \in RunIDs : run < currentRun => loaded[run] = ExpectedLoaded[run]
          /\ \A run \in RunIDs : run > currentRun => loaded[run] = <<>>)
    /\ (phase = "Building" => loaded = ExpectedLoaded)

PhaseResultBound ==
    /\ (phase = "Idle" => result = "None")
    /\ (phase = "Reading" => result \in {"Started", "EntryRead", "RunComplete"})
    /\ (phase = "Building" => result = "RunComplete")
    /\ (phase = "Terminal" => result \in {"Success", "ReadFailed", "CapacityExceeded"})

PublicationAtomic ==
    /\ (phase # "Terminal" => cursor = PriorCursor)
    /\ (result \in {"ReadFailed", "CapacityExceeded"} => cursor = PriorCursor)
    /\ (result = "Success" => cursor = PublishedCursor(ExpectedLoaded))

Safety == TypeOK /\ ProgressExact /\ PhaseResultBound /\ PublicationAtomic

HarnessState ==
    [action |-> lastAction,
     current_run |-> currentRun,
     last_keys |-> lastKeys,
     loaded |-> loaded,
     phase |-> phase,
     cursor |-> cursor,
     result |-> result]

HarnessAlias == CheckedWitnessAlias(lastAction, HarnessState)

Spec == Init /\ [][Next]_vars

=============================================================================
