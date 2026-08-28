---------------- MODULE LiveSuffixRegistryPublication ----------------
EXTENDS FiniteSets, Naturals, TLC, FlyologyHarness

(***************************************************************************
This focused model covers appending one family to an authenticated registry
whose retained checkpoint has a later two-transaction live suffix. The
checkpoint/suffix partition is captured exactly, the suffix group is never
split, and the registry successor retains the replay boundary and identity
ledger. A conclusive successor HEAD fences the old writer in the same action.
Cancellation or local activation failure after HEAD preserves durable
authority, and recovery uses the same receipt without another provider Put.

One checkpoint identity, one two-member suffix, and one appended family are
finite qualification geometry, not product capacities or public defaults.
Formats, byte authentication, provider behavior, progress, Ada, and refinement
remain outside this model.
***************************************************************************)

CheckpointIds == {"I1"}
SuffixIds == {"I2", "I3"}
LedgerIds == CheckpointIds \union SuffixIds
Families == {"Existing", "Appended"}
Manifests == {"M0", "M1", "MR"}
Batches == {"B1"}
Receipts == {"AppendReceipt", "RivalReceipt"}
Results == {"None", "Unknown", "Committed", "Rejected",
    "LocalActivationFailed"}
Phases == {"CheckpointOnly", "SuffixCommitted", "PartitionCaptured",
    "AppendBegun", "ManifestStored", "ManifestUnknown", "Ready",
    "HeadConfirmed", "Unknown", "UnknownRival", "Cancelled", "LocalFailed",
    "Recovered", "Rejected"}
ActionNames == {"Init", "CommitSuffixGroup", "SnapshotPartition",
    "BeginFamilyAppend", "StoreAppendManifest",
    "ConfirmAppendManifest", "LoseAcceptedManifestResponse",
    "ResolveManifestByRead", "PublishAppendHead", "LoseAcceptedHeadResponse",
    "ObserveHeadPreconditionFailure", "ExternalPublishRival",
    "ResolveCommitted", "ResolveRejected", "CancelAfterHead",
    "FailLocalActivation", "RecoverActivation"}

VARIABLES storedManifests, confirmedManifests, storedBatches,
    confirmedBatches, manifestPrevious, manifestRegistry,
    manifestReplayBoundary, manifestLedger,
    batchFirst, batchHighest, batchIds, headManifest, headLatestBatch, headHighest,
    headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
    capturedCheckpoint, capturedSuffix, receipt, result, phase, oldWriterFenced,
    recoveredIds, cancelledAfterHead, rivalRejected, batchPuts, manifestPuts,
    headPuts, lastAction

vars == <<storedManifests, confirmedManifests, storedBatches,
    confirmedBatches, manifestPrevious, manifestRegistry,
    manifestReplayBoundary, manifestLedger,
    batchFirst, batchHighest, batchIds, headManifest, headLatestBatch, headHighest,
    headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
    capturedCheckpoint, capturedSuffix, receipt, result, phase, oldWriterFenced,
    recoveredIds, cancelledAfterHead, rivalRejected, batchPuts, manifestPuts,
    headPuts, lastAction>>

EmptyManifestSet == [m \in Manifests |-> {}]

