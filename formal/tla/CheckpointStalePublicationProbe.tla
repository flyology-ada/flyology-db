-------------------- MODULE CheckpointStalePublicationProbe --------------------
EXTENDS CheckpointPublication

ProbeNext == Next \/ UnsafePublishWithStaleExpectedHead

ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
