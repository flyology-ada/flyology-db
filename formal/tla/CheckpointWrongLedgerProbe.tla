----------------------- MODULE CheckpointWrongLedgerProbe -----------------------
EXTENDS CheckpointPublication

ProbeNext == Next \/ UnsafePublishWithWrongIdentityLedger

ProbeSpec == Init /\ [][ProbeNext]_vars

=============================================================================