Init ==
    /\ storedManifests = {"M0"}
    /\ confirmedManifests = {"M0"}
    /\ storedBatches = {} /\ confirmedBatches = {}
    /\ manifestPrevious = [m \in Manifests |-> "None"]
    /\ manifestRegistry = [EmptyManifestSet EXCEPT !["M0"] = {"Existing"}]
    /\ manifestReplayBoundary =
         [m \in Manifests |-> IF m = "M0" THEN 1 ELSE 0]
    /\ manifestLedger = [EmptyManifestSet EXCEPT !["M0"] = CheckpointIds]
    /\ batchFirst = [b \in Batches |-> 0]
    /\ batchHighest = [b \in Batches |-> 0]
    /\ batchIds = [b \in Batches |-> {}]
    /\ headManifest = "M0" /\ headLatestBatch = "None"
    /\ headHighest = 1 /\ headOrdinal = 0
    /\ headTransition = "None"
    /\ checkpointIds = CheckpointIds /\ suffixIds = {}
    /\ liveIds = CheckpointIds
    /\ capturedCheckpoint = {} /\ capturedSuffix = {}
    /\ receipt = "AppendReceipt" /\ result = "None"
    /\ phase = "CheckpointOnly" /\ oldWriterFenced = FALSE
    /\ recoveredIds = {} /\ cancelledAfterHead = FALSE
    /\ rivalRejected = FALSE
    /\ batchPuts = 0 /\ manifestPuts = 0 /\ headPuts = 0
    /\ lastAction = "Init"

CommitSuffixGroup ==
    /\ phase = "CheckpointOnly"
    /\ storedBatches' = {"B1"} /\ confirmedBatches' = {"B1"}
    /\ batchFirst' = [batchFirst EXCEPT !["B1"] = 2]
    /\ batchHighest' = [batchHighest EXCEPT !["B1"] = 3]
    /\ batchIds' = [batchIds EXCEPT !["B1"] = SuffixIds]
    /\ headLatestBatch' = "B1" /\ headHighest' = 3
    /\ suffixIds' = SuffixIds /\ liveIds' = LedgerIds
    /\ phase' = "SuffixCommitted" /\ lastAction' = "CommitSuffixGroup"
    /\ UNCHANGED <<storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestReplayBoundary, manifestLedger,
        headManifest, headOrdinal, headTransition,
        checkpointIds, capturedCheckpoint, capturedSuffix, receipt, result,
        oldWriterFenced, recoveredIds, cancelledAfterHead, rivalRejected,
        batchPuts, manifestPuts, headPuts>>

SnapshotPartition ==
    /\ phase = "SuffixCommitted"
    /\ checkpointIds = CheckpointIds /\ suffixIds = SuffixIds
    /\ checkpointIds \cap suffixIds = {}
    /\ checkpointIds \union suffixIds =
         manifestLedger[headManifest] \union batchIds[headLatestBatch]
    /\ capturedCheckpoint' = checkpointIds
    /\ capturedSuffix' = suffixIds
    /\ phase' = "PartitionCaptured" /\ lastAction' = "SnapshotPartition"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        receipt, result, oldWriterFenced, recoveredIds, cancelledAfterHead,
        rivalRejected, batchPuts, manifestPuts, headPuts>>

BeginFamilyAppend ==
    /\ phase = "PartitionCaptured"
    /\ phase' = "AppendBegun" /\ lastAction' = "BeginFamilyAppend"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, result, oldWriterFenced,
        recoveredIds, cancelledAfterHead, rivalRejected, batchPuts,
        manifestPuts, headPuts>>

StoreAppendManifest ==
    /\ phase = "AppendBegun"
    /\ storedManifests' = storedManifests \union {"M1"}
    /\ manifestPrevious' = [manifestPrevious EXCEPT !["M1"] = "M0"]
    /\ manifestRegistry' =
         [manifestRegistry EXCEPT !["M1"] = Families]
    /\ manifestReplayBoundary' =
         [manifestReplayBoundary EXCEPT !["M1"] = 1]
    /\ manifestLedger' = [manifestLedger EXCEPT !["M1"] = CheckpointIds]
    /\ manifestPuts' = manifestPuts + 1
    /\ phase' = "ManifestStored" /\ lastAction' = "StoreAppendManifest"
    /\ UNCHANGED <<confirmedManifests, storedBatches, confirmedBatches,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, result, oldWriterFenced,
        recoveredIds, cancelledAfterHead, rivalRejected, batchPuts, headPuts>>

