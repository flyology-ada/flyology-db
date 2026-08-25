---------- MODULE LSMThreeRunCompactionEquivalenceSafetyProof ----------

(***************************************************************************
This kernel proves one policy-neutral three-run compaction step for arbitrary
nonempty key and value sets. Mutation composition is associative; the newest
of three selected mutations, including a middle tombstone when the last run
is empty for that key, is retained. Retained older/newer runs and an unchanged
suffix preserve every read. Selection, trigger, fanout, levels, allocation,
publication, retention, progress, and Ada refinement stay separate.
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

MergeSelectedThree(first, middle, last) ==
    [k \in Keys |->
        ComposeMutation(ComposeMutation(first[k], middle[k]), last[k])]

RecoverBefore(older, first, middle, last, newer, suffix) ==
    ApplyRun(
        ApplyRun(
            ApplyRun(
                ApplyRun(
                    ApplyRun(
                        ApplyRun(EmptyView, older), first), middle), last),
            newer), suffix)

RecoverAfter(older, merged, newer, suffix) ==
    ApplyRun(ApplyRun(ApplyRun(ApplyRun(EmptyView, older), merged), newer), suffix)

THEOREM MutationCompositionIsAssociative ==
    \A first, middle, last \in Mutations :
        ComposeMutation(ComposeMutation(first, middle), last)
          = ComposeMutation(first, ComposeMutation(middle, last))
<1> QED BY DEF Mutations, ComposeMutation

THEOREM LastSelectedMutationIsRetained ==
    \A first, middle, last \in Mutations :
        last # NoMutation =>
          ComposeMutation(ComposeMutation(first, middle), last) = last
<1> QED BY DEF Mutations, ComposeMutation

THEOREM MiddleSelectedMutationIsRetainedWhenLastIsEmpty ==
    \A first, middle, last \in Mutations :
        /\ last = NoMutation
        /\ middle # NoMutation
        => ComposeMutation(ComposeMutation(first, middle), last) = middle
<1> QED BY DEF Mutations, ComposeMutation

THEOREM MiddleTombstoneIsRetainedWhenLastIsEmpty ==
    DistinctSentinels =>
      \A first \in Mutations :
        ComposeMutation(ComposeMutation(first, Tombstone), NoMutation)
          = Tombstone
<1> QED BY DEF DistinctSentinels, Mutations, ComposeMutation

THEOREM ThreeComposedMutationsPreserveValue ==
    DistinctSentinels =>
      \A value \in ViewValues :
        \A first, middle, last \in Mutations :
          ApplyMutation(
              ApplyMutation(ApplyMutation(value, first), middle), last)
            = ApplyMutation(
                value,
                ComposeMutation(ComposeMutation(first, middle), last))
<1> QED BY DEF DistinctSentinels, ViewValues, Mutations,
    ApplyMutation, ComposeMutation

THEOREM ThreeSelectedRunsPreserveView ==
    DistinctSentinels =>
      \A view \in [Keys -> ViewValues] :
        \A first, middle, last \in [Keys -> Mutations] :
          ApplyRun(ApplyRun(ApplyRun(view, first), middle), last)
            = ApplyRun(view, MergeSelectedThree(first, middle, last))
<1> QED BY DEF DistinctSentinels, ViewValues, Mutations,
    ApplyRun, ApplyMutation, MergeSelectedThree, ComposeMutation

THEOREM ThreeRunPartialMergePreservesEveryRead ==
    DistinctSentinels =>
      \A older, first, middle, last, newer, suffix \in [Keys -> Mutations] :
        RecoverBefore(older, first, middle, last, newer, suffix)
          = RecoverAfter(
              older, MergeSelectedThree(first, middle, last), newer, suffix)
<1> QED BY DEF DistinctSentinels, ViewValues, Mutations, EmptyView,
    ApplyRun, ApplyMutation, MergeSelectedThree, ComposeMutation,
    RecoverBefore, RecoverAfter

=============================================================================
