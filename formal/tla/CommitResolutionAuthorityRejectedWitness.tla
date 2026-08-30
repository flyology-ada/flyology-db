--------------- MODULE CommitResolutionAuthorityRejectedWitness ---------------
EXTENDS CommitPublication

RejectedImportComplete ==
    /\ lastAction = "ResolvePreconditionFailure"
    /\ crashObserved
    /\ durableAuthority[T1] = B1
    /\ authorityLifecycle[T1] = "Imported"
    /\ wasUnknown[T1]
    /\ receipt[T1] = "PreconditionFailed"
    /\ T1 \in batchTxns[B1]

RejectedImportPending == ~RejectedImportComplete

=============================================================================
