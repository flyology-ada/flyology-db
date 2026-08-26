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

SelectedFamilies ==
    IF Decision = "Additive" THEN Changed
    ELSE IF Decision = "Complete" THEN Nonempty
    ELSE {}

THEOREM NoWorkSelection == ~Dirty => Decision = "NoWork"
<1>1. QED BY DEF Decision

THEOREM AdditiveSelection == Dirty /\ AdditiveFits => Decision = "Additive"
<1>1. QED BY DEF Decision

THEOREM CompleteSelection == Dirty /\ ~AdditiveFits /\ CompleteFits => Decision = "Complete"
<1>1. QED BY DEF Decision

THEOREM NoAdmissibleSelection ==
    Dirty /\ ~AdditiveFits /\ ~CompleteFits => Decision = "NoAdmissible"
<1>1. QED BY DEF Decision

THEOREM NoWorkFamilies == ~Dirty => SelectedFamilies = {}
<1>1. QED BY DEF SelectedFamilies, Decision

THEOREM AdditiveFamilies == Dirty /\ AdditiveFits => SelectedFamilies = Changed
<1>1. QED BY DEF SelectedFamilies, Decision

THEOREM CompleteFamilies ==
    Dirty /\ ~AdditiveFits /\ CompleteFits => SelectedFamilies = Nonempty
<1>1. QED BY DEF SelectedFamilies, Decision

THEOREM NoAdmissibleFamilies ==
    Dirty /\ ~AdditiveFits /\ ~CompleteFits => SelectedFamilies = {}
<1>1. QED BY DEF SelectedFamilies, Decision

=============================================================================
