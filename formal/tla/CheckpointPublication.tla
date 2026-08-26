----------------------- MODULE CheckpointPublication -----------------------
EXTENDS FiniteSets, FlyologyHarness, Naturals, TLC

CONSTANTS
    M0, M1, R1, R2, F1, F2,
    T1, T2, T3, I1, I2, I3, IX,
    H0, H1, H2, HF, HL, HR,
    NoManifest, NoHeadId

Manifests == {M0, M1}
Runs == {R1, R2}
Families == {F1, F2}
Transactions == {T1, T2, T3}
Identities == {I1, I2, I3, IX}
HeadIds == {H0, H1, H2, HF, HL, HR}

FlushPhases == {
    "Idle", "Prepared", "ManifestStored", "Ready", "HeadAccepted",
    "HeadUnknown", "Success", "Rejected", "Backpressured"
}
RecoveryPhases == {"Idle", "Recovered", "Rejected"}
CapacityModes == {
    "Enough", "FamilyRunFull", "DatabaseRunFull", "IdentityFull"
}
ActionNames == {
    "Init", "ReserveFailedIdentity", "CommitPrefix",
    "FamilyRunCapacityBackpressure", "DatabaseRunCapacityBackpressure",
    "IdentityCapacityBackpressure", "BeginFlush", "StoreRun",
    "ConfirmRun", "StoreManifest", "ConfirmManifest", "PublishFlush",
    "LoseAcceptedFlushResponse", "LoseUnacceptedFlushResponse",
    "ObserveFlushSuccess", "ExternalCommitLater", "RivalTransition",
    "ResolveCommitted", "ResolveRejected",
    "ExternalAdvanceBeforeFlushPublication", "HideRun", "CorruptRunRead",
    "Crash", "Recover", "RejectRecovery"
}

FamilyConfig == [f \in Families |->
    IF f = F1
    THEN [maxKey |-> 4, maxValue |-> 16,
          memtableBytes |-> 32, memtableEntries |-> 2, maxL0Runs |-> 1]
    ELSE [maxKey |-> 8, maxValue |-> 32,
          memtableBytes |-> 64, memtableEntries |-> 2, maxL0Runs |-> 1]]

TxnIdentity == [t \in Transactions |->
    IF t = T1 THEN I1 ELSE IF t = T2 THEN I2 ELSE I3]
TxnFamily == [t \in Transactions |-> IF t = T2 THEN F2 ELSE F1]
RunFamily == [r \in Runs |-> IF r = R1 THEN F1 ELSE F2]
RunTransactions == [r \in Runs |-> IF r = R1 THEN {T1} ELSE {T2}]
AttemptRuns == {R1, R2}

PrefixTransactions(n) ==
    IF n = 0 THEN {}
    ELSE IF n = 1 THEN {T1}
    ELSE IF n = 2 THEN {T1, T2}
    ELSE {T1, T2, T3}

PrefixIdentities(n) == {TxnIdentity[t] : t \in PrefixTransactions(n)}
BoundaryIdentityAuthority(n) ==
    IF n = 0 THEN {} ELSE PrefixIdentities(n) \cup {IX}
FamilyPrefixTransactions(f, n) ==
    {t \in PrefixTransactions(n) : TxnFamily[t] = f}
CommitHeadId(n) == IF n = 1 THEN H1 ELSE H2

VARIABLES
    storedRuns,
    confirmedRuns,
    completeRuns,
    sortedRuns,
    readableRuns,
    corruptRuns,
    storedManifests,
    confirmedManifests,
    manifestPrevious,
    manifestRegistry,
    manifestRuns,
    manifestBoundary,
    manifestLedger,
    headManifest,
    headHighest,
    headOrdinal,
    headId,
    confirmedBatches,
    admittedIds,
    flushBoundary,
    flushExpectedOrdinal,
    flushExpectedId,
    flushAttemptOrdinal,
    flushAttemptId,
    flushPhase,
    flushWasUnknown,
    resolvedCommitted,
    resolvedRejected,
    capacityMode,
    localRuns,
    localManifests,
    localState,
    localIds,
    recoveryPhase,
    recoveredManifest,
    recoveredState,
    recoveredIds,
    replayedTransactions,
    crashObserved,
    stalePublicationObserved,
    lastAction

