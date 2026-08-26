----------------- MODULE L0CheckpointSelectionSafetyProof -----------------
EXTENDS FiniteSets, Naturals

CONSTANTS Current, Maximum, Changed, Nonempty, TotalMaximum, Dirty

AdditiveFits ==
    /\ \A family \in Changed : Current[family] < Maximum[family]
    /\ Cardinality(Changed) <= TotalMaximum - (Current["F1"] + Current["F2"])

CompleteFits == Cardinality(Nonempty) <= TotalMaximum

Decision ==
    IF ~Dirty THEN "NoWork"
    ELSE IF AdditiveFits THEN "Additive"
    ELSE IF CompleteFits THEN "Complete"
    ELSE "NoAdmissible"

THEOREM NoWorkSelection == ~Dirty => Decision = "NoWork"
<1>1. QED BY DEF Decision

THEOREM AdditiveSelection == Dirty /\ AdditiveFits => Decision = "Additive"
<1>1. QED BY DEF Decision

THEOREM CompleteSelection == Dirty /\ ~AdditiveFits /\ CompleteFits => Decision = "Complete"
<1>1. QED BY DEF Decision

THEOREM NoAdmissibleSelection ==
    Dirty /\ ~AdditiveFits /\ ~CompleteFits => Decision = "NoAdmissible"
<1>1. QED BY DEF Decision

=============================================================================