ConfirmAppendManifest ==
    /\ phase = "ManifestStored"
    /\ confirmedManifests' = confirmedManifests \union {"M1"}
    /\ phase' = "Ready" /\ lastAction' = "ConfirmAppendManifest"
    /\ UNCHANGED <<storedManifests, storedBatches, confirmedBatches,
        manifestPrevious, manifestRegistry, manifestReplayBoundary,
        manifestLedger, batchFirst, batchHighest,
        batchIds, headManifest, headLatestBatch, headHighest, headOrdinal,
        headTransition,
        checkpointIds, suffixIds, liveIds, capturedCheckpoint, capturedSuffix,
        receipt, result, oldWriterFenced, recoveredIds, cancelledAfterHead,
        rivalRejected, batchPuts, manifestPuts, headPuts>>

LoseAcceptedManifestResponse ==
    /\ phase = "ManifestStored" /\ "M1" \in storedManifests
    /\ phase' = "ManifestUnknown" /\ result' = "Unknown"
    /\ oldWriterFenced' = TRUE
    /\ lastAction' = "LoseAcceptedManifestResponse"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest, headOrdinal, headTransition, checkpointIds, suffixIds,
        liveIds, capturedCheckpoint, capturedSuffix, receipt, recoveredIds,
        cancelledAfterHead, rivalRejected, batchPuts, manifestPuts, headPuts>>

ResolveManifestByRead ==
    /\ phase = "ManifestUnknown" /\ "M1" \in storedManifests
    /\ confirmedManifests' = confirmedManifests \union {"M1"}
    /\ phase' = "Ready" /\ result' = "None"
    /\ lastAction' = "ResolveManifestByRead"
    /\ UNCHANGED <<storedManifests, storedBatches, confirmedBatches,
        manifestPrevious, manifestRegistry, manifestReplayBoundary,
        manifestLedger, batchFirst, batchHighest, batchIds, headManifest,
        headLatestBatch, headHighest, headOrdinal, headTransition,
        checkpointIds, suffixIds, liveIds, capturedCheckpoint, capturedSuffix,
        receipt, oldWriterFenced, recoveredIds, cancelledAfterHead,
        rivalRejected, batchPuts, manifestPuts, headPuts>>

PublishAppendHead ==
    /\ phase = "Ready" /\ "M1" \in confirmedManifests
    /\ headManifest' = "M1" /\ headLatestBatch' = "B1"
    /\ headHighest' = 3
    /\ headOrdinal' = headOrdinal + 1
    /\ headTransition' = receipt
    /\ oldWriterFenced' = TRUE
    /\ headPuts' = headPuts + 1
    /\ phase' = "HeadConfirmed" /\ result' = "Committed"
    /\ lastAction' = "PublishAppendHead"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, recoveredIds,
        cancelledAfterHead, rivalRejected, batchPuts, manifestPuts>>

LoseAcceptedHeadResponse ==
    /\ phase = "Ready" /\ "M1" \in confirmedManifests
    /\ headManifest' = "M1" /\ headLatestBatch' = "B1"
    /\ headHighest' = 3
    /\ headOrdinal' = headOrdinal + 1
    /\ headTransition' = receipt
    /\ oldWriterFenced' = TRUE
    /\ headPuts' = headPuts + 1
    /\ phase' = "Unknown" /\ result' = "Unknown"
    /\ lastAction' = "LoseAcceptedHeadResponse"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, recoveredIds,
        cancelledAfterHead, rivalRejected, batchPuts, manifestPuts>>

ObserveHeadPreconditionFailure ==
    /\ phase = "Ready"
    /\ phase' = "Rejected" /\ result' = "Rejected"
    /\ oldWriterFenced' = TRUE
    /\ lastAction' = "ObserveHeadPreconditionFailure"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, recoveredIds,
        cancelledAfterHead, rivalRejected, batchPuts, manifestPuts, headPuts>>