vars == <<
    storedRuns,
    confirmedRuns,
    completeRuns,
    sortedRuns,
    readableRuns,
    corruptRuns,
    storedManifests,
    confirmedManifests,
    manifestPrevious,
    manifestRegistry,
    manifestRuns,
    manifestBoundary,
    manifestLedger,
    headManifest,
    headHighest,
    headOrdinal,
    headId,
    confirmedBatches,
    admittedIds,
    flushBoundary,
    flushExpectedOrdinal,
    flushExpectedId,
    flushAttemptOrdinal,
    flushAttemptId,
    flushPhase,
    flushWasUnknown,
    resolvedCommitted,
    resolvedRejected,
    capacityMode,
    localRuns,
    localManifests,
    localState,
    localIds,
    recoveryPhase,
    recoveredManifest,
    recoveredState,
    recoveredIds,
    replayedTransactions,
    crashObserved,
    stalePublicationObserved,
    lastAction
>>

EmptyRunMap == [f \in Families |-> {}]
RootManifestRuns == EmptyRunMap
CheckpointManifestRuns ==
    [f \in Families |-> IF f = F1 THEN {R1} ELSE {R2}]

RunsNamedBy(m) == UNION {manifestRuns[m][f] : f \in Families}
RunState(rs) == UNION {RunTransactions[r] : r \in rs}
VisibleState == PrefixTransactions(headHighest)
ManifestReachable(m) ==
    m = headManifest
        \/ (headManifest = M1 /\ manifestPrevious[M1] = m)

RecoveryRuns == RunsNamedBy(headManifest)
RecoveryBoundary == manifestBoundary[headManifest]
RecoveryReplay ==
    PrefixTransactions(headHighest) \ PrefixTransactions(RecoveryBoundary)
RecoveryIdentityReplay ==
    PrefixIdentities(headHighest) \ PrefixIdentities(RecoveryBoundary)
AuthoritativeVisibleIds ==
    manifestLedger[headManifest] \cup RecoveryIdentityReplay

AllRecoveryRunsValid ==
    /\ RecoveryRuns \subseteq confirmedRuns
    /\ RecoveryRuns \subseteq completeRuns
    /\ RecoveryRuns \subseteq sortedRuns
    /\ RecoveryRuns \subseteq readableRuns
    /\ RecoveryRuns \cap corruptRuns = {}

PerFamilyRunCapacityAvailable == capacityMode # "FamilyRunFull"
DatabaseRunCapacityAvailable == capacityMode # "DatabaseRunFull"
RunCapacityAvailable ==
    PerFamilyRunCapacityAvailable /\ DatabaseRunCapacityAvailable
IdentityCapacityAvailable == capacityMode # "IdentityFull"
WriterEnabled == ~crashObserved

Init ==
    /\ capacityMode \in CapacityModes
    /\ storedRuns = {}
    /\ confirmedRuns = {}
    /\ completeRuns = {}
    /\ sortedRuns = {}
    /\ readableRuns = {}
    /\ corruptRuns = {}
    /\ storedManifests = {M0}
    /\ confirmedManifests = {M0}
    /\ manifestPrevious = [m \in Manifests |-> NoManifest]
    /\ manifestRegistry = [m \in Manifests |-> FamilyConfig]
    /\ manifestRuns = [m \in Manifests |-> EmptyRunMap]
    /\ manifestBoundary = [m \in Manifests |-> 0]
    /\ manifestLedger = [m \in Manifests |-> {}]
    /\ headManifest = M0
    /\ headHighest = 0
    /\ headOrdinal = 1
    /\ headId = H0
    /\ confirmedBatches = {}
    /\ admittedIds = {}
    /\ flushBoundary = 0
    /\ flushExpectedOrdinal = 0
    /\ flushExpectedId = NoHeadId
    /\ flushAttemptOrdinal = 0
    /\ flushAttemptId = NoHeadId
    /\ flushPhase = "Idle"
    /\ flushWasUnknown = FALSE
    /\ resolvedCommitted = FALSE
    /\ resolvedRejected = FALSE
    /\ localRuns = {}
    /\ localManifests = {M0}
    /\ localState = {}
    /\ localIds = {}
    /\ recoveryPhase = "Idle"
    /\ recoveredManifest = NoManifest
    /\ recoveredState = {}
    /\ recoveredIds = {}
    /\ replayedTransactions = {}
    /\ crashObserved = FALSE
    /\ stalePublicationObserved = FALSE
    /\ lastAction = "Init"

