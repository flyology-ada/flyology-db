----------------------- MODULE L0CheckpointSelection -----------------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
This finite model freezes the maintenance observation that precedes caller-
owned Flush or complete Compact. Two families, zero-to-two current runs, and
one-to-three database-wide slots are exhaustive qualification geometry, not
product defaults. The observation mutates no authority, reserves no identity,
and creates no scheduling or Ada-refinement claim.
***************************************************************************)

Families == {"F1", "F2"}
Actions == {"NoWork", "Additive", "Complete", "NoAdmissible"}

CurrentTotal(current) == current["F1"] + current["F2"]

AdditiveFits(current, maximum, changed, totalMaximum) ==
    /\ \A family \in changed : current[family] < maximum[family]
    /\ Cardinality(changed) <= totalMaximum - CurrentTotal(current)

CompleteFits(nonempty, totalMaximum) ==
    Cardinality(nonempty) <= totalMaximum

RequiredAction(current, maximum, changed, nonempty, totalMaximum, dirty) ==
    IF ~dirty THEN "NoWork"
    ELSE IF AdditiveFits(current, maximum, changed, totalMaximum) THEN "Additive"
    ELSE IF CompleteFits(nonempty, totalMaximum) THEN "Complete"
    ELSE "NoAdmissible"

VARIABLES current, maximum, changed, nonempty, totalMaximum, dirty,
          action, phase, lastAction

vars == <<current, maximum, changed, nonempty, totalMaximum, dirty,
          action, phase, lastAction>>

AuthorityValid ==
    /\ current \in [Families -> 0 .. 2]
    /\ maximum \in [Families -> 1 .. 2]
    /\ \A family \in Families : current[family] <= maximum[family]
    /\ totalMaximum \in 1 .. 3
    /\ CurrentTotal(current) <= totalMaximum
    /\ changed \subseteq Families
    /\ nonempty \subseteq Families
    /\ dirty \in BOOLEAN
    /\ ~dirty => changed = {}

Init ==
    /\ AuthorityValid
    /\ action = "Unobserved"
    /\ phase = "Ready"
    /\ lastAction = "Init"

ObserveNoWork ==
    /\ phase = "Ready"
    /\ RequiredAction(current, maximum, changed, nonempty, totalMaximum, dirty) = "NoWork"
    /\ action' = "NoWork"
    /\ phase' = "Observed"
    /\ lastAction' = "ObserveNoWork"
    /\ UNCHANGED <<current, maximum, changed, nonempty, totalMaximum, dirty>>

ObserveAdditive ==
    /\ phase = "Ready"
    /\ RequiredAction(current, maximum, changed, nonempty, totalMaximum, dirty) = "Additive"
    /\ action' = "Additive"
    /\ phase' = "Observed"
    /\ lastAction' = "ObserveAdditive"
    /\ UNCHANGED <<current, maximum, changed, nonempty, totalMaximum, dirty>>

ObserveComplete ==
    /\ phase = "Ready"
    /\ RequiredAction(current, maximum, changed, nonempty, totalMaximum, dirty) = "Complete"
    /\ action' = "Complete"
    /\ phase' = "Observed"
    /\ lastAction' = "ObserveComplete"
    /\ UNCHANGED <<current, maximum, changed, nonempty, totalMaximum, dirty>>

ObserveNoAdmissible ==
    /\ phase = "Ready"
    /\ RequiredAction(current, maximum, changed, nonempty, totalMaximum, dirty) = "NoAdmissible"
    /\ action' = "NoAdmissible"
    /\ phase' = "Observed"
    /\ lastAction' = "ObserveNoAdmissible"
    /\ UNCHANGED <<current, maximum, changed, nonempty, totalMaximum, dirty>>

Next == ObserveNoWork \/ ObserveAdditive \/ ObserveComplete \/ ObserveNoAdmissible

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ AuthorityValid
    /\ action \in Actions \cup {"Unobserved"}
    /\ phase \in {"Ready", "Observed"}
    /\ lastAction \in
         {"Init", "ObserveNoWork", "ObserveAdditive", "ObserveComplete", "ObserveNoAdmissible"}

ObservationCorrect ==
    phase = "Observed" =>
      action = RequiredAction(current, maximum, changed, nonempty, totalMaximum, dirty)

ObservationHasNoEffects ==
    phase = "Observed" => AuthorityValid

=============================================================================
