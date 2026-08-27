------------ MODULE AuthenticatedScanInitializationSkipProbe ------------
EXTENDS AuthenticatedScanInitialization

UnsafeNext == Begin \/ UnsafeSkipEntry

UnsafeSpec == Init /\ [][UnsafeNext]_vars

=============================================================================