ReserveFailedIdentity ==
    /\ WriterEnabled
    /\ headHighest < 2
    /\ IX \notin admittedIds
    /\ admittedIds' = admittedIds \cup {IX}
    /\ localIds' = localIds \cup {IX}
    /\ lastAction' = "ReserveFailedIdentity"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, recoveryPhase, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

CommitPrefix ==
    /\ WriterEnabled
    /\ headHighest < 2
    /\ flushPhase = "Idle"
    /\ LET next == headHighest + 1
           txn == IF next = 1 THEN T1 ELSE T2
           identity == TxnIdentity[txn]
       IN /\ identity \notin admittedIds
          /\ headHighest' = next
          /\ headOrdinal' = headOrdinal + 1
          /\ headId' = CommitHeadId(next)
          /\ confirmedBatches' = confirmedBatches \cup {txn}
          /\ admittedIds' = admittedIds \cup {identity}
          /\ localState' = PrefixTransactions(next)
          /\ localIds' = localIds \cup {identity}
    /\ lastAction' = "CommitPrefix"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, recoveryPhase, recoveredManifest, recoveredState,
        recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

FamilyRunCapacityBackpressure ==
    /\ WriterEnabled
    /\ headHighest = 2
    /\ flushPhase = "Idle"
    /\ ~PerFamilyRunCapacityAvailable
    /\ flushPhase' = "Backpressured"
    /\ lastAction' = "FamilyRunCapacityBackpressure"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

DatabaseRunCapacityBackpressure ==
    /\ WriterEnabled
    /\ headHighest = 2
    /\ flushPhase = "Idle"
    /\ PerFamilyRunCapacityAvailable
    /\ ~DatabaseRunCapacityAvailable
    /\ flushPhase' = "Backpressured"
    /\ lastAction' = "DatabaseRunCapacityBackpressure"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

IdentityCapacityBackpressure ==
    /\ WriterEnabled
    /\ headHighest = 2
    /\ flushPhase = "Idle"
    /\ RunCapacityAvailable
    /\ ~IdentityCapacityAvailable
    /\ flushPhase' = "Backpressured"
    /\ lastAction' = "IdentityCapacityBackpressure"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

BeginFlush ==
    /\ WriterEnabled
    /\ headHighest = 2
    /\ flushPhase = "Idle"
    /\ RunCapacityAvailable
    /\ IdentityCapacityAvailable
    /\ IX \in admittedIds
    /\ flushBoundary' = headHighest
    /\ flushExpectedOrdinal' = headOrdinal
    /\ flushExpectedId' = headId
    /\ flushPhase' = "Prepared"
    /\ lastAction' = "BeginFlush"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

StoreRun(r) ==
    /\ WriterEnabled
    /\ r \in AttemptRuns \ storedRuns
    /\ flushPhase = "Prepared"
    /\ storedRuns' = storedRuns \cup {r}
    /\ completeRuns' = completeRuns \cup {r}
    /\ sortedRuns' = sortedRuns \cup {r}
    /\ readableRuns' = readableRuns \cup {r}
    /\ localRuns' = localRuns \cup {r}
    /\ lastAction' = "StoreRun"
    /\ UNCHANGED <<
        confirmedRuns, corruptRuns, storedManifests, confirmedManifests,
        manifestPrevious, manifestRegistry, manifestRuns, manifestBoundary,
        manifestLedger, headManifest, headHighest, headOrdinal, headId,
        confirmedBatches, admittedIds, flushBoundary, flushExpectedOrdinal,
        flushExpectedId, flushAttemptOrdinal, flushAttemptId, flushPhase,
        flushWasUnknown, resolvedCommitted, resolvedRejected, capacityMode,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

ConfirmRun(r) ==
    /\ WriterEnabled
    /\ r \in storedRuns \ confirmedRuns
    /\ r \in completeRuns
    /\ r \in sortedRuns
    /\ confirmedRuns' = confirmedRuns \cup {r}
    /\ lastAction' = "ConfirmRun"
    /\ UNCHANGED <<
        storedRuns, completeRuns, sortedRuns, readableRuns, corruptRuns,
        storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

