------------------- MODULE LazySSTReadFrameSwapProbe --------------------
EXTENDS LazySSTRead

OtherKey(key) == IF key = 1 THEN 2 ELSE 1

UnsafeFrameSwap ==
    /\ phase = "NeedFrame"
    /\ currentGeneration = capturedGeneration
    /\ indexGeneration = capturedGeneration
    /\ frameGeneration' = capturedGeneration
    /\ frameKey' = OtherKey(requestedKey)
    /\ frameValue' = ObjectValues[capturedGeneration][OtherKey(requestedKey)]
    /\ phase' = "Ready"
    /\ result' = "FrameRead"
    /\ lastAction' = "UnsafeFrameSwap"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, output>>

UnsafeNext == Next \/ UnsafeFrameSwap
UnsafeSpec == Init /\ [][UnsafeNext]_vars

=============================================================================
