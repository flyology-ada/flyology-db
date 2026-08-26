----------------- MODULE ManifestPublicationFailureWitness -----------------
EXTENDS ManifestPublication, FlyologyHarness

FailureWitnessComplete ==
    /\ lastAction = "Recover"
    /\ latestManifest = M2
    /\ previous[M2] = NoManifest
    /\ M1 \in headWasUnknown
    /\ M1 \in resolvedFailed
    /\ phase[M1] = "Failed"
    /\ attemptedOrdinal[M1] = 1
    /\ headOrdinal = 1
    /\ crashObserved
    /\ local = {}
    /\ recoveredManifest = M2
    /\ recoveredRegistry = RootRegistry

FailureWitnessPending == ~FailureWitnessComplete

WitnessState == [
    action |-> lastAction,
    head |-> [ordinal |-> headOrdinal, latest_manifest |-> latestManifest],
    manifests |-> [m \in ManifestIds |-> [
        phase |-> phase[m],
        previous |-> previous[m],
        registry |-> registry[m],
        bytes_confirmed |-> m \in confirmed,
        put_was_unknown |-> m \in putWasUnknown,
        head_was_unknown |-> m \in headWasUnknown,
        resolved_committed |-> m \in resolvedCommitted,
        resolved_failed |-> m \in resolvedFailed
    ]],
    cache |-> [local |-> local, recovered_manifest |-> recoveredManifest,
               recovered_registry |-> recoveredRegistry, crash_observed |-> crashObserved]
]

Alias == CheckedWitnessAlias(lastAction, WitnessState)

=============================================================================