ExternalPublishRival ==
    /\ phase = "Ready"
    /\ storedManifests' = storedManifests \union {"MR"}
    /\ confirmedManifests' = confirmedManifests \union {"MR"}
    /\ manifestPrevious' = [manifestPrevious EXCEPT !["MR"] = "M0"]
    /\ manifestRegistry' = [manifestRegistry EXCEPT !["MR"] = Families]
    /\ manifestReplayBoundary' =
         [manifestReplayBoundary EXCEPT !["MR"] = 1]
    /\ manifestLedger' = [manifestLedger EXCEPT !["MR"] = CheckpointIds]
    /\ headManifest' = "MR" /\ headLatestBatch' = "B1"
    /\ headHighest' = 3
    /\ headOrdinal' = headOrdinal + 1
    /\ headTransition' = "RivalReceipt"
    /\ oldWriterFenced' = TRUE
    /\ phase' = "UnknownRival" /\ result' = "Unknown"
    /\ lastAction' = "ExternalPublishRival"
    /\ UNCHANGED <<storedBatches, confirmedBatches, batchFirst,
        batchHighest, batchIds, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, recoveredIds,
        cancelledAfterHead, rivalRejected, batchPuts, manifestPuts, headPuts>>

ResolveCommitted ==
    /\ phase = "Unknown" /\ headTransition = receipt
    /\ phase' = "HeadConfirmed" /\ result' = "Committed"
    /\ lastAction' = "ResolveCommitted"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, oldWriterFenced,
        recoveredIds, cancelledAfterHead, rivalRejected, batchPuts,
        manifestPuts, headPuts>>

ResolveRejected ==
    /\ phase = "UnknownRival" /\ headTransition # receipt
    /\ phase' = "Rejected" /\ result' = "Rejected"
    /\ rivalRejected' = TRUE /\ lastAction' = "ResolveRejected"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, oldWriterFenced,
        recoveredIds, cancelledAfterHead, batchPuts, manifestPuts, headPuts>>

CancelAfterHead ==
    /\ phase = "HeadConfirmed"
    /\ phase' = "Cancelled" /\ result' = "LocalActivationFailed"
    /\ cancelledAfterHead' = TRUE /\ lastAction' = "CancelAfterHead"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, oldWriterFenced,
        recoveredIds, rivalRejected, batchPuts, manifestPuts, headPuts>>

FailLocalActivation ==
    /\ phase = "HeadConfirmed"
    /\ phase' = "LocalFailed" /\ result' = "LocalActivationFailed"
    /\ lastAction' = "FailLocalActivation"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, oldWriterFenced,
        recoveredIds, cancelledAfterHead, rivalRejected, batchPuts,
        manifestPuts, headPuts>>

RecoverActivation ==
    /\ phase \in {"HeadConfirmed", "Cancelled", "LocalFailed"}
    /\ headTransition = receipt /\ oldWriterFenced
    /\ recoveredIds' = capturedCheckpoint \union capturedSuffix
    /\ phase' = "Recovered" /\ result' = "Committed"
    /\ lastAction' = "RecoverActivation"
    /\ UNCHANGED <<storedManifests, confirmedManifests, storedBatches,
        confirmedBatches, manifestPrevious, manifestRegistry,
        manifestReplayBoundary, manifestLedger,
        batchFirst, batchHighest, batchIds, headManifest, headLatestBatch,
        headHighest,
        headOrdinal, headTransition, checkpointIds, suffixIds, liveIds,
        capturedCheckpoint, capturedSuffix, receipt, oldWriterFenced,
        cancelledAfterHead, rivalRejected, batchPuts, manifestPuts, headPuts>>

Next ==
    \/ CommitSuffixGroup \/ SnapshotPartition
    \/ BeginFamilyAppend \/ StoreAppendManifest \/ ConfirmAppendManifest
    \/ LoseAcceptedManifestResponse \/ ResolveManifestByRead
    \/ PublishAppendHead \/ LoseAcceptedHeadResponse
    \/ ObserveHeadPreconditionFailure \/ ExternalPublishRival
    \/ ResolveCommitted \/ ResolveRejected \/ CancelAfterHead
    \/ FailLocalActivation \/ RecoverActivation

