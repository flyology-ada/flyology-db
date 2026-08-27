------------- MODULE AuthenticatedScanInitializationWitness -------------
EXTENDS AuthenticatedScanInitialization, FlyologyHarness

WitnessNext == Begin \/ ReadEntry \/ ReadAbsent \/ SkipFuture \/ PublishCursor

WitnessPending == lastAction # "PublishCursor"

WitnessSpec == Init /\ [][WitnessNext]_vars

=============================================================================
