--------------------------- MODULE LazySSTRead ---------------------------
EXTENDS FlyologyHarness, Naturals, Sequences, TLC

(***************************************************************************
This finite model freezes the certainty boundary for an independently framed
lazy SST read. Begin abstracts a successful authority observation followed by
generation-bound header validation. Index and entry-frame reads must use that
same generation; a frame must match the authenticated index key. Allocation
and corruption rejection preserve the prior output.

Two keys, two generations, and four values are qualification geometry, not
format, cache, request, retry, key/value, or provider policy. The model does
not prove CRC arithmetic, byte ranges, parsing, allocation, progress,
concurrency, provider behavior, the Ada implementation, or refinement.
***************************************************************************)

Keys == 1 .. 2
Generations == {"G1", "G2"}
Values == {"A1", "B1", "A2", "B2"}
Outputs == Values \union {"Prior"}
Phases == {"Idle", "NeedIndex", "NeedFrame", "Ready", "Terminal"}
Results == {
    "None", "HeaderRead", "IndexRead", "FrameRead", "Success",
    "CapacityExceeded", "StaleGeneration", "Corrupt"
}
ActionNames == {
    "Init", "Begin", "ReplaceObject", "ReadIndex", "ReadFrame",
    "PublishSuccess", "RejectAllocation", "RejectStaleIndex",
    "RejectStaleFrame", "RejectCorruptIndex", "RejectCorruptFrame",
    "UnsafeStaleRead", "UnsafeFrameSwap"
}

ObjectValues ==
    [generation \in Generations |->
        IF generation = "G1"
        THEN [key \in Keys |-> IF key = 1 THEN "A1" ELSE "B1"]
        ELSE [key \in Keys |-> IF key = 1 THEN "A2" ELSE "B2"]]

VARIABLES currentGeneration, capturedGeneration, requestedKey, indexGeneration,
    frameGeneration, frameKey, frameValue, phase, output, result, lastAction

vars == <<currentGeneration, capturedGeneration, requestedKey, indexGeneration,
    frameGeneration, frameKey, frameValue, phase, output, result, lastAction>>

Init ==
    /\ currentGeneration = "G1"
    /\ capturedGeneration = "None"
    /\ requestedKey = 2
    /\ indexGeneration = "None"
    /\ frameGeneration = "None"
    /\ frameKey = 0
    /\ frameValue = "Prior"
    /\ phase = "Idle"
    /\ output = "Prior"
    /\ result = "None"
    /\ lastAction = "Init"

Begin ==
    /\ phase = "Idle"
    /\ capturedGeneration' = currentGeneration
    /\ indexGeneration' = "None"
    /\ frameGeneration' = "None"
    /\ frameKey' = 0
    /\ frameValue' = "Prior"
    /\ phase' = "NeedIndex"
    /\ output' = output
    /\ result' = "HeaderRead"
    /\ lastAction' = "Begin"
    /\ UNCHANGED <<currentGeneration, requestedKey>>

ReplaceObject ==
    /\ phase \in {"NeedIndex", "NeedFrame", "Ready"}
    /\ currentGeneration = "G1"
    /\ currentGeneration' = "G2"
    /\ lastAction' = "ReplaceObject"
    /\ UNCHANGED <<capturedGeneration, requestedKey, indexGeneration,
        frameGeneration, frameKey, frameValue, phase, output, result>>

ReadIndex ==
    /\ phase = "NeedIndex"
    /\ currentGeneration = capturedGeneration
    /\ indexGeneration' = capturedGeneration
    /\ phase' = "NeedFrame"
    /\ result' = "IndexRead"
    /\ lastAction' = "ReadIndex"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        frameGeneration, frameKey, frameValue, output>>

RejectStaleIndex ==
    /\ phase = "NeedIndex"
    /\ currentGeneration # capturedGeneration
    /\ phase' = "Terminal"
    /\ result' = "StaleGeneration"
    /\ lastAction' = "RejectStaleIndex"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, frameGeneration, frameKey, frameValue, output>>

RejectCorruptIndex ==
    /\ phase = "NeedIndex"
    /\ currentGeneration = capturedGeneration
    /\ phase' = "Terminal"
    /\ result' = "Corrupt"
    /\ lastAction' = "RejectCorruptIndex"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, frameGeneration, frameKey, frameValue, output>>

