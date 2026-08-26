---------------------- MODULE LazySSTReadSafetyProof ---------------------
EXTENDS Naturals, Sequences

(***************************************************************************
This action-preservation kernel abstracts an arbitrary generation-bound lazy
SST entry read. ObjectValue is the exact authenticated value for each object
generation and key. An index authenticates only its captured generation; a
frame authenticates that generation, the requested key, and its exact value.
Failure preserves the prior output.

The finite LazySSTRead model checks replacement timing, allocation rejection,
corruption rejection, and two unsafe probes. This kernel does not prove CRC
arithmetic, byte ranges, format decoding, provider behavior, allocation,
progress, concurrency, the Ada implementation, or refinement.
***************************************************************************)

CONSTANTS Generations, Keys, Values, NoGeneration, NoKey, Prior, ObjectValue

ConstantsOK ==
    /\ Generations # {}
    /\ Keys # {}
    /\ Values # {}
    /\ NoGeneration \notin Generations
    /\ NoKey \notin Keys
    /\ Prior \notin Values
    /\ ObjectValue \in [Generations -> [Keys -> Values]]

ASSUME ConstantsOK

Phases == {"Idle", "NeedIndex", "NeedFrame", "Ready", "Terminal"}
Results == {
    "None", "HeaderRead", "IndexRead", "FrameRead", "Success",
    "CapacityExceeded", "StaleGeneration", "Corrupt"
}
FailureResults == {"CapacityExceeded", "StaleGeneration", "Corrupt"}

VARIABLES capturedGeneration, requestedKey, indexGeneration, frameGeneration,
    frameKey, frameValue, phase, output, result

vars == <<capturedGeneration, requestedKey, indexGeneration, frameGeneration,
    frameKey, frameValue, phase, output, result>>

Init ==
    /\ capturedGeneration = NoGeneration
    /\ requestedKey = NoKey
    /\ indexGeneration = NoGeneration
    /\ frameGeneration = NoGeneration
    /\ frameKey = NoKey
    /\ frameValue = Prior
    /\ phase = "Idle"
    /\ output = Prior
    /\ result = "None"

CaptureHeader ==
    /\ phase = "Idle"
    /\ \E generation \in Generations, key \in Keys :
        /\ capturedGeneration' = generation
        /\ requestedKey' = key
    /\ indexGeneration' = NoGeneration
    /\ frameGeneration' = NoGeneration
    /\ frameKey' = NoKey
    /\ frameValue' = Prior
    /\ phase' = "NeedIndex"
    /\ output' = output
    /\ result' = "HeaderRead"

AuthenticateIndex ==
    /\ phase = "NeedIndex"
    /\ indexGeneration' = capturedGeneration
    /\ phase' = "NeedFrame"
    /\ result' = "IndexRead"
    /\ UNCHANGED <<capturedGeneration, requestedKey, frameGeneration,
        frameKey, frameValue, output>>

AuthenticateFrame ==
    /\ phase = "NeedFrame"
    /\ indexGeneration = capturedGeneration
    /\ frameGeneration' = capturedGeneration
    /\ frameKey' = requestedKey
    /\ frameValue' = ObjectValue[capturedGeneration][requestedKey]
    /\ phase' = "Ready"
    /\ result' = "FrameRead"
    /\ UNCHANGED <<capturedGeneration, requestedKey, indexGeneration, output>>

Publish ==
    /\ phase = "Ready"
    /\ indexGeneration = capturedGeneration
    /\ frameGeneration = capturedGeneration
    /\ frameKey = requestedKey
    /\ output' = frameValue
    /\ phase' = "Terminal"
    /\ result' = "Success"
    /\ UNCHANGED <<capturedGeneration, requestedKey, indexGeneration,
        frameGeneration, frameKey, frameValue>>

Reject ==
    /\ phase \in {"NeedIndex", "NeedFrame"}
    /\ result' \in FailureResults
    /\ phase' \in {phase, "Terminal"}
    /\ UNCHANGED <<capturedGeneration, requestedKey, indexGeneration,
        frameGeneration, frameKey, frameValue, output>>

TypeOK ==
    /\ capturedGeneration \in Generations \union {NoGeneration}
    /\ requestedKey \in Keys \union {NoKey}
    /\ indexGeneration \in Generations \union {NoGeneration}
    /\ frameGeneration \in Generations \union {NoGeneration}
    /\ frameKey \in Keys \union {NoKey}
    /\ frameValue \in Values \union {Prior}
    /\ phase \in Phases
    /\ output \in Values \union {Prior}
    /\ result \in Results