StoreManifest ==
    /\ WriterEnabled
    /\ flushPhase = "Prepared"
    /\ AttemptRuns \subseteq confirmedRuns
    /\ M1 \notin storedManifests
    /\ storedManifests' = storedManifests \cup {M1}
    /\ manifestPrevious' = [manifestPrevious EXCEPT ![M1] = M0]
    /\ manifestRegistry' = [manifestRegistry EXCEPT ![M1] = FamilyConfig]
    /\ manifestRuns' = [manifestRuns EXCEPT ![M1] = CheckpointManifestRuns]
    /\ manifestBoundary' = [manifestBoundary EXCEPT ![M1] = flushBoundary]
    /\ manifestLedger' = [manifestLedger EXCEPT ![M1] = admittedIds]
    /\ flushPhase' = "ManifestStored"
    /\ localManifests' = localManifests \cup {M1}
    /\ lastAction' = "StoreManifest"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, confirmedManifests, headManifest, headHighest,
        headOrdinal, headId, confirmedBatches, admittedIds,
        flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localState, localIds, recoveryPhase, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

ConfirmManifest ==
    /\ WriterEnabled
    /\ flushPhase = "ManifestStored"
    /\ M1 \in storedManifests
    /\ M1 \notin confirmedManifests
    /\ confirmedManifests' = confirmedManifests \cup {M1}
    /\ flushPhase' = "Ready"
    /\ lastAction' = "ConfirmManifest"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, manifestPrevious, manifestRegistry,
        manifestRuns, manifestBoundary, manifestLedger, headManifest,
        headHighest, headOrdinal, headId, confirmedBatches, admittedIds,
        flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

PublishFlush ==
    /\ WriterEnabled
    /\ flushPhase = "Ready"
    /\ M1 \in confirmedManifests
    /\ headOrdinal = flushExpectedOrdinal
    /\ headId = flushExpectedId
    /\ headManifest' = M1
    /\ headOrdinal' = headOrdinal + 1
    /\ headId' = HF
    /\ flushAttemptOrdinal' = headOrdinal + 1
    /\ flushAttemptId' = HF
    /\ flushPhase' = "HeadAccepted"
    /\ lastAction' = "PublishFlush"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headHighest, confirmedBatches, admittedIds, flushBoundary,
        flushExpectedOrdinal, flushExpectedId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

LoseAcceptedFlushResponse ==
    /\ WriterEnabled
    /\ flushPhase = "HeadAccepted"
    /\ flushPhase' = "HeadUnknown"
    /\ flushWasUnknown' = TRUE
    /\ lastAction' = "LoseAcceptedFlushResponse"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, resolvedCommitted,
        resolvedRejected, capacityMode, localRuns, localManifests,
        localState, localIds, recoveryPhase, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

LoseUnacceptedFlushResponse ==
    /\ WriterEnabled
    /\ flushPhase = "Ready"
    /\ headOrdinal = flushExpectedOrdinal
    /\ headId = flushExpectedId
    /\ flushAttemptOrdinal' = headOrdinal + 1
    /\ flushAttemptId' = HF
    /\ flushPhase' = "HeadUnknown"
    /\ flushWasUnknown' = TRUE
    /\ lastAction' = "LoseUnacceptedFlushResponse"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

ObserveFlushSuccess ==
    /\ WriterEnabled
    /\ flushPhase = "HeadAccepted"
    /\ flushPhase' = "Success"
    /\ lastAction' = "ObserveFlushSuccess"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

ExternalCommitLater ==
    /\ WriterEnabled
    /\ headManifest = M1
    /\ headHighest = 2
    /\ flushPhase \in {"HeadUnknown", "Success"}
    /\ I3 \notin admittedIds
    /\ headHighest' = 3
    /\ headOrdinal' = headOrdinal + 1
    /\ headId' = HL
    /\ confirmedBatches' = confirmedBatches \cup {T3}
    /\ admittedIds' = admittedIds \cup {I3}
    /\ localState' = PrefixTransactions(3)
    /\ localIds' = localIds \cup {I3}
    /\ lastAction' = "ExternalCommitLater"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, recoveryPhase, recoveredManifest, recoveredState,
        recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

