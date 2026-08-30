--------------- MODULE CommitResolutionAuthorityAcceptedWitness ---------------
EXTENDS CommitPublication

AcceptedImportComplete ==
    /\ lastAction = "ResolveCommitted"
    /\ crashObserved
    /\ durableAuthority[T1] = B1
    /\ authorityLifecycle[T1] = "Imported"
    /\ wasUnknown[T1]
    /\ receipt[T1] = "Committed"
    /\ T1 \in batchTxns[B1]

AcceptedImportPending == ~AcceptedImportComplete

=============================================================================
