--------------- MODULE LSMCompactionEquivalenceSafetyProof ---------------

(***************************************************************************
This unbounded kernel proves the point-read semantics of complete live-state
replacement for arbitrary nonempty key and value sets. The replacement run
contains a Put for each captured live key and no entry for absence; replaying
any later delta over its recovery is equivalent to replaying that delta over
the captured view. Formats, allocation, publication, retention, and progress
remain in their separate proof lanes.
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

Compact(view) ==
    [k \in Keys |-> IF view[k] = NoValue THEN NoMutation ELSE view[k]]

THEOREM CompactedRunHasNoTombstones ==
    DistinctSentinels =>
        \A view \in [Keys -> ViewValues] :
            \A k \in Keys : Compact(view)[k] # Tombstone
<1> QED BY DEF DistinctSentinels, Compact, ViewValues

THEOREM AbsenceProducesNoEntry ==
    \A view \in [Keys -> ViewValues] :
        \A k \in Keys : view[k] = NoValue => Compact(view)[k] = NoMutation
<1> QED BY DEF Compact

THEOREM LiveValueProducesPut ==
    \A view \in [Keys -> ViewValues] :
        \A k \in Keys : view[k] # NoValue => Compact(view)[k] = view[k]
<1> QED BY DEF Compact

THEOREM CompactionReconstructsView ==
    DistinctSentinels =>
        \A view \in [Keys -> ViewValues] :
            ApplyRun(EmptyView, Compact(view)) = view
<1> QED BY DEF DistinctSentinels, ApplyRun, ApplyMutation, Compact, EmptyView, ViewValues

THEOREM LaterDeltaPreservesView ==
    DistinctSentinels =>
        \A view \in [Keys -> ViewValues] :
            \A delta \in [Keys -> Mutations] :
                ApplyRun(ApplyRun(EmptyView, Compact(view)), delta)
                  = ApplyRun(view, delta)
<1> QED BY CompactionReconstructsView

=============================================================================
