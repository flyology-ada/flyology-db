---------- MODULE LiveSuffixRegistryPublicationSafetyProof ----------
EXTENDS Naturals

(***************************************************************************
This arbitrary-domain kernel proves the ownership and authority cut for a
registry append over an authenticated checkpoint/live-suffix partition. A
conclusive successor HEAD fences the old writer in the same action. Later
cancellation and local activation failure preserve that durable authority;
same-receipt resolution and recovery perform no provider write and install the
complete partition. A rival HEAD can only reject the submitted receipt.

Concrete history decoding, partition computation, byte authentication,
provider behavior, capacities, progress, Ada, and refinement remain outside
this proof. The SPARK-selected identity-partition policy owns the concrete
cardinality check used by Ada.
***************************************************************************)

CONSTANTS Identities, Checkpoint, Suffix, Ledger, Receipt, RivalReceipt

ConstantsOK ==
    /\ Identities # {}
    /\ Checkpoint \subseteq Identities /\ Suffix \subseteq Identities
    /\ Checkpoint \cap Suffix = {}
    /\ Checkpoint \union Suffix = Ledger
    /\ Ledger \subseteq Identities
    /\ Receipt # RivalReceipt

ASSUME ConstantsOK

Phases == {"Idle", "Captured", "ManifestUnknown", "ManifestReady",
    "Confirmed", "Unknown", "Cancelled", "LocalFailed", "Recovered",
    "RivalUnknown", "Rejected"}
Results == {"None", "Unknown", "Committed", "LocalActivationFailed",
    "Rejected"}
Transitions == {"None", Receipt, RivalReceipt}

VARIABLES phase, capturedCheckpoint, capturedSuffix, headTransition,
    oldWriterFenced, result, recovered, manifestWrites, headWrites,
    batchWrites, rivalRejected

vars == <<phase, capturedCheckpoint, capturedSuffix, headTransition,
    oldWriterFenced, result, recovered, manifestWrites, headWrites,
    batchWrites, rivalRejected>>

Init ==
    /\ phase = "Idle"
    /\ capturedCheckpoint = {} /\ capturedSuffix = {}
    /\ headTransition = "None" /\ oldWriterFenced = FALSE
    /\ result = "None" /\ recovered = {}
    /\ manifestWrites = 0 /\ headWrites = 0 /\ batchWrites = 0
    /\ rivalRejected = FALSE

Capture ==
    /\ phase = "Idle"
    /\ capturedCheckpoint' = Checkpoint /\ capturedSuffix' = Suffix
    /\ phase' = "Captured"
    /\ UNCHANGED <<headTransition, oldWriterFenced, result, recovered,
        manifestWrites, headWrites, batchWrites, rivalRejected>>

LoseManifestAccepted ==
    /\ phase = "Captured"
    /\ phase' = "ManifestUnknown" /\ result' = "Unknown"
    /\ oldWriterFenced' = TRUE
    /\ manifestWrites' = 1 /\ headWrites' = 0
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, headTransition,
        recovered, batchWrites, rivalRejected>>

ResolveManifestRead ==
    /\ phase = "ManifestUnknown"
    /\ phase' = "ManifestReady" /\ result' = "None"
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, headTransition,
        oldWriterFenced, recovered, manifestWrites, headWrites, batchWrites,
        rivalRejected>>

Publish ==
    /\ phase \in {"Captured", "ManifestReady"}
    /\ headTransition' = Receipt /\ oldWriterFenced' = TRUE
    /\ phase' = "Confirmed" /\ result' = "Committed"
    /\ manifestWrites' = 1 /\ headWrites' = 1
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, recovered,
        batchWrites, rivalRejected>>

LoseAccepted ==
    /\ phase \in {"Captured", "ManifestReady"}
    /\ headTransition' = Receipt /\ oldWriterFenced' = TRUE
    /\ phase' = "Unknown" /\ result' = "Unknown"
    /\ manifestWrites' = 1 /\ headWrites' = 1
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, recovered,
        batchWrites, rivalRejected>>

ResolveCommitted ==
    /\ phase = "Unknown" /\ headTransition = Receipt
    /\ phase' = "Confirmed" /\ result' = "Committed"
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, headTransition,
        oldWriterFenced, recovered, manifestWrites, headWrites, batchWrites,
        rivalRejected>>

Cancel ==
    /\ phase = "Confirmed" /\ headTransition = Receipt
    /\ phase' = "Cancelled" /\ result' = "LocalActivationFailed"
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, headTransition,
        oldWriterFenced, recovered, manifestWrites, headWrites, batchWrites,
        rivalRejected>>

Fail ==
    /\ phase = "Confirmed" /\ headTransition = Receipt
    /\ phase' = "LocalFailed" /\ result' = "LocalActivationFailed"
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, headTransition,
        oldWriterFenced, recovered, manifestWrites, headWrites, batchWrites,
        rivalRejected>>

