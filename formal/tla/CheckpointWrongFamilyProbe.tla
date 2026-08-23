----------------------- MODULE CheckpointWrongFamilyProbe -----------------------
EXTENDS CheckpointPublication

ProbeNext == Next \/ UnsafePublishWithWrongFamilyMapping

ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
