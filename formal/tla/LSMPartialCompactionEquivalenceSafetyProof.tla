------------ MODULE LSMPartialCompactionEquivalenceSafetyProof ------------

(***************************************************************************
This unbounded kernel proves policy-neutral partial LSM compaction for
arbitrary nonempty key and value sets. Replacing two consecutive selected
runs with their newest mutation per key preserves all reads while retained
older and newer runs remain in order. Tombstones are mutations and therefore
remain when they are the newest selected mutation. Formats, sequence-range
selection, allocation, publication, retention, scheduling, and progress stay
in their separate lanes.
***************************************************************************)

CONSTANTS Keys, Values, NoValue, NoMutation, Tombstone

NonemptyTypes ==
    /\ Keys # {}
    /\ Values # {}
DistinctSentinels ==
    /\ NoValue \notin Values
    /\ NoMutation \notin Values
    /\ Tombstone \notin Values
    /\ NoValue # NoMutation
    /\ NoValue # Tombstone
    /\ NoMutation # Tombstone

ASSUME NonemptyTypes /\ DistinctSentinels

ViewValues == Values \cup {NoValue}
Mutations == Values \cup {NoMutation, Tombstone}

EmptyView == [k \in Keys |-> NoValue]

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

THEOREM NewestSelectedMutationIsRetained ==
    \A first, second \in [Keys -> Mutations] :
        \A k \in Keys :
            /\ (second[k] # NoMutation => MergeSelected(first, second)[k] = second[k])
            /\ (second[k] = NoMutation => MergeSelected(first, second)[k] = first[k])
<1> QED BY DEF MergeSelected, ComposeMutation

THEOREM SelectedTombstonesAreRetained ==
    DistinctSentinels =>
        \A first, second \in [Keys -> Mutations] :
            \A k \in Keys :
                /\ (second[k] = Tombstone => MergeSelected(first, second)[k] = Tombstone)
                /\ (/\ second[k] = NoMutation
                    /\ first[k] = Tombstone
                    => MergeSelected(first, second)[k] = Tombstone)
<1> QED BY DEF DistinctSentinels, MergeSelected, ComposeMutation

THEOREM ComposedMutationPreservesValue ==
    DistinctSentinels =>
        \A value \in ViewValues :
            \A first, second \in Mutations :
                ApplyMutation(ApplyMutation(value, first), second)
                  = ApplyMutation(value, ComposeMutation(first, second))
<1> QED BY DEF DistinctSentinels, ViewValues, Mutations,
    ApplyMutation, ComposeMutation

THEOREM SelectedMergePreservesView ==
    DistinctSentinels =>
        \A view \in [Keys -> ViewValues] :
            \A first, second \in [Keys -> Mutations] :
                ApplyRun(ApplyRun(view, first), second)
                  = ApplyRun(view, MergeSelected(first, second))
<1> QED BY DEF DistinctSentinels, ViewValues, Mutations,
    ApplyRun, ApplyMutation, MergeSelected, ComposeMutation

THEOREM PartialMergePreservesEveryRead ==
    DistinctSentinels =>
        \A older, first, second, newer \in [Keys -> Mutations] :
            RecoverBefore(older, first, second, newer)
              = RecoverAfter(older, MergeSelected(first, second), newer)
<1> QED BY DEF DistinctSentinels, ViewValues, Mutations, EmptyView,
    ApplyRun, ApplyMutation, MergeSelected, ComposeMutation,
    RecoverBefore, RecoverAfter

=============================================================================
