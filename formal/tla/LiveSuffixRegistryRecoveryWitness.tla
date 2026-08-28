--------------- MODULE LiveSuffixRegistryRecoveryWitness ---------------
EXTENDS LiveSuffixRegistryPublication

(***************************************************************************
This witness selects accepted manifest-response loss, read-only same-receipt
manifest resolution, accepted HEAD-response loss, a local activation failure,
and complete same-receipt recovery.
***************************************************************************)

FailedRecovery == lastAction = "FailLocalActivation" /\ RecoverActivation

NextWitness ==
    \/ CommitSuffixGroup \/ SnapshotPartition \/ BeginFamilyAppend
    \/ StoreAppendManifest \/ LoseAcceptedManifestResponse
    \/ ResolveManifestByRead
    \/ LoseAcceptedHeadResponse \/ ResolveCommitted
    \/ FailLocalActivation \/ FailedRecovery

SpecWitness == Init /\ [][NextWitness]_vars

WitnessComplete ==
    /\ phase = "Recovered" /\ result = "Committed"
    /\ lastAction = "RecoverActivation"
    /\ headManifest = "M1" /\ headTransition = receipt
    /\ capturedCheckpoint = CheckpointIds /\ capturedSuffix = SuffixIds
    /\ recoveredIds = LedgerIds /\ oldWriterFenced
    /\ batchPuts = 0 /\ manifestPuts = 1 /\ headPuts = 1
    /\ ~cancelledAfterHead

WitnessPending == ~WitnessComplete
WitnessAlias == HarnessAlias

=============================================================================
