---------------------- MODULE ManifestPublicationWitness ----------------------
EXTENDS ManifestPublication

WitnessComplete ==
    /\ lastAction = "Recover"
    /\ latestManifest = M2
    /\ previous[M2] = M1
    /\ M1 \in putWasUnknown
    /\ M1 \in headWasUnknown
    /\ M1 \in resolvedCommitted
    /\ M1 \in confirmed
    /\ crashObserved
    /\ local = {}
    /\ recoveredManifest = M2
    /\ recoveredRegistry = SuccessorRegistry

WitnessPending == ~WitnessComplete

Alias == [
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

=============================================================================