TypeOK ==
    /\ storedManifests \subseteq Manifests
    /\ confirmedManifests \subseteq Manifests
    /\ storedBatches \subseteq Batches /\ confirmedBatches \subseteq Batches
    /\ manifestPrevious \in [Manifests -> {"None"} \union Manifests]
    /\ manifestRegistry \in [Manifests -> SUBSET Families]
    /\ manifestReplayBoundary \in [Manifests -> 0 .. 3]
    /\ manifestLedger \in [Manifests -> SUBSET LedgerIds]
    /\ batchFirst \in [Batches -> 0 .. 3]
    /\ batchHighest \in [Batches -> 0 .. 3]
    /\ batchIds \in [Batches -> SUBSET LedgerIds]
    /\ headManifest \in Manifests
    /\ headLatestBatch \in {"None"} \union Batches
    /\ headHighest \in 1 .. 3
    /\ headOrdinal \in Nat /\ headTransition \in {"None"} \union Receipts
    /\ checkpointIds \subseteq LedgerIds /\ suffixIds \subseteq LedgerIds
    /\ liveIds \subseteq LedgerIds
    /\ capturedCheckpoint \subseteq LedgerIds
    /\ capturedSuffix \subseteq LedgerIds
    /\ receipt = "AppendReceipt" /\ result \in Results /\ phase \in Phases
    /\ oldWriterFenced \in BOOLEAN /\ recoveredIds \subseteq LedgerIds
    /\ cancelledAfterHead \in BOOLEAN /\ rivalRejected \in BOOLEAN
    /\ batchPuts \in 0 .. 0 /\ manifestPuts \in 0 .. 1
    /\ headPuts \in 0 .. 1 /\ lastAction \in ActionNames

ConfirmedBytesStored ==
    /\ confirmedManifests \subseteq storedManifests
    /\ confirmedBatches \subseteq storedBatches

RegistryAppendIsExact ==
    /\ manifestPrevious["M0"] = "None"
    /\ manifestRegistry["M0"] = {"Existing"}
    /\ manifestReplayBoundary["M0"] = 1
    /\ manifestLedger["M0"] = CheckpointIds
    /\ ("M1" \in storedManifests =>
          /\ manifestPrevious["M1"] = "M0"
          /\ manifestRegistry["M1"] = Families
          /\ manifestReplayBoundary["M1"] = 1
          /\ manifestLedger["M1"] = CheckpointIds)

ExactPartition ==
    phase \notin {"PartitionCaptured", "AppendBegun", "ManifestStored",
        "ManifestUnknown", "Ready", "HeadConfirmed", "Unknown",
        "UnknownRival", "Cancelled", "LocalFailed", "Recovered"} \/
    /\ capturedCheckpoint = CheckpointIds
    /\ capturedSuffix = SuffixIds
    /\ capturedCheckpoint \cap capturedSuffix = {}
    /\ capturedCheckpoint \union capturedSuffix = LedgerIds

SuffixGroupIsWhole == suffixIds = {} \/ suffixIds = SuffixIds

AuthenticatedLiveSuffix ==
    \/ /\ headLatestBatch = "None"
       /\ headHighest = manifestReplayBoundary[headManifest]
       /\ suffixIds = {}
    \/ /\ headLatestBatch = "B1"
       /\ "B1" \in confirmedBatches
       /\ batchFirst["B1"] = manifestReplayBoundary[headManifest] + 1
       /\ batchHighest["B1"] = headHighest
       /\ batchIds["B1"] = suffixIds
       /\ suffixIds = SuffixIds
       /\ liveIds = manifestLedger[headManifest] \union batchIds["B1"]