RivalTransition ==
    /\ WriterEnabled
    /\ flushPhase = "HeadUnknown"
    /\ headManifest = M0
    /\ headOrdinal = flushExpectedOrdinal
    /\ headId = flushExpectedId
    /\ headOrdinal' = headOrdinal + 1
    /\ headId' = HR
    /\ lastAction' = "RivalTransition"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, confirmedBatches, admittedIds,
        flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

ResolveCommitted ==
    /\ WriterEnabled
    /\ flushPhase = "HeadUnknown"
    /\ ManifestReachable(M1)
    /\ flushPhase' = "Success"
    /\ resolvedCommitted' = TRUE
    /\ lastAction' = "ResolveCommitted"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedRejected, capacityMode, localRuns, localManifests,
        localState, localIds, recoveryPhase, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

ResolveRejected ==
    /\ WriterEnabled
    /\ flushPhase = "HeadUnknown"
    /\ ~ManifestReachable(M1)
    /\ headOrdinal >= flushAttemptOrdinal
    /\ flushPhase' = "Rejected"
    /\ resolvedRejected' = TRUE
    /\ lastAction' = "ResolveRejected"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushWasUnknown,
        resolvedCommitted, capacityMode, localRuns, localManifests,
        localState, localIds, recoveryPhase, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

ExternalAdvanceBeforeFlushPublication ==
    /\ WriterEnabled
    /\ flushPhase = "Ready"
    /\ headOrdinal = flushExpectedOrdinal
    /\ headId = flushExpectedId
    /\ headOrdinal' = headOrdinal + 1
    /\ headId' = HR
    /\ lastAction' = "ExternalAdvanceBeforeFlushPublication"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, confirmedBatches, admittedIds,
        flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

(***************************************************************************
The following four actions are deliberately unsafe probes. They are not
members of Next. Probe modules add exactly one to the real state machine in
order to demonstrate that the corresponding invariant detects the bypass.
***************************************************************************)

UnsafePublishWithStaleExpectedHead ==
    /\ flushPhase = "Ready"
    /\ M1 \in confirmedManifests
    /\ headOrdinal > flushExpectedOrdinal
    /\ headId # flushExpectedId
    /\ headManifest' = M1
    /\ headOrdinal' = headOrdinal + 1
    /\ headId' = HF
    /\ flushAttemptOrdinal' = headOrdinal + 1
    /\ flushAttemptId' = HF
    /\ flushPhase' = "HeadAccepted"
    /\ stalePublicationObserved' = TRUE
    /\ lastAction' = "UnsafePublishWithStaleExpectedHead"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headHighest, confirmedBatches, admittedIds, flushBoundary,
        flushExpectedOrdinal, flushExpectedId, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved
       >>

UnsafePublishWithPartialRunSet ==
    /\ flushPhase = "Prepared"
    /\ R1 \in confirmedRuns
    /\ R2 \notin confirmedRuns
    /\ headOrdinal = flushExpectedOrdinal
    /\ headId = flushExpectedId
    /\ M1 \notin storedManifests
    /\ storedManifests' = storedManifests \cup {M1}
    /\ confirmedManifests' = confirmedManifests \cup {M1}
    /\ manifestPrevious' = [manifestPrevious EXCEPT ![M1] = M0]
    /\ manifestRegistry' = [manifestRegistry EXCEPT ![M1] = FamilyConfig]
    /\ manifestRuns' = [manifestRuns EXCEPT ![M1] = CheckpointManifestRuns]
    /\ manifestBoundary' = [manifestBoundary EXCEPT ![M1] = flushBoundary]
    /\ manifestLedger' = [manifestLedger EXCEPT ![M1] = admittedIds]
    /\ headManifest' = M1
    /\ headOrdinal' = headOrdinal + 1
    /\ headId' = HF
    /\ flushAttemptOrdinal' = headOrdinal + 1
    /\ flushAttemptId' = HF
    /\ flushPhase' = "HeadAccepted"
    /\ localManifests' = localManifests \cup {M1}
    /\ lastAction' = "UnsafePublishWithPartialRunSet"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, headHighest, confirmedBatches, admittedIds,
        flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushWasUnknown, resolvedCommitted, resolvedRejected, capacityMode,
        localRuns, localState, localIds, recoveryPhase, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

