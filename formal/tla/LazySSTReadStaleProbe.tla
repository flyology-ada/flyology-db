---------------------- MODULE LazySSTReadStaleProbe ----------------------
EXTENDS LazySSTRead

UnsafeStaleRead ==
    /\ phase = "NeedIndex"
    /\ currentGeneration # capturedGeneration
    /\ output' = ObjectValues[currentGeneration][requestedKey]
    /\ phase' = "Terminal"
    /\ result' = "Success"
    /\ lastAction' = "UnsafeStaleRead"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, frameGeneration, frameKey, frameValue>>

UnsafeNext == Next \/ UnsafeStaleRead
UnsafeSpec == Init /\ [][UnsafeNext]_vars

=============================================================================
