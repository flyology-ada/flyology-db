------------------------ MODULE LazySSTNextEntry ------------------------
EXTENDS FlyologyHarness, Naturals, TLC

(***************************************************************************
This finite model freezes the first snapshot-visible entry selected from one
canonical SST run. Equal keys are ordered by descending sequence; the start is
inclusive or strict, the upper bound is exclusive, and a selected tombstone is
conclusive. Selection/read failure preserves the prior output.

Three entries, two keys, two snapshots, and the finite bound modes are model
geometry only. They are not DB limits, frame sizes, request budgets, defaults,
or scan policy. The model does not prove byte comparison, CRCs, parsing,
provider behavior, progress, allocation, the Ada implementation, or refinement.
***************************************************************************)

Positions == 1 .. 3
Snapshots == 1 .. 2
StartModes == {"None", "InclusiveA", "StrictA"}
UpperModes == {"None", "UpperA", "UpperB"}
Values == {"A2", "B2"}
Prior == "Prior"
NotFound == "NotFound"
Tombstone == "Tombstone"
Outputs == Values \union {Prior, NotFound}
Phases == {"Idle", "Selecting", "Selected", "Ready", "Terminal"}
Results == {"None", "Selected", "FrameRead", "Success", "NotFound", "ReadFailed"}
ActionNames == {
    "Init", "Begin", "SelectEntry", "ReadFrame", "PublishValue",
    "PublishTombstone", "PublishAbsent", "RejectSelection", "RejectFrame",
    "UnsafeSkipFirst"
}

KeyAt(position) == IF position \in {1, 2} THEN 1 ELSE 2
SequenceAt(position) == IF position = 2 THEN 1 ELSE 2
EntryAt(position) ==
    IF position = 1 THEN "A2"
    ELSE IF position = 2 THEN Tombstone
         ELSE "B2"

ValidRequest(startMode, upperMode) ==
    ~((startMode \in {"InclusiveA", "StrictA"}) /\ upperMode = "UpperA")

StartAdmits(position, startMode) ==
    startMode = "None"
    \/ (startMode = "InclusiveA" /\ KeyAt(position) >= 1)
    \/ (startMode = "StrictA" /\ KeyAt(position) > 1)

UpperAdmits(position, upperMode) ==
    upperMode = "None"
    \/ (upperMode = "UpperA" /\ KeyAt(position) < 1)
    \/ (upperMode = "UpperB" /\ KeyAt(position) < 2)

Candidate(position, selectedSnapshot, startMode, upperMode) ==
    /\ SequenceAt(position) <= selectedSnapshot
    /\ StartAdmits(position, startMode)
    /\ UpperAdmits(position, upperMode)

ExpectedPosition(selectedSnapshot, startMode, upperMode) ==
    IF Candidate(1, selectedSnapshot, startMode, upperMode) THEN 1
    ELSE IF Candidate(2, selectedSnapshot, startMode, upperMode) THEN 2
         ELSE IF Candidate(3, selectedSnapshot, startMode, upperMode) THEN 3
              ELSE 0

VARIABLES snapshot, startMode, upperMode, selectedPosition, framePosition,
    phase, output, result, lastAction

vars == <<snapshot, startMode, upperMode, selectedPosition, framePosition,
    phase, output, result, lastAction>>

Init ==
    /\ snapshot = 1
    /\ startMode = "None"
    /\ upperMode = "None"
    /\ selectedPosition = 0
    /\ framePosition = 0
    /\ phase = "Idle"
    /\ output = Prior
    /\ result = "None"
    /\ lastAction = "Init"

BeginRequest(selectedSnapshot, selectedStart, selectedUpper) ==
    /\ phase = "Idle"
    /\ selectedSnapshot \in Snapshots
    /\ selectedStart \in StartModes
    /\ selectedUpper \in UpperModes
    /\ ValidRequest(selectedStart, selectedUpper)
    /\ snapshot' = selectedSnapshot
    /\ startMode' = selectedStart
    /\ upperMode' = selectedUpper
    /\ selectedPosition' = 0
    /\ framePosition' = 0
    /\ phase' = "Selecting"
    /\ output' = output
    /\ result' = "None"
    /\ lastAction' = "Begin"

Begin ==
    \E selectedSnapshot \in Snapshots,
       selectedStart \in StartModes,
       selectedUpper \in UpperModes :
        BeginRequest(selectedSnapshot, selectedStart, selectedUpper)

SelectEntry ==
    /\ phase = "Selecting"
    /\ selectedPosition' = ExpectedPosition(snapshot, startMode, upperMode)
    /\ phase' = "Selected"
    /\ result' = "Selected"
    /\ lastAction' = "SelectEntry"
    /\ UNCHANGED <<snapshot, startMode, upperMode, framePosition, output>>

ReadFrame ==
    /\ phase = "Selected"
    /\ selectedPosition \in Positions
    /\ framePosition' = selectedPosition
    /\ phase' = "Ready"
    /\ result' = "FrameRead"
    /\ lastAction' = "ReadFrame"
    /\ UNCHANGED <<snapshot, startMode, upperMode, selectedPosition, output>>

