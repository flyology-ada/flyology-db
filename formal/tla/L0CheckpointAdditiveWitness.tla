------------------- MODULE L0CheckpointAdditiveWitness ---------------------
EXTENDS L0CheckpointSelection

WitnessPending ==
    ~(/\ phase = "Observed"
      /\ action = "Additive"
      /\ selectedFamilies = {"F1"}
      /\ changed = {"F1"}
      /\ dirty)

=============================================================================
