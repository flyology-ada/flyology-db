----------------- MODULE CheckpointPublicationRejectedWitness -----------------
EXTENDS CheckpointPublication

WitnessComplete ==
    /\ lastAction = "ResolveRejected"
    /\ flushPhase = "Rejected"
    /\ flushWasUnknown
    /\ resolvedRejected
    /\ headManifest = M0
    /\ headHighest = 2
    /\ headOrdinal = flushAttemptOrdinal
    /\ headId = HR
    /\ M1 \notin {headManifest, manifestPrevious[headManifest]}

WitnessPending == ~WitnessComplete

=============================================================================
