--------------------- MODULE LSMCompactionEquivalence ---------------------
EXTENDS TLC

(***************************************************************************
This finite model freezes the read semantics of complete live-state L0
replacement. A compacted run emits one Put for every live key and no entry
for an absent key. Recovering that run must reproduce the captured view
exactly, and applying any later delta must produce the same view as applying
that delta directly to the capture. Two keys and two values are finite
qualification geometry, not database key/value or run-capacity policy.
***************************************************************************)

CONSTANTS K1, K2, V1, V2, NoValue, NoMutation, Tombstone

Keys == {K1, K2}
Values == {V1, V2}
ViewValues == Values \cup {NoValue}
Mutations == Values \cup {NoMutation, Tombstone}
Phases == {"Captured", "Built", "Recovered", "Replayed"}
ActionNames == {"Init", "BuildCompactedRun", "RecoverCompactedRun", "ReplayLaterDelta"}

EmptyView == [k \in Keys |-> NoValue]
EmptyRun == [k \in Keys |-> NoMutation]

ApplyMutation(value, mutation) ==
    IF mutation = NoMutation THEN value
    ELSE IF mutation = Tombstone THEN NoValue
    ELSE mutation

ApplyRun(view, run) ==
    [k \in Keys |-> ApplyMutation(view[k], run[k])]

Compact(view) ==
    [k \in Keys |-> IF view[k] = NoValue THEN NoMutation ELSE view[k]]

VARIABLES sourceView, laterDelta, compactedRun, recoveredView,
    replayedView, phase, lastAction

vars == <<sourceView, laterDelta, compactedRun, recoveredView,
    replayedView, phase, lastAction>>

Init ==
    /\ sourceView \in [Keys -> ViewValues]
    /\ laterDelta \in [Keys -> Mutations]
    /\ compactedRun = EmptyRun
    /\ recoveredView = EmptyView
    /\ replayedView = EmptyView
    /\ phase = "Captured"
    /\ lastAction = "Init"

BuildCompactedRun ==
    /\ phase = "Captured"
    /\ compactedRun' = Compact(sourceView)
    /\ phase' = "Built"
    /\ lastAction' = "BuildCompactedRun"
    /\ UNCHANGED <<sourceView, laterDelta, recoveredView, replayedView>>

RecoverCompactedRun ==
    /\ phase = "Built"
    /\ recoveredView' = ApplyRun(EmptyView, compactedRun)
    /\ phase' = "Recovered"
    /\ lastAction' = "RecoverCompactedRun"
    /\ UNCHANGED <<sourceView, laterDelta, compactedRun, replayedView>>

ReplayLaterDelta ==
    /\ phase = "Recovered"
    /\ replayedView' = ApplyRun(recoveredView, laterDelta)
    /\ phase' = "Replayed"
    /\ lastAction' = "ReplayLaterDelta"
    /\ UNCHANGED <<sourceView, laterDelta, compactedRun, recoveredView>>

Next == BuildCompactedRun \/ RecoverCompactedRun \/ ReplayLaterDelta
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ sourceView \in [Keys -> ViewValues]
    /\ laterDelta \in [Keys -> Mutations]
    /\ compactedRun \in [Keys -> Mutations]
    /\ recoveredView \in [Keys -> ViewValues]
    /\ replayedView \in [Keys -> ViewValues]
    /\ phase \in Phases
    /\ lastAction \in ActionNames

CompactedRunIsCanonical == phase = "Captured" \/
    \A k \in Keys :
        /\ compactedRun[k] # Tombstone
        /\ (sourceView[k] = NoValue => compactedRun[k] = NoMutation)
        /\ (sourceView[k] # NoValue => compactedRun[k] = sourceView[k])

RecoveryPreservesEveryRead == phase \notin {"Recovered", "Replayed"} \/
    recoveredView = sourceView

LaterReplayPreservesEveryRead == phase # "Replayed" \/
    replayedView = ApplyRun(sourceView, laterDelta)

Safety ==
    /\ TypeOK
    /\ CompactedRunIsCanonical
    /\ RecoveryPreservesEveryRead
    /\ LaterReplayPreservesEveryRead

=============================================================================
