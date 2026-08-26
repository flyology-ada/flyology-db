-------------------- MODULE LazySSTNextEntryWitness ---------------------
EXTENDS LazySSTNextEntry

WitnessNext ==
    CASE lastAction = "Init" -> BeginRequest(1, "InclusiveA", "UpperB")
      [] lastAction = "Begin" -> SelectEntry
      [] lastAction = "SelectEntry" -> ReadFrame
      [] lastAction = "ReadFrame" -> PublishTombstone

WitnessSpec == Init /\ [][WitnessNext]_vars
WitnessPending == lastAction # "PublishTombstone"

=============================================================================