UnsafePublishWithWrongFamilyMapping ==
    /\ flushPhase = "Ready"
    /\ M1 \in confirmedManifests
    /\ headOrdinal = flushExpectedOrdinal
    /\ headId = flushExpectedId
    /\ manifestRuns' =
        [manifestRuns EXCEPT
            ![M1] = [f \in Families |-> IF f = F1 THEN {R2} ELSE {R1}]]
    /\ headManifest' = M1
    /\ headOrdinal' = headOrdinal + 1
    /\ headId' = HF
    /\ flushAttemptOrdinal' = headOrdinal + 1
    /\ flushAttemptId' = HF
    /\ flushPhase' = "HeadAccepted"
    /\ lastAction' = "UnsafePublishWithWrongFamilyMapping"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestBoundary, manifestLedger, headHighest,
        confirmedBatches, admittedIds, flushBoundary, flushExpectedOrdinal,
        flushExpectedId, flushWasUnknown, resolvedCommitted,
        resolvedRejected, capacityMode, localRuns, localManifests,
        localState, localIds, recoveryPhase, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

UnsafePublishWithWrongIdentityLedger ==
    /\ flushPhase = "Ready"
    /\ M1 \in confirmedManifests
    /\ headOrdinal = flushExpectedOrdinal
    /\ headId = flushExpectedId
    /\ manifestLedger' =
        [manifestLedger EXCEPT
            ![M1] = PrefixIdentities(manifestBoundary[M1])]
    /\ headManifest' = M1
    /\ headOrdinal' = headOrdinal + 1
    /\ headId' = HF
    /\ flushAttemptOrdinal' = headOrdinal + 1
    /\ flushAttemptId' = HF
    /\ flushPhase' = "HeadAccepted"
    /\ lastAction' = "UnsafePublishWithWrongIdentityLedger"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, headHighest,
        confirmedBatches, admittedIds, flushBoundary, flushExpectedOrdinal,
        flushExpectedId, flushWasUnknown, resolvedCommitted,
        resolvedRejected, capacityMode, localRuns, localManifests,
        localState, localIds, recoveryPhase, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

HideRun(r) ==
    /\ r \in confirmedRuns \ corruptRuns
    /\ r \in readableRuns
    /\ recoveryPhase = "Idle"
    /\ readableRuns' = readableRuns \ {r}
    /\ lastAction' = "HideRun"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, corruptRuns,
        storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

CorruptRunRead(r) ==
    /\ r \in confirmedRuns
    /\ r \in readableRuns
    /\ r \notin corruptRuns
    /\ recoveryPhase = "Idle"
    /\ corruptRuns' = corruptRuns \cup {r}
    /\ lastAction' = "CorruptRunRead"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveryPhase,
        recoveredManifest, recoveredState, recoveredIds,
        replayedTransactions, crashObserved, stalePublicationObserved
       >>

Crash ==
    /\ localRuns' = {}
    /\ localManifests' = {}
    /\ localState' = {}
    /\ localIds' = {}
    /\ recoveryPhase' = "Idle"
    /\ recoveredManifest' = NoManifest
    /\ recoveredState' = {}
    /\ recoveredIds' = {}
    /\ replayedTransactions' = {}
    /\ crashObserved' = TRUE
    /\ lastAction' = "Crash"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode,
        stalePublicationObserved
       >>

Recover ==
    /\ crashObserved
    /\ recoveryPhase = "Idle"
    /\ headManifest \in confirmedManifests
    /\ AllRecoveryRunsValid
    /\ recoveredManifest' = headManifest
    /\ recoveredState' = RunState(RecoveryRuns) \cup RecoveryReplay
    /\ recoveredIds' = manifestLedger[headManifest]
                            \cup RecoveryIdentityReplay
    /\ replayedTransactions' = RecoveryReplay
    /\ recoveryPhase' = "Recovered"
    /\ lastAction' = "Recover"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, crashObserved,
        stalePublicationObserved
       >>

