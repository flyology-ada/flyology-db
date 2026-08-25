---------------- MODULE LSMThreeRunCompactionEquivalence ----------------
EXTENDS Integers, TLC

(***************************************************************************
This finite model freezes one policy-neutral three-run compaction step. Three
caller-selected consecutive runs sit between retained older and newer runs.
Their newest mutation per key, including a middle-run tombstone when the last
run is empty for that key, becomes one merged run. A post-checkpoint suffix
and its transaction-identity authority transfer unchanged. One key, two
values, and a three-run selected slice are qualification geometry, not key,
value, fanout, trigger, level, or capacity policy.
***************************************************************************)

CONSTANTS K1, V1, V2, NoValue, NoMutation, Tombstone

Keys == {K1}
Values == {V1, V2}
ViewValues == Values \cup {NoValue}
Mutations == Values \cup {NoMutation, Tombstone}
SelectedSlots == 1 .. 3
Phases == {"Captured", "Built", "Recovered"}
ActionNames == {"Init", "BuildThreeRunMerge", "RecoverMergedRuns"}

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

MergeSelectedThree(selected) ==
    [k \in Keys |->
        ComposeMutation(
            ComposeMutation(selected[1][k], selected[2][k]),
            selected[3][k])]

RecoverBefore(older, selected, newer, suffix) ==
    ApplyRun(
        ApplyRun(
            ApplyRun(
                ApplyRun(
                    ApplyRun(
                        ApplyRun(EmptyView, older),
                        selected[1]),
                    selected[2]),
                selected[3]),
            newer),
        suffix)

RecoverAfter(older, merged, newer, suffix) ==
    ApplyRun(ApplyRun(ApplyRun(ApplyRun(EmptyView, older), merged), newer), suffix)

VARIABLES olderRun, selectedRuns, newerRun, suffixBatch, mergedRun,
    transferredSuffix, identityRetained, beforeView, afterView, phase,
    lastAction

vars == <<olderRun, selectedRuns, newerRun, suffixBatch, mergedRun,
    transferredSuffix, identityRetained, beforeView, afterView, phase,
    lastAction>>

Init ==
    /\ olderRun \in [Keys -> Mutations]
    /\ selectedRuns \in [SelectedSlots -> [Keys -> Mutations]]
    /\ newerRun \in [Keys -> Mutations]
    /\ suffixBatch \in [Keys -> Mutations]
    /\ mergedRun = EmptyRun
    /\ transferredSuffix = EmptyRun
    /\ identityRetained = FALSE
    /\ beforeView = RecoverBefore(olderRun, selectedRuns, newerRun, suffixBatch)
    /\ afterView = EmptyView
    /\ phase = "Captured"
    /\ lastAction = "Init"

BuildThreeRunMerge ==
    /\ phase = "Captured"
    /\ mergedRun' = MergeSelectedThree(selectedRuns)
    /\ transferredSuffix' = suffixBatch
    /\ identityRetained' = TRUE
    /\ phase' = "Built"
    /\ lastAction' = "BuildThreeRunMerge"
    /\ UNCHANGED <<olderRun, selectedRuns, newerRun, suffixBatch,
        beforeView, afterView>>

RecoverMergedRuns ==
    /\ phase = "Built"
    /\ afterView' = RecoverAfter(olderRun, mergedRun, newerRun, transferredSuffix)
    /\ phase' = "Recovered"
    /\ lastAction' = "RecoverMergedRuns"
    /\ UNCHANGED <<olderRun, selectedRuns, newerRun, suffixBatch, mergedRun,
        transferredSuffix, identityRetained, beforeView>>

Next == BuildThreeRunMerge \/ RecoverMergedRuns
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ olderRun \in [Keys -> Mutations]
    /\ selectedRuns \in [SelectedSlots -> [Keys -> Mutations]]
    /\ newerRun \in [Keys -> Mutations]
    /\ suffixBatch \in [Keys -> Mutations]
    /\ mergedRun \in [Keys -> Mutations]
    /\ transferredSuffix \in [Keys -> Mutations]
    /\ identityRetained \in BOOLEAN
    /\ beforeView \in [Keys -> ViewValues]
    /\ afterView \in [Keys -> ViewValues]
    /\ phase \in Phases
    /\ lastAction \in ActionNames

MergedRunIsExact == phase = "Captured" \/
    mergedRun = MergeSelectedThree(selectedRuns)

MiddleTombstoneRemains == phase = "Captured" \/
    \A k \in Keys :
        /\ (selectedRuns[3][k] = Tombstone => mergedRun[k] = Tombstone)
        /\ (/\ selectedRuns[3][k] = NoMutation
            /\ selectedRuns[2][k] = Tombstone
            => mergedRun[k] = Tombstone)

SuffixAuthorityTransfers == phase = "Captured" \/
    /\ transferredSuffix = suffixBatch
    /\ identityRetained

RecoveryPreservesEveryRead == phase # "Recovered" \/ afterView = beforeView

Safety ==
    /\ TypeOK
    /\ MergedRunIsExact
    /\ MiddleTombstoneRemains
    /\ SuffixAuthorityTransfers
    /\ RecoveryPreservesEveryRead

=============================================================================