HeadAuthorityIsConfirmed ==
    /\ headManifest \in confirmedManifests
    /\ (headManifest \in {"M1", "MR"} =>
          /\ headHighest = 3
          /\ manifestReplayBoundary[headManifest] = 1
          /\ manifestLedger[headManifest] = CheckpointIds
          /\ headLatestBatch = "B1"
          /\ "B1" \in confirmedBatches
          /\ batchFirst["B1"] = manifestReplayBoundary[headManifest] + 1
          /\ batchHighest["B1"] = headHighest
          /\ batchIds["B1"] = SuffixIds)

ConfirmedHeadFencesImmediately ==
    headManifest = "M0" \/ oldWriterFenced

ReceiptConclusionIsSound ==
    /\ (result = "Committed" => headTransition = receipt)
    /\ (rivalRejected => headTransition # receipt /\ result = "Rejected")
    /\ (result = "LocalActivationFailed" => headTransition = receipt)
    /\ (lastAction = "ObserveHeadPreconditionFailure" =>
          result = "Rejected" /\ headTransition # receipt)

FailurePreservesDurableAuthority ==
    phase \notin {"Cancelled", "LocalFailed"} \/
    /\ headManifest = "M1" /\ headHighest = 3
    /\ manifestLedger[headManifest] = CheckpointIds
    /\ headLatestBatch = "B1" /\ batchIds["B1"] = SuffixIds
    /\ oldWriterFenced

RecoveryIsComplete ==
    phase # "Recovered" \/
    /\ recoveredIds = capturedCheckpoint \union capturedSuffix
    /\ recoveredIds = LedgerIds /\ headTransition = receipt

WriterGeometry == batchPuts = 0 /\ manifestPuts <= 1 /\ headPuts <= 1

CapturedPartitionIsExact == ExactPartition

ConfirmedHeadImpliesFenced ==
    headManifest = "M0" \/ oldWriterFenced

ResolutionDoesNotReplay ==
    /\ (lastAction \in {"ResolveCommitted", "RecoverActivation"} =>
          /\ batchPuts = 0 /\ manifestPuts = 1 /\ headPuts = 1)
    /\ (lastAction = "ResolveRejected" =>
          /\ batchPuts = 0 /\ manifestPuts = 1 /\ headPuts = 0)

ManifestResolutionDoesNotReplay ==
    lastAction # "ResolveManifestByRead" \/
    /\ batchPuts = 0
    /\ manifestPuts = 1
    /\ headPuts = 0

RivalCannotResolveCommitted ==
    headTransition = receipt \/ result # "Committed"

Safety == TypeOK /\ ConfirmedBytesStored /\ RegistryAppendIsExact /\
    ExactPartition /\ SuffixGroupIsWhole /\ AuthenticatedLiveSuffix /\
    HeadAuthorityIsConfirmed /\
    ConfirmedHeadFencesImmediately /\ ReceiptConclusionIsSound /\
    FailurePreservesDurableAuthority /\ RecoveryIsComplete /\ WriterGeometry /\
    ResolutionDoesNotReplay /\ ManifestResolutionDoesNotReplay /\
    RivalCannotResolveCommitted

HarnessState ==
    [action |-> lastAction, phase |-> phase, result |-> result,
     receipt |-> receipt,
     head |-> [manifest |-> headManifest, latest_batch |-> headLatestBatch,
               highest |-> headHighest, ordinal |-> headOrdinal,
               transition |-> headTransition],
     authority |-> [checkpoint |-> checkpointIds, suffix |-> suffixIds,
                    captured_checkpoint |-> capturedCheckpoint,
                    captured_suffix |-> capturedSuffix, live |-> liveIds,
                    recovered |-> recoveredIds],
     ownership |-> [fenced |-> oldWriterFenced,
                    cancelled_after_head |-> cancelledAfterHead,
                    rival_rejected |-> rivalRejected],
     writes |-> [batch |-> batchPuts, manifest |-> manifestPuts,
                 head |-> headPuts]]

HarnessAlias == CheckedWitnessAlias(lastAction, HarnessState)

Spec == Init /\ [][Next]_vars

=============================================================================