PublishValue ==
    /\ phase = "Ready"
    /\ framePosition = selectedPosition
    /\ EntryAt(selectedPosition) \in Values
    /\ output' = EntryAt(selectedPosition)
    /\ phase' = "Terminal"
    /\ result' = "Success"
    /\ lastAction' = "PublishValue"
    /\ UNCHANGED <<snapshot, startMode, upperMode, selectedPosition, framePosition>>

PublishTombstone ==
    /\ phase = "Ready"
    /\ framePosition = selectedPosition
    /\ EntryAt(selectedPosition) = Tombstone
    /\ output' = NotFound
    /\ phase' = "Terminal"
    /\ result' = "NotFound"
    /\ lastAction' = "PublishTombstone"
    /\ UNCHANGED <<snapshot, startMode, upperMode, selectedPosition, framePosition>>

PublishAbsent ==
    /\ phase = "Selected"
    /\ selectedPosition = 0
    /\ output' = NotFound
    /\ phase' = "Terminal"
    /\ result' = "NotFound"
    /\ lastAction' = "PublishAbsent"
    /\ UNCHANGED <<snapshot, startMode, upperMode, selectedPosition, framePosition>>

RejectSelection ==
    /\ phase = "Selecting"
    /\ phase' = "Terminal"
    /\ result' = "ReadFailed"
    /\ lastAction' = "RejectSelection"
    /\ UNCHANGED <<snapshot, startMode, upperMode, selectedPosition, framePosition, output>>

RejectFrame ==
    /\ phase = "Selected"
    /\ selectedPosition \in Positions
    /\ phase' = "Terminal"
    /\ result' = "ReadFailed"
    /\ lastAction' = "RejectFrame"
    /\ UNCHANGED <<snapshot, startMode, upperMode, selectedPosition, framePosition, output>>

UnsafeSkipFirst ==
    /\ phase = "Selecting"
    /\ ExpectedPosition(snapshot, startMode, upperMode) \in {1, 2}
    /\ selectedPosition' = 3
    /\ phase' = "Selected"
    /\ result' = "Selected"
    /\ lastAction' = "UnsafeSkipFirst"
    /\ UNCHANGED <<snapshot, startMode, upperMode, framePosition, output>>

Next ==
    \/ Begin
    \/ SelectEntry
    \/ ReadFrame
    \/ PublishValue
    \/ PublishTombstone
    \/ PublishAbsent
    \/ RejectSelection
    \/ RejectFrame

TypeOK ==
    /\ snapshot \in Snapshots
    /\ startMode \in StartModes
    /\ upperMode \in UpperModes
    /\ selectedPosition \in Positions \union {0}
    /\ framePosition \in Positions \union {0}
    /\ phase \in Phases
    /\ output \in Outputs
    /\ result \in Results
    /\ lastAction \in ActionNames

RequestBound == phase # "Idle" => ValidRequest(startMode, upperMode)

PhaseResultBound ==
    /\ (phase = "Idle" => result = "None")
    /\ (phase = "Selecting" => result = "None")
    /\ (phase = "Selected" => result = "Selected")
    /\ (phase = "Ready" => result = "FrameRead")
    /\ (phase = "Terminal" => result \in {"Success", "NotFound", "ReadFailed"})

SelectionExact ==
    phase \in {"Selected", "Ready", "Terminal"} /\ result # "ReadFailed"
    => selectedPosition = ExpectedPosition(snapshot, startMode, upperMode)

FrameBound ==
    phase = "Ready" => /\ selectedPosition \in Positions
                       /\ framePosition = selectedPosition

PrePublicationAtomic == phase # "Terminal" => output = Prior

FailureAtomic == result = "ReadFailed" => output = Prior

TerminalExact ==
    phase = "Terminal" /\ result # "ReadFailed"
    => IF selectedPosition = 0
       THEN /\ result = "NotFound"
            /\ output = NotFound
       ELSE IF EntryAt(selectedPosition) = Tombstone
            THEN /\ result = "NotFound"
                 /\ output = NotFound
            ELSE /\ result = "Success"
                 /\ output = EntryAt(selectedPosition)

Safety ==
    /\ TypeOK
    /\ RequestBound
    /\ PhaseResultBound
    /\ SelectionExact
    /\ FrameBound
    /\ PrePublicationAtomic
    /\ FailureAtomic
    /\ TerminalExact

HarnessState ==
    [action |-> lastAction,
     snapshot |-> snapshot,
     start_mode |-> startMode,
     upper_mode |-> upperMode,
     selected_position |-> selectedPosition,
     frame_position |-> framePosition,
     phase |-> phase,
     output |-> output,
     result |-> result]

HarnessAlias == CheckedWitnessAlias(lastAction, HarnessState)

Spec == Init /\ [][Next]_vars

=============================================================================
