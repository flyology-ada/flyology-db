----------------- MODULE CheckpointPublicationRecoveryWitness -----------------
EXTENDS CheckpointPublication

WitnessComplete ==
    /\ lastAction = "Recover"
    /\ flushPhase = "Success"
    /\ flushWasUnknown
    /\ resolvedCommitted
    /\ headManifest = M1
    /\ headHighest = 3
    /\ crashObserved
    /\ localRuns = {}
    /\ localManifests = {}
    /\ localState = {}
    /\ localIds = {}
    /\ recoveryPhase = "Recovered"
    /\ recoveredManifest = M1
    /\ recoveredState = {T1, T2, T3}
    /\ recoveredIds = {I1, I2, I3, IX}
    /\ replayedTransactions = {T3}

WitnessPending == ~WitnessComplete

=============================================================================
