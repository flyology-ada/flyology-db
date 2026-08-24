---------------------------- MODULE ReplicaRefresh ----------------------------
EXTENDS Naturals, TLC

(***************************************************************************
This finite model freezes monotonic read-only replica refresh and exact writer
fencing. A refresh captures one HEAD ordinal/epoch pair, validates the exact
confirmed immutable graph for that ordinal, and installs only at or above the
replica high-water pair. A writer publishes only from its exact captured HEAD
ordinal and epoch. Bounds 2 and 1 are qualification geometry, not persisted
limits, lease durations, polling policy, or public defaults.
***************************************************************************)

MaximumOrdinal == 2
MaximumEpoch == 1
Ordinals == 0 .. MaximumOrdinal
Epochs == 0 .. MaximumEpoch
RefreshPhases == {"Idle", "Loading", "Ready"}
WriterPhases == {"Idle", "Ready"}

ActionNames == {
    "Init", "ConfirmSuccessor", "BeginWriter", "FenceEpoch",
    "CancelWriter", "Publish", "BeginRefresh", "CompleteLoad",
    "InstallRefresh", "DiscardRefresh"
}

VARIABLES confirmed, headOrdinal, headEpoch, writerPhase,
    writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
    replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
    refreshPhase, highOrdinal, highEpoch, rollbackInstalled, lastAction

vars == <<confirmed, headOrdinal, headEpoch, writerPhase,
    writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
    replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
    refreshPhase, highOrdinal, highEpoch, rollbackInstalled, lastAction>>

PairLE(leftOrdinal, leftEpoch, rightOrdinal, rightEpoch) ==
    leftOrdinal < rightOrdinal
    \/ (leftOrdinal = rightOrdinal /\ leftEpoch <= rightEpoch)

Init ==
    /\ confirmed = {0} /\ headOrdinal = 0 /\ headEpoch = 0
    /\ writerPhase = "Idle"
    /\ writerExpectedOrdinal = 0 /\ writerCapturedEpoch = 0
    /\ stalePublished = FALSE
    /\ replicaOrdinal = 0 /\ replicaEpoch = 0
    /\ capturedOrdinal = 0 /\ capturedEpoch = 0
    /\ refreshPhase = "Idle"
    /\ highOrdinal = 0 /\ highEpoch = 0 /\ rollbackInstalled = FALSE
    /\ lastAction = "Init"

ConfirmSuccessor ==
    /\ headOrdinal < MaximumOrdinal
    /\ headOrdinal + 1 \notin confirmed
    /\ confirmed' = confirmed \cup {headOrdinal + 1}
    /\ lastAction' = "ConfirmSuccessor"
    /\ UNCHANGED <<headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

BeginWriter ==
    /\ writerPhase = "Idle"
    /\ writerExpectedOrdinal' = headOrdinal
    /\ writerCapturedEpoch' = headEpoch
    /\ writerPhase' = "Ready"
    /\ lastAction' = "BeginWriter"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

FenceEpoch ==
    /\ headEpoch < MaximumEpoch
    /\ headEpoch' = headEpoch + 1
    /\ lastAction' = "FenceEpoch"
    /\ UNCHANGED <<confirmed, headOrdinal, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

CancelWriter ==
    /\ writerPhase = "Ready"
    /\ writerPhase' = "Idle"
    /\ lastAction' = "CancelWriter"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

Publish ==
    /\ writerPhase = "Ready"
    /\ writerExpectedOrdinal = headOrdinal
    /\ writerCapturedEpoch = headEpoch
    /\ headOrdinal < MaximumOrdinal
    /\ headOrdinal + 1 \in confirmed
    /\ headOrdinal' = headOrdinal + 1
    /\ writerPhase' = "Idle"
    /\ lastAction' = "Publish"
    /\ UNCHANGED <<confirmed, headEpoch, writerExpectedOrdinal,
        writerCapturedEpoch, stalePublished, replicaOrdinal, replicaEpoch,
        capturedOrdinal, capturedEpoch, refreshPhase, highOrdinal,
        highEpoch, rollbackInstalled>>

BeginRefresh ==
    /\ refreshPhase = "Idle"
    /\ capturedOrdinal' = headOrdinal /\ capturedEpoch' = headEpoch
    /\ refreshPhase' = "Loading"
    /\ lastAction' = "BeginRefresh"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, highOrdinal, highEpoch,
        rollbackInstalled>>

CompleteLoad ==
    /\ refreshPhase = "Loading"
    /\ capturedOrdinal \in confirmed
    /\ refreshPhase' = "Ready"
    /\ lastAction' = "CompleteLoad"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        highOrdinal, highEpoch, rollbackInstalled>>

InstallRefresh ==
    /\ refreshPhase = "Ready"
    /\ PairLE(replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch)
    /\ PairLE(capturedOrdinal, capturedEpoch, headOrdinal, headEpoch)
    /\ replicaOrdinal' = capturedOrdinal /\ replicaEpoch' = capturedEpoch
    /\ highOrdinal' = capturedOrdinal /\ highEpoch' = capturedEpoch
    /\ refreshPhase' = "Idle"
    /\ lastAction' = "InstallRefresh"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        capturedOrdinal, capturedEpoch, rollbackInstalled>>

DiscardRefresh ==
    /\ refreshPhase # "Idle"
    /\ refreshPhase' = "Idle"
    /\ lastAction' = "DiscardRefresh"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        highOrdinal, highEpoch, rollbackInstalled>>

Next ==
    \/ ConfirmSuccessor \/ BeginWriter \/ FenceEpoch \/ CancelWriter
    \/ Publish \/ BeginRefresh \/ CompleteLoad \/ InstallRefresh
    \/ DiscardRefresh

TypeOK ==
    /\ confirmed \subseteq Ordinals
    /\ headOrdinal \in Ordinals /\ headEpoch \in Epochs
    /\ writerPhase \in WriterPhases
    /\ writerExpectedOrdinal \in Ordinals /\ writerCapturedEpoch \in Epochs
    /\ stalePublished \in BOOLEAN
    /\ replicaOrdinal \in Ordinals /\ replicaEpoch \in Epochs
    /\ capturedOrdinal \in Ordinals /\ capturedEpoch \in Epochs
    /\ refreshPhase \in RefreshPhases
    /\ highOrdinal \in Ordinals /\ highEpoch \in Epochs
    /\ rollbackInstalled \in BOOLEAN /\ lastAction \in ActionNames

AuthorityIsConfirmed == headOrdinal \in confirmed

ReplicaIsConfirmedAndNotFuture ==
    /\ replicaOrdinal \in confirmed
    /\ PairLE(replicaOrdinal, replicaEpoch, headOrdinal, headEpoch)

CapturedRefreshIsNotFuture == refreshPhase = "Idle" \/
    /\ capturedOrdinal \in confirmed
    /\ PairLE(capturedOrdinal, capturedEpoch, headOrdinal, headEpoch)

ReplicaNeverRollsBack ==
    /\ highOrdinal = replicaOrdinal /\ highEpoch = replicaEpoch
    /\ ~rollbackInstalled

NoStaleWriterPublication == ~stalePublished

Safety ==
    /\ TypeOK /\ AuthorityIsConfirmed /\ ReplicaIsConfirmedAndNotFuture
    /\ CapturedRefreshIsNotFuture /\ ReplicaNeverRollsBack
    /\ NoStaleWriterPublication

Spec == Init /\ [][Next]_vars

=============================================================================
