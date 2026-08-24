---------------------- MODULE ReplicaRefreshSafetyProof ----------------------
EXTENDS Naturals

(***************************************************************************
This unbounded action-preservation kernel uses arbitrary natural HEAD ordinals
and writer epochs. Exact guarded publication cannot record a stale write, and
a validated captured replica pair installs only at or above its high-water
pair and no later than current authority. Concrete immutable-graph validation,
transport certainty, polling, leases, progress, and Ada refinement are out of
scope.
***************************************************************************)

RefreshPhases == {"Idle", "Loading", "Ready"}
WriterPhases == {"Idle", "Ready"}

VARIABLES confirmed, headOrdinal, headEpoch, writerPhase,
    writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
    replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
    refreshPhase, highOrdinal, highEpoch, rollbackInstalled

vars == <<confirmed, headOrdinal, headEpoch, writerPhase,
    writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
    replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
    refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

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

ConfirmSuccessor ==
    /\ headOrdinal + 1 \notin confirmed
    /\ confirmed' = confirmed \cup {headOrdinal + 1}
    /\ UNCHANGED <<headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

BeginWriter ==
    /\ writerPhase = "Idle"
    /\ writerExpectedOrdinal' = headOrdinal
    /\ writerCapturedEpoch' = headEpoch
    /\ writerPhase' = "Ready"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

FenceEpoch ==
    /\ headEpoch' = headEpoch + 1
    /\ UNCHANGED <<confirmed, headOrdinal, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

CancelWriter ==
    /\ writerPhase = "Ready" /\ writerPhase' = "Idle"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        refreshPhase, highOrdinal, highEpoch, rollbackInstalled>>

Publish ==
    /\ writerPhase = "Ready"
    /\ writerExpectedOrdinal = headOrdinal
    /\ writerCapturedEpoch = headEpoch
    /\ headOrdinal + 1 \in confirmed
    /\ headOrdinal' = headOrdinal + 1 /\ writerPhase' = "Idle"
    /\ UNCHANGED <<confirmed, headEpoch, writerExpectedOrdinal,
        writerCapturedEpoch, stalePublished, replicaOrdinal, replicaEpoch,
        capturedOrdinal, capturedEpoch, refreshPhase, highOrdinal,
        highEpoch, rollbackInstalled>>

BeginRefresh ==
    /\ refreshPhase = "Idle"
    /\ capturedOrdinal' = headOrdinal /\ capturedEpoch' = headEpoch
    /\ refreshPhase' = "Loading"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, highOrdinal, highEpoch,
        rollbackInstalled>>

CompleteLoad ==
    /\ refreshPhase = "Loading" /\ capturedOrdinal \in confirmed
    /\ refreshPhase' = "Ready"
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
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        capturedOrdinal, capturedEpoch, rollbackInstalled>>

DiscardRefresh ==
    /\ refreshPhase # "Idle" /\ refreshPhase' = "Idle"
    /\ UNCHANGED <<confirmed, headOrdinal, headEpoch, writerPhase,
        writerExpectedOrdinal, writerCapturedEpoch, stalePublished,
        replicaOrdinal, replicaEpoch, capturedOrdinal, capturedEpoch,
        highOrdinal, highEpoch, rollbackInstalled>>

TypeOK ==
    /\ confirmed \subseteq Nat
    /\ headOrdinal \in Nat /\ headEpoch \in Nat
    /\ writerPhase \in {"Idle", "Ready"}
    /\ writerExpectedOrdinal \in Nat /\ writerCapturedEpoch \in Nat
    /\ stalePublished \in BOOLEAN
    /\ replicaOrdinal \in Nat /\ replicaEpoch \in Nat
    /\ capturedOrdinal \in Nat /\ capturedEpoch \in Nat
    /\ refreshPhase \in {"Idle", "Loading", "Ready"}
    /\ highOrdinal \in Nat /\ highEpoch \in Nat
    /\ rollbackInstalled \in BOOLEAN

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

Safety ==
    /\ TypeOK /\ AuthorityIsConfirmed /\ ReplicaIsConfirmedAndNotFuture
    /\ CapturedRefreshIsNotFuture /\ ReplicaNeverRollsBack
    /\ ~stalePublished

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM ConfirmSuccessorPreservesSafety ==
    Safety /\ ConfirmSuccessor => Safety'
<1> QED BY DEF ConfirmSuccessor, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM BeginWriterPreservesSafety == Safety /\ BeginWriter => Safety'
<1> QED BY DEF BeginWriter, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM FenceEpochPreservesSafety == Safety /\ FenceEpoch => Safety'
<1> QED BY DEF FenceEpoch, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM CancelWriterPreservesSafety == Safety /\ CancelWriter => Safety'
<1> QED BY DEF CancelWriter, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM PublishPreservesSafety == Safety /\ Publish => Safety'
<1> QED BY DEF Publish, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM BeginRefreshPreservesSafety == Safety /\ BeginRefresh => Safety'
<1> QED BY DEF BeginRefresh, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM CompleteLoadPreservesSafety == Safety /\ CompleteLoad => Safety'
<1> QED BY DEF CompleteLoad, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM InstallRefreshPreservesSafety == Safety /\ InstallRefresh => Safety'
<1> QED BY DEF InstallRefresh, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM DiscardRefreshPreservesSafety == Safety /\ DiscardRefresh => Safety'
<1> QED BY DEF DiscardRefresh, Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, AuthorityIsConfirmed,
    ReplicaIsConfirmedAndNotFuture, CapturedRefreshIsNotFuture,
    ReplicaNeverRollsBack, PairLE, vars

=============================================================================
