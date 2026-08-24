------------------ MODULE LSMPartialCompactionEquivalence ------------------
EXTENDS TLC

(***************************************************************************
This finite model freezes policy-neutral partial LSM compaction semantics.
Two consecutive selected runs are replaced by their newest mutation per key,
while an older and a newer run remain in the recovery order. Unlike complete
live-state replacement, a selected tombstone must remain in the merged run so
it can continue masking a retained older value. Two keys and two values are
finite qualification geometry, not database key/value or run-capacity policy.
***************************************************************************)

CONSTANTS K1, K2, V1, V2, NoValue, NoMutation, Tombstone

Keys == {K1, K2}
Values == {V1, V2}
ViewValues == Values \cup {NoValue}
Mutations == Values \cup {NoMutation, Tombstone}
Phases == {"Captured", "Built", "Recovered"}
ActionNames == {"Init", "BuildPartialMerge", "RecoverMergedRuns"}

EmptyView == [k \in Keys |-> NoValue]
EmptyRun == [k \in Keys |-> NoMutation]

ApplyMutation(value, mutation) ==
    IF mutation = NoMutation THEN value
    ELSE IF mutation = Tombstone THEN NoValue
    ELSE mutation

ApplyRun(view, run) ==
    [k \in Keys |-> ApplyMutation(view[k], run[k])]

ComposeMutation(earlier, later) ==
    IF later = NoMutation THEN earlier ELSE later

MergeSelected(first, second) ==
    [k \in Keys |-> ComposeMutation(first[k], second[k])]

RecoverBefore(older, first, second, newer) ==
    ApplyRun(ApplyRun(ApplyRun(ApplyRun(EmptyView, older), first), second), newer)

RecoverAfter(older, merged, newer) ==
    ApplyRun(ApplyRun(ApplyRun(EmptyView, older), merged), newer)

VARIABLES olderRun, selectedFirst, selectedSecond, newerRun, mergedRun,
    beforeView, afterView, phase, lastAction

vars == <<olderRun, selectedFirst, selectedSecond, newerRun, mergedRun,
    beforeView, afterView, phase, lastAction>>

Init ==
    /\ olderRun \in [Keys -> Mutations]
    /\ selectedFirst \in [Keys -> Mutations]
    /\ selectedSecond \in [Keys -> Mutations]
    /\ newerRun \in [Keys -> Mutations]
    /\ mergedRun = EmptyRun
    /\ beforeView = RecoverBefore(olderRun, selectedFirst, selectedSecond, newerRun)
    /\ afterView = EmptyView
    /\ phase = "Captured"
    /\ lastAction = "Init"

BuildPartialMerge ==
    /\ phase = "Captured"
    /\ mergedRun' = MergeSelected(selectedFirst, selectedSecond)
    /\ phase' = "Built"
    /\ lastAction' = "BuildPartialMerge"
    /\ UNCHANGED <<olderRun, selectedFirst, selectedSecond, newerRun,
        beforeView, afterView>>

RecoverMergedRuns ==
    /\ phase = "Built"
    /\ afterView' = RecoverAfter(olderRun, mergedRun, newerRun)
    /\ phase' = "Recovered"
    /\ lastAction' = "RecoverMergedRuns"
    /\ UNCHANGED <<olderRun, selectedFirst, selectedSecond, newerRun,
        mergedRun, beforeView>>

Next == BuildPartialMerge \/ RecoverMergedRuns
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ olderRun \in [Keys -> Mutations]
    /\ selectedFirst \in [Keys -> Mutations]
    /\ selectedSecond \in [Keys -> Mutations]
    /\ newerRun \in [Keys -> Mutations]
    /\ mergedRun \in [Keys -> Mutations]
    /\ beforeView \in [Keys -> ViewValues]
    /\ afterView \in [Keys -> ViewValues]
    /\ phase \in Phases
    /\ lastAction \in ActionNames

MergedRunIsExact == phase = "Captured" \/
    mergedRun = MergeSelected(selectedFirst, selectedSecond)

SelectedTombstonesRemain == phase = "Captured" \/
    \A k \in Keys :
        /\ (selectedSecond[k] = Tombstone => mergedRun[k] = Tombstone)
        /\ (/\ selectedSecond[k] = NoMutation
            /\ selectedFirst[k] = Tombstone
            => mergedRun[k] = Tombstone)

RecoveryPreservesEveryRead == phase # "Recovered" \/ afterView = beforeView

Safety ==
    /\ TypeOK
    /\ MergedRunIsExact
    /\ SelectedTombstonesRemain
    /\ RecoveryPreservesEveryRead

=============================================================================
