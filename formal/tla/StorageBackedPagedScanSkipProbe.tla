-------------------- MODULE StorageBackedPagedScanSkipProbe -------------------
EXTENDS StorageBackedPagedScan

UnsafeNext == (lastAction = "Init" /\ BeginPage(2)) \/ UnsafeSkipVisible

UnsafeSpec == Init /\ [][UnsafeNext]_vars

=============================================================================