Recover ==
    /\ phase \in {"Confirmed", "Cancelled", "LocalFailed"}
    /\ headTransition = Receipt /\ oldWriterFenced
    /\ recovered' = capturedCheckpoint \union capturedSuffix
    /\ phase' = "Recovered" /\ result' = "Committed"
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, headTransition,
        oldWriterFenced, manifestWrites, headWrites, batchWrites,
        rivalRejected>>

PublishRival ==
    /\ phase \in {"Captured", "ManifestReady"}
    /\ headTransition' = RivalReceipt /\ oldWriterFenced' = TRUE
    /\ phase' = "RivalUnknown" /\ result' = "Unknown"
    /\ manifestWrites' = 1 /\ headWrites' = 0
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, recovered,
        batchWrites, rivalRejected>>

RejectRival ==
    /\ phase = "RivalUnknown" /\ headTransition = RivalReceipt
    /\ phase' = "Rejected" /\ result' = "Rejected"
    /\ rivalRejected' = TRUE
    /\ UNCHANGED <<capturedCheckpoint, capturedSuffix, headTransition,
        oldWriterFenced, recovered, manifestWrites, headWrites, batchWrites>>

TypeOK ==
    /\ phase \in Phases
    /\ capturedCheckpoint \subseteq Identities
    /\ capturedSuffix \subseteq Identities
    /\ headTransition \in Transitions /\ oldWriterFenced \in BOOLEAN
    /\ result \in Results /\ recovered \subseteq Identities
    /\ manifestWrites \in 0 .. 1 /\ headWrites \in 0 .. 1
    /\ batchWrites = 0 /\ rivalRejected \in BOOLEAN

PartitionExact ==
    phase \in {"Idle", "Rejected"} \/
    /\ capturedCheckpoint = Checkpoint /\ capturedSuffix = Suffix
    /\ capturedCheckpoint \cap capturedSuffix = {}
    /\ capturedCheckpoint \union capturedSuffix = Ledger

ConfirmedHeadFenced ==
    headTransition = "None" \/ oldWriterFenced

ConclusionSound ==
    /\ (result = "Committed" => headTransition = Receipt)
    /\ (result = "LocalActivationFailed" => headTransition = Receipt)
    /\ (rivalRejected =>
          /\ phase = "Rejected"
          /\ headTransition = RivalReceipt /\ result = "Rejected")

RecoveryComplete ==
    phase # "Recovered" \/ recovered = Ledger

NoReplay ==
    /\ batchWrites = 0 /\ manifestWrites <= 1 /\ headWrites <= 1
    /\ (phase \in {"ManifestUnknown", "ManifestReady"} =>
          /\ manifestWrites = 1 /\ headWrites = 0 /\ batchWrites = 0)
    /\ (phase \in {"ManifestUnknown", "ManifestReady", "RivalUnknown",
          "Rejected"} =>
          /\ batchWrites = 0 /\ manifestWrites = 1 /\ headWrites = 0)
    /\ (phase \in {"Unknown", "Confirmed", "Cancelled", "LocalFailed",
          "Recovered"} =>
          /\ batchWrites = 0 /\ manifestWrites = 1 /\ headWrites = 1)
    /\ (phase = "Recovered" => manifestWrites = 1 /\ headWrites = 1)
    /\ (rivalRejected => manifestWrites = 1 /\ headWrites = 0)

Safety == TypeOK /\ PartitionExact /\ ConfirmedHeadFenced /\
    ConclusionSound /\ RecoveryComplete /\ NoReplay

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1> QED BY DEF Init, Safety, TypeOK, PartitionExact, ConfirmedHeadFenced,
    ConclusionSound, RecoveryComplete, NoReplay, Phases, Results,
    Transitions, ConstantsOK

THEOREM CapturePreservesSafety == Safety /\ Capture => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Capture, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM LoseManifestAcceptedPreservesSafety ==
    Safety /\ LoseManifestAccepted => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, LoseManifestAccepted, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM ResolveManifestReadPreservesSafety ==
    Safety /\ ResolveManifestRead => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, ResolveManifestRead, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM PublishPreservesSafety == Safety /\ Publish => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Publish, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM LoseAcceptedPreservesSafety == Safety /\ LoseAccepted => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, LoseAccepted, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM ResolveCommittedPreservesSafety ==
    Safety /\ ResolveCommitted => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, ResolveCommitted, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM CancelPreservesSafety == Safety /\ Cancel => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Cancel, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM FailPreservesSafety == Safety /\ Fail => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Fail, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM RecoverPreservesSafety == Safety /\ Recover => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Recover, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM PublishRivalPreservesSafety == Safety /\ PublishRival => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, PublishRival, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM RejectRivalPreservesSafety == Safety /\ RejectRival => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, RejectRival, TypeOK, PartitionExact,
    ConfirmedHeadFenced, ConclusionSound, RecoveryComplete, NoReplay,
    Phases, Results, Transitions, ConstantsOK

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, PartitionExact, ConfirmedHeadFenced,
    ConclusionSound, RecoveryComplete, NoReplay, vars

=============================================================================