RejectRecovery ==
    /\ crashObserved
    /\ recoveryPhase = "Idle"
    /\ headManifest \in confirmedManifests
    /\ ~AllRecoveryRunsValid
    /\ recoveryPhase' = "Rejected"
    /\ lastAction' = "RejectRecovery"
    /\ UNCHANGED <<
        storedRuns, confirmedRuns, completeRuns, sortedRuns, readableRuns,
        corruptRuns, storedManifests, confirmedManifests, manifestPrevious,
        manifestRegistry, manifestRuns, manifestBoundary, manifestLedger,
        headManifest, headHighest, headOrdinal, headId, confirmedBatches,
        admittedIds, flushBoundary, flushExpectedOrdinal, flushExpectedId,
        flushAttemptOrdinal, flushAttemptId, flushPhase, flushWasUnknown,
        resolvedCommitted, resolvedRejected, capacityMode, localRuns,
        localManifests, localState, localIds, recoveredManifest,
        recoveredState, recoveredIds, replayedTransactions, crashObserved,
        stalePublicationObserved
       >>

Next ==
    \/ ReserveFailedIdentity
    \/ CommitPrefix
    \/ FamilyRunCapacityBackpressure
    \/ DatabaseRunCapacityBackpressure
    \/ IdentityCapacityBackpressure
    \/ BeginFlush
    \/ \E r \in Runs : StoreRun(r)
    \/ \E r \in Runs : ConfirmRun(r)
    \/ StoreManifest
    \/ ConfirmManifest
    \/ PublishFlush
    \/ LoseAcceptedFlushResponse
    \/ LoseUnacceptedFlushResponse
    \/ ObserveFlushSuccess
    \/ ExternalCommitLater
    \/ RivalTransition
    \/ ResolveCommitted
    \/ ResolveRejected
    \/ ExternalAdvanceBeforeFlushPublication
    \/ \E r \in Runs : HideRun(r)
    \/ \E r \in Runs : CorruptRunRead(r)
    \/ Crash
    \/ Recover
    \/ RejectRecovery

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ storedRuns \subseteq Runs
    /\ confirmedRuns \subseteq Runs
    /\ completeRuns \subseteq Runs
    /\ sortedRuns \subseteq Runs
    /\ readableRuns \subseteq Runs
    /\ corruptRuns \subseteq Runs
    /\ storedManifests \subseteq Manifests
    /\ confirmedManifests \subseteq Manifests
    /\ manifestPrevious \in [Manifests -> Manifests \cup {NoManifest}]
    /\ manifestRegistry \in [Manifests -> {FamilyConfig}]
    /\ manifestRuns \in [Manifests -> [Families -> SUBSET Runs]]
    /\ manifestBoundary \in [Manifests -> 0..3]
    /\ manifestLedger \in [Manifests -> SUBSET Identities]
    /\ headManifest \in Manifests
    /\ headHighest \in 0..3
    /\ headOrdinal \in Nat
    /\ headId \in HeadIds
    /\ confirmedBatches \subseteq Transactions
    /\ admittedIds \subseteq Identities
    /\ flushBoundary \in 0..3
    /\ flushExpectedOrdinal \in Nat
    /\ flushExpectedId \in HeadIds \cup {NoHeadId}
    /\ flushAttemptOrdinal \in Nat
    /\ flushAttemptId \in HeadIds \cup {NoHeadId}
    /\ flushPhase \in FlushPhases
    /\ flushWasUnknown \in BOOLEAN
    /\ resolvedCommitted \in BOOLEAN
    /\ resolvedRejected \in BOOLEAN
    /\ capacityMode \in CapacityModes
    /\ localRuns \subseteq Runs
    /\ localManifests \subseteq Manifests
    /\ localState \subseteq Transactions
    /\ localIds \subseteq Identities
    /\ recoveryPhase \in RecoveryPhases
    /\ recoveredManifest \in Manifests \cup {NoManifest}
    /\ recoveredState \subseteq Transactions
    /\ recoveredIds \subseteq Identities
    /\ replayedTransactions \subseteq Transactions
    /\ crashObserved \in BOOLEAN
    /\ stalePublicationObserved \in BOOLEAN
    /\ lastAction \in ActionNames

ConfirmedRunsAreComplete ==
    confirmedRuns \subseteq storedRuns \cap completeRuns \cap sortedRuns

ConfirmedManifestsAreStored == confirmedManifests \subseteq storedManifests

ConfirmedRunFamiliesMatchContents ==
    \A r \in confirmedRuns :
        \A t \in RunTransactions[r] : TxnFamily[t] = RunFamily[r]

HeadReferencesConfirmedManifestAndRuns ==
    /\ headManifest \in confirmedManifests
    /\ RunsNamedBy(headManifest) \subseteq confirmedRuns