RejectAllocation ==
    /\ phase = "NeedFrame"
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectAllocation"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, frameGeneration, frameKey, frameValue, phase, output>>

ReadFrame ==
    /\ phase = "NeedFrame"
    /\ currentGeneration = capturedGeneration
    /\ indexGeneration = capturedGeneration
    /\ frameGeneration' = capturedGeneration
    /\ frameKey' = requestedKey
    /\ frameValue' = ObjectValues[capturedGeneration][requestedKey]
    /\ phase' = "Ready"
    /\ result' = "FrameRead"
    /\ lastAction' = "ReadFrame"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, output>>

RejectStaleFrame ==
    /\ phase = "NeedFrame"
    /\ currentGeneration # capturedGeneration
    /\ phase' = "Terminal"
    /\ result' = "StaleGeneration"
    /\ lastAction' = "RejectStaleFrame"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, frameGeneration, frameKey, frameValue, output>>

RejectCorruptFrame ==
    /\ phase = "NeedFrame"
    /\ currentGeneration = capturedGeneration
    /\ indexGeneration = capturedGeneration
    /\ phase' = "Terminal"
    /\ result' = "Corrupt"
    /\ lastAction' = "RejectCorruptFrame"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, frameGeneration, frameKey, frameValue, output>>

PublishSuccess ==
    /\ phase = "Ready"
    /\ indexGeneration = capturedGeneration
    /\ frameGeneration = capturedGeneration
    /\ frameKey = requestedKey
    /\ output' = frameValue
    /\ phase' = "Terminal"
    /\ result' = "Success"
    /\ lastAction' = "PublishSuccess"
    /\ UNCHANGED <<currentGeneration, capturedGeneration, requestedKey,
        indexGeneration, frameGeneration, frameKey, frameValue>>

Next ==
    \/ Begin
    \/ ReplaceObject
    \/ ReadIndex
    \/ ReadFrame
    \/ PublishSuccess
    \/ RejectAllocation
    \/ RejectStaleIndex
    \/ RejectStaleFrame
    \/ RejectCorruptIndex
    \/ RejectCorruptFrame

TypeOK ==
    /\ currentGeneration \in Generations
    /\ capturedGeneration \in Generations \union {"None"}
    /\ requestedKey \in Keys
    /\ indexGeneration \in Generations \union {"None"}
    /\ frameGeneration \in Generations \union {"None"}
    /\ frameKey \in Keys \union {0}
    /\ frameValue \in Outputs
    /\ phase \in Phases
    /\ output \in Outputs
    /\ result \in Results
    /\ lastAction \in ActionNames

GenerationExact ==
    /\ (indexGeneration # "None" => indexGeneration = capturedGeneration)
    /\ (frameGeneration # "None" => frameGeneration = capturedGeneration)

RequestBound ==
    phase \in {"NeedIndex", "NeedFrame", "Ready"}
    => /\ capturedGeneration \in Generations
       /\ requestedKey \in Keys

FrameBound ==
    frameGeneration = "None"
    \/ /\ frameKey = requestedKey
       /\ frameValue = ObjectValues[capturedGeneration][requestedKey]

OutputExact ==
    output = "Prior"
    \/ /\ result = "Success"
       /\ output = ObjectValues[capturedGeneration][requestedKey]

PrePublicationAtomic ==
    phase \in {"Idle", "NeedIndex", "NeedFrame", "Ready"} => output = "Prior"

FailureAtomic ==
    result \in {"CapacityExceeded", "StaleGeneration", "Corrupt"}
    => output = "Prior"

Safety ==
    /\ TypeOK
    /\ RequestBound
    /\ GenerationExact
    /\ FrameBound
    /\ OutputExact
    /\ PrePublicationAtomic
    /\ FailureAtomic

HarnessState ==
    [action |-> lastAction,
     current_generation |-> currentGeneration,
     captured_generation |-> capturedGeneration,
     requested_key |-> requestedKey,
     index_generation |-> indexGeneration,
     frame_generation |-> frameGeneration,
     frame_key |-> frameKey,
     frame_value |-> frameValue,
     phase |-> phase,
     output |-> output,
     result |-> result]

HarnessAlias == CheckedWitnessAlias(lastAction, HarnessState)

Spec == Init /\ [][Next]_vars

=============================================================================
