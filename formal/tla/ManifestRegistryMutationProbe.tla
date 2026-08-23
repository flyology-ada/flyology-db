-------------------- MODULE ManifestRegistryMutationProbe --------------------
EXTENDS FiniteSets, TLC

CONSTANTS M1, M2, F1, F2, C1, C2, NoManifest, NoConfig

ManifestIds == {M1, M2}
Families == {F1, F2}

VARIABLES stored, previous, registry

vars == <<stored, previous, registry>>

RegistryIsMonotonic ==
    \A m \in stored, f \in Families :
        previous[m] # NoManifest /\ registry[previous[m]][f] # NoConfig
            => registry[m][f] = registry[previous[m]][f]

Init ==
    /\ stored = {M1, M2}
    /\ previous = (M1 :> NoManifest @@ M2 :> M1)
    /\ registry =
        (M1 :> (F1 :> C1 @@ F2 :> NoConfig) @@
         M2 :> (F1 :> C2 @@ F2 :> C2))

ProbeSpec == Init /\ [][UNCHANGED vars]_vars

=============================================================================