RegistryIsImmutable ==
    \A m \in storedManifests : manifestRegistry[m] = FamilyConfig

CheckpointContentsAreExact ==
    \A m \in confirmedManifests :
        /\ RunState(RunsNamedBy(m)) =
            PrefixTransactions(manifestBoundary[m])
        /\ manifestLedger[m] =
            BoundaryIdentityAuthority(manifestBoundary[m])

FamilyPlacementIsExact ==
    \A m \in confirmedManifests, f \in Families :
        /\ \A r \in manifestRuns[m][f] : RunFamily[r] = f
        /\ RunState(manifestRuns[m][f]) =
            FamilyPrefixTransactions(f, manifestBoundary[m])

UsedIdentitiesAreNeitherLostNorInvented ==
    recoveryPhase # "Recovered" \/ recoveredIds = AuthoritativeVisibleIds

RecoveredStateIsVisiblePrefix ==
    recoveryPhase # "Recovered" \/ recoveredState = VisibleState

NoPreBoundaryBatchIsReplayed ==
    recoveryPhase # "Recovered"
        \/ replayedTransactions
            \cap PrefixTransactions(manifestBoundary[recoveredManifest]) = {}

NoPreBoundaryIdentityIsReplayed ==
    recoveryPhase # "Recovered"
        \/ RecoveryIdentityReplay \cap manifestLedger[recoveredManifest] = {}

LaterCommitsPreserveManifest == headHighest # 3 \/ headManifest = M1

StaleFlushCannotPublish == ~stalePublicationObserved

LocalIsOnlyACache ==
    /\ localRuns \subseteq storedRuns
    /\ localManifests \subseteq storedManifests
    /\ localState \subseteq VisibleState
    /\ localIds \subseteq admittedIds

RecoveryRejectsInvalidRuns ==
    recoveryPhase # "Recovered" \/ AllRecoveryRunsValid

Safety ==
    /\ TypeOK
    /\ ConfirmedRunsAreComplete
    /\ ConfirmedManifestsAreStored
    /\ ConfirmedRunFamiliesMatchContents
    /\ HeadReferencesConfirmedManifestAndRuns
    /\ RegistryIsImmutable
    /\ CheckpointContentsAreExact
    /\ FamilyPlacementIsExact
    /\ UsedIdentitiesAreNeitherLostNorInvented
    /\ RecoveredStateIsVisiblePrefix
    /\ NoPreBoundaryBatchIsReplayed
    /\ NoPreBoundaryIdentityIsReplayed
    /\ LaterCommitsPreserveManifest
    /\ StaleFlushCannotPublish
    /\ LocalIsOnlyACache
    /\ RecoveryRejectsInvalidRuns

WitnessState == [
    action |-> lastAction,
    capacity |-> capacityMode,
    head |-> [manifest |-> headManifest, highest |-> headHighest,
              ordinal |-> headOrdinal, id |-> headId],
    flush |-> [phase |-> flushPhase, boundary |-> flushBoundary,
               expected_ordinal |-> flushExpectedOrdinal,
               expected_id |-> flushExpectedId,
               attempted_ordinal |-> flushAttemptOrdinal,
               attempted_id |-> flushAttemptId,
               was_unknown |-> flushWasUnknown,
               resolved_committed |-> resolvedCommitted,
               resolved_rejected |-> resolvedRejected],
    store |-> [stored_runs |-> storedRuns, confirmed_runs |-> confirmedRuns,
               complete_runs |-> completeRuns, sorted_runs |-> sortedRuns,
               stored_manifests |-> storedManifests,
               confirmed_manifests |-> confirmedManifests,
               checkpoint_runs |-> RunsNamedBy(M1),
               checkpoint_runs_by_family |-> manifestRuns[M1],
               checkpoint_ledger |-> manifestLedger[M1]],
    authority |-> [admitted_ids |-> admittedIds,
                    confirmed_batches |-> confirmedBatches],
    cache |-> [local_runs |-> localRuns, local_manifests |-> localManifests,
               local_state |-> localState, local_ids |-> localIds,
               recovery_phase |-> recoveryPhase,
               recovered_manifest |-> recoveredManifest,
               recovered_state |-> recoveredState,
               recovered_ids |-> recoveredIds,
               replayed |-> replayedTransactions,
               crash_observed |-> crashObserved]
]

WitnessAlias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
