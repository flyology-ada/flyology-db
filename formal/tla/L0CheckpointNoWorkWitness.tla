-------------------- MODULE L0CheckpointNoWorkWitness ----------------------
EXTENDS L0CheckpointSelection

WitnessPending ==
    ~(/\ phase = "Observed"
      /\ action = "NoWork"
      /\ selectedFamilies = {}
      /\ ~dirty)

=============================================================================
