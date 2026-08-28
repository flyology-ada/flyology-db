------------- MODULE LiveSuffixRegistryCancellationWitness -------------
EXTENDS LiveSuffixRegistryPublication

(***************************************************************************
This witness selects a conclusive HEAD response, immediate fencing,
post-HEAD cancellation, and complete same-receipt recovery without replay.
***************************************************************************)

NextWitness ==
    \/ CommitSuffixGroup \/ SnapshotPartition \/ BeginFamilyAppend
    \/ StoreAppendManifest \/ ConfirmAppendManifest
    \/ PublishAppendHead \/ CancelAfterHead \/ RecoverActivation

SpecWitness == Init /\ [][NextWitness]_vars

WitnessComplete ==
    /\ phase = "Recovered" /\ result = "Committed"
    /\ lastAction = "RecoverActivation"
    /\ headManifest = "M1" /\ headTransition = receipt
    /\ capturedCheckpoint = CheckpointIds /\ capturedSuffix = SuffixIds
    /\ recoveredIds = LedgerIds /\ oldWriterFenced
    /\ batchPuts = 0 /\ manifestPuts = 1 /\ headPuts = 1
    /\ cancelledAfterHead

WitnessPending == ~WitnessComplete
WitnessAlias == HarnessAlias

=============================================================================
