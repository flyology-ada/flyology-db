---------------- MODULE CheckpointPublicationCommittedWitness ----------------
EXTENDS CheckpointPublication

WitnessComplete ==
    /\ lastAction = "ResolveCommitted"
    /\ flushPhase = "Success"
    /\ flushWasUnknown
    /\ resolvedCommitted
    /\ headManifest = M1
    /\ headHighest = 2
    /\ manifestBoundary[M1] = 2
    /\ manifestLedger[M1] = {I1, I2, IX}
    /\ RunsNamedBy(M1) = AttemptRuns

WitnessPending == ~WitnessComplete

=============================================================================
