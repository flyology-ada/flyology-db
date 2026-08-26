-------------------- MODULE L0CheckpointSelectionWitness --------------------
EXTENDS L0CheckpointSelection

WitnessPending ==
    ~(/\ phase = "Observed"
      /\ action = "Complete"
      /\ current = [family \in Families |-> 1]
      /\ maximum = [family \in Families |-> 2]
      /\ changed = Families
      /\ nonempty = Families
      /\ totalMaximum = 3
      /\ dirty)

=============================================================================
