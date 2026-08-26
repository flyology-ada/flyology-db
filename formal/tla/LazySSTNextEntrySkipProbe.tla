------------------- MODULE LazySSTNextEntrySkipProbe --------------------
EXTENDS LazySSTNextEntry

UnsafeNext == Next \/ UnsafeSkipFirst
UnsafeSpec == Init /\ [][UnsafeNext]_vars

=============================================================================
