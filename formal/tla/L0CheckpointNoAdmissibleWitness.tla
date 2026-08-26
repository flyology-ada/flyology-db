---------------- MODULE L0CheckpointNoAdmissibleWitness --------------------
EXTENDS L0CheckpointSelection

WitnessPending ==
    ~(/\ phase = "Observed"
      /\ action = "NoAdmissible"
      /\ selectedFamilies = {}
      /\ nonempty = Families
      /\ totalMaximum = 1
      /\ dirty)

=============================================================================
