----------------------- MODULE CheckpointPartialRunProbe -----------------------
EXTENDS CheckpointPublication

ProbeNext == Next \/ UnsafePublishWithPartialRunSet

ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
