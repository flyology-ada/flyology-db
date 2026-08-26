------------------------- MODULE LazySSTReadWitness -----------------------
EXTENDS LazySSTRead

WitnessNext ==
    CASE lastAction = "Init" -> Begin
      [] lastAction = "Begin" -> ReadIndex
      [] lastAction = "ReadIndex" -> RejectAllocation
      [] lastAction = "RejectAllocation" -> ReadFrame
      [] lastAction = "ReadFrame" -> ReplaceObject
      [] lastAction = "ReplaceObject" -> PublishSuccess

WitnessSpec == Init /\ [][WitnessNext]_vars
WitnessPending == lastAction # "PublishSuccess"

=============================================================================
