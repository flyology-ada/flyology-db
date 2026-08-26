------------------------ MODULE LazyCheckpointRead ------------------------
EXTENDS Naturals, Sequences, TLC

(***************************************************************************
This finite model freezes newest-to-oldest selection across one exact
oldest-to-newest immutable run slice at a fixed snapshot. Future runs are
skipped without a child read, authenticated absence falls through, and the
first visible value or tombstone is conclusive. A child failure preserves the
prior output and is never retried.

Three runs, two keys, and four values are qualification geometry, not a run
ceiling, key/value limit, request budget, retry policy, or public default. The
model does not prove SST authentication, allocation, provider behavior,
progress, the Ada implementation, or refinement.
***************************************************************************)

Runs == 1 .. 3
RunCount == 3
Keys == 1 .. 2
Snapshots == 0 .. 3
Absent == "Absent"
Tombstone == "Tombstone"
Prior == "Prior"
NotFound == "NotFound"
Values == {"A1", "A2", "A3", "B1"}
Outputs == Values \union {Prior, NotFound}
Phases == {"Idle", "Selecting", "Terminal"}
Results == {"None", "Success", "NotFound", "ReadFailed"}
ActionNames == {
    "Init", "Begin", "SkipFuture", "ReadAbsent", "PublishValue",
    "PublishTombstone", "PublishAbsent", "RejectRead"
}

Cell(run, key) ==
    IF key = 1
    THEN IF run = 1 THEN "A1" ELSE IF run = 2 THEN "A2" ELSE "A3"
    ELSE IF run = 1 THEN "B1" ELSE IF run = 2 THEN Absent ELSE Tombstone

Expected(snapshot, key) ==
    IF snapshot >= 3 /\ Cell(3, key) # Absent
    THEN Cell(3, key)
    ELSE IF snapshot >= 2 /\ Cell(2, key) # Absent
         THEN Cell(2, key)
         ELSE IF snapshot >= 1 /\ Cell(1, key) # Absent
              THEN Cell(1, key)
              ELSE Absent

VARIABLES snapshot, key, cursor, phase, output, result, lastAction

vars == <<snapshot, key, cursor, phase, output, result, lastAction>>

Init ==
    /\ snapshot = 0
    /\ key = 1
    /\ cursor = 0
    /\ phase = "Idle"
    /\ output = Prior
    /\ result = "None"
    /\ lastAction = "Init"

Begin ==
    /\ phase = "Idle"
    /\ \E selectedSnapshot \in Snapshots, selectedKey \in Keys :
        /\ snapshot' = selectedSnapshot
        /\ key' = selectedKey
    /\ cursor' = RunCount
    /\ phase' = "Selecting"
    /\ output' = output
    /\ result' = "None"
    /\ lastAction' = "Begin"

SkipFuture ==
    /\ phase = "Selecting"
    /\ cursor > 0
    /\ cursor > snapshot
    /\ cursor' = cursor - 1
    /\ lastAction' = "SkipFuture"
    /\ UNCHANGED <<snapshot, key, phase, output, result>>

ReadAbsent ==
    /\ phase = "Selecting"
    /\ cursor > 0
    /\ cursor <= snapshot
    /\ Cell(cursor, key) = Absent
    /\ cursor' = cursor - 1
    /\ lastAction' = "ReadAbsent"
    /\ UNCHANGED <<snapshot, key, phase, output, result>>

PublishValue ==
    /\ phase = "Selecting"
    /\ cursor > 0
    /\ cursor <= snapshot
    /\ Cell(cursor, key) \in Values
    /\ output' = Cell(cursor, key)
    /\ result' = "Success"
    /\ phase' = "Terminal"
    /\ lastAction' = "PublishValue"
    /\ UNCHANGED <<snapshot, key, cursor>>

PublishTombstone ==
    /\ phase = "Selecting"
    /\ cursor > 0
    /\ cursor <= snapshot
    /\ Cell(cursor, key) = Tombstone
    /\ output' = NotFound
    /\ result' = "NotFound"
    /\ phase' = "Terminal"
    /\ lastAction' = "PublishTombstone"
    /\ UNCHANGED <<snapshot, key, cursor>>

PublishAbsent ==
    /\ phase = "Selecting"
    /\ cursor = 0
    /\ output' = NotFound
    /\ result' = "NotFound"
    /\ phase' = "Terminal"
    /\ lastAction' = "PublishAbsent"
    /\ UNCHANGED <<snapshot, key, cursor>>

RejectRead ==
    /\ phase = "Selecting"
    /\ cursor > 0
    /\ cursor <= snapshot
    /\ result' = "ReadFailed"
    /\ phase' = "Terminal"
    /\ lastAction' = "RejectRead"
    /\ UNCHANGED <<snapshot, key, cursor, output>>

Next ==
    \/ Begin
    \/ SkipFuture
    \/ ReadAbsent
    \/ PublishValue
    \/ PublishTombstone
    \/ PublishAbsent
    \/ RejectRead

TypeOK ==
    /\ snapshot \in Snapshots
    /\ key \in Keys
    /\ cursor \in 0 .. RunCount
    /\ phase \in Phases
    /\ output \in Outputs
    /\ result \in Results
    /\ lastAction \in ActionNames

CursorSafe ==
    phase = "Selecting" => cursor <= RunCount

PrePublicationAtomic ==
    phase # "Terminal" => output = Prior

FailureAtomic ==
    result = "ReadFailed" => output = Prior

TerminalExact ==
    phase = "Terminal" /\ result # "ReadFailed"
    => IF Expected(snapshot, key) \in Values
       THEN /\ result = "Success"
            /\ output = Expected(snapshot, key)
       ELSE /\ result = "NotFound"
            /\ output = NotFound

Safety ==
    /\ TypeOK
    /\ CursorSafe
    /\ PrePublicationAtomic
    /\ FailureAtomic
    /\ TerminalExact

Spec == Init /\ [][Next]_vars

=============================================================================