GenerationExact ==
    /\ (indexGeneration # NoGeneration => indexGeneration = capturedGeneration)
    /\ (frameGeneration # NoGeneration => frameGeneration = capturedGeneration)

RequestBound ==
    phase \in {"NeedIndex", "NeedFrame", "Ready"}
    => /\ capturedGeneration \in Generations
       /\ requestedKey \in Keys

FrameBound ==
    frameGeneration = NoGeneration
    \/ /\ frameKey = requestedKey
       /\ frameValue = ObjectValue[capturedGeneration][requestedKey]

OutputExact ==
    output = Prior
    \/ /\ result = "Success"
       /\ output = ObjectValue[capturedGeneration][requestedKey]

PrePublicationAtomic ==
    phase \in {"Idle", "NeedIndex", "NeedFrame", "Ready"} => output = Prior

FailureAtomic == result \in FailureResults => output = Prior

Safety ==
    /\ TypeOK
    /\ RequestBound
    /\ GenerationExact
    /\ FrameBound
    /\ OutputExact
    /\ PrePublicationAtomic
    /\ FailureAtomic

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1>1. Init => TypeOK
<2> QED BY DEF Init, TypeOK, Phases, Results, ConstantsOK
<1>2. Init => GenerationExact
<2> QED BY DEF Init, GenerationExact
<1>3. Init => RequestBound
<2> QED BY DEF Init, RequestBound
<1>4. Init => FrameBound
<2> QED BY DEF Init, FrameBound
<1>5. Init => OutputExact
<2> QED BY DEF Init, OutputExact
<1>6. Init => FailureAtomic
<2> QED BY DEF Init, FailureAtomic, FailureResults
<1>7. Init => PrePublicationAtomic
<2> QED BY DEF Init, PrePublicationAtomic
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM CaptureHeaderPreservesSafety == Safety /\ CaptureHeader => Safety'
<1> USE ConstantsOK
<1>1. Safety /\ CaptureHeader => TypeOK'
<2> QED BY DEF Safety, CaptureHeader, TypeOK, Phases, Results, ConstantsOK
<1>2. Safety /\ CaptureHeader => GenerationExact'
<2> QED BY DEF CaptureHeader, GenerationExact
<1>3. Safety /\ CaptureHeader => RequestBound'
<2> QED BY DEF CaptureHeader, RequestBound
<1>4. Safety /\ CaptureHeader => FrameBound'
<2> QED BY DEF CaptureHeader, FrameBound
<1>5. Safety /\ CaptureHeader => OutputExact'
<2> QED BY DEF Safety, CaptureHeader, OutputExact, PrePublicationAtomic
<1>6. Safety /\ CaptureHeader => FailureAtomic'
<2> QED BY DEF CaptureHeader, FailureAtomic, FailureResults
<1>7. Safety /\ CaptureHeader => PrePublicationAtomic'
<2> QED BY DEF Safety, CaptureHeader, PrePublicationAtomic
<1> QED BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Safety

THEOREM AuthenticateIndexPreservesSafety ==
    Safety /\ AuthenticateIndex => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, AuthenticateIndex, TypeOK, RequestBound,
    GenerationExact, FrameBound, OutputExact, PrePublicationAtomic,
    FailureAtomic, Phases, Results, FailureResults, ConstantsOK

THEOREM AuthenticateFramePreservesSafety ==
    Safety /\ AuthenticateFrame => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, AuthenticateFrame, TypeOK, RequestBound,
    GenerationExact, FrameBound, OutputExact, PrePublicationAtomic,
    FailureAtomic, Phases, Results, FailureResults, ConstantsOK

THEOREM PublishPreservesSafety == Safety /\ Publish => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Publish, TypeOK, RequestBound, GenerationExact,
    FrameBound, OutputExact, PrePublicationAtomic, FailureAtomic, Phases,
    Results, FailureResults, ConstantsOK

THEOREM RejectPreservesSafety == Safety /\ Reject => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Reject, TypeOK, RequestBound, GenerationExact,
    FrameBound, OutputExact, PrePublicationAtomic, FailureAtomic, Phases,
    Results, FailureResults, ConstantsOK

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, RequestBound, GenerationExact, FrameBound,
    OutputExact, PrePublicationAtomic, FailureAtomic, vars

=============================================================================
