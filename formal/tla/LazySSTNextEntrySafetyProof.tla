----------------- MODULE LazySSTNextEntrySafetyProof --------------------
EXTENDS Naturals

(***************************************************************************
This action-preservation kernel abstracts one canonical next-visible-entry
selection over arbitrary finite request, position, and value domains. The
finite LazySSTNextEntry model owns byte ordering, snapshot/version fallback,
and bound calculation. Here ExpectedPosition is that established function, so
TLAPS proves request binding, exact selected/frame positions, terminal output,
and failure atomicity for every admitted request.

The kernel does not prove parsing, CRCs, provider behavior, progress, the Ada
implementation, or refinement.
***************************************************************************)

CONSTANTS Requests, Positions, Values, NoRequest, NoPosition, Prior,
    NotFound, Tombstone, ExpectedPosition, EntryAt

ConstantsOK ==
    /\ Requests # {}
    /\ Positions # {}
    /\ Values # {}
    /\ NoRequest \notin Requests
    /\ NoPosition \notin Positions
    /\ Prior \notin Values \union {NotFound, Tombstone}
    /\ NotFound \notin Values \union {Tombstone}
    /\ Tombstone \notin Values
    /\ ExpectedPosition \in [Requests -> Positions \union {NoPosition}]
    /\ EntryAt \in [Positions -> Values \union {Tombstone}]

ASSUME ConstantsOK

Phases == {"Idle", "Selecting", "Selected", "Ready", "Terminal"}
Results == {"None", "Selected", "FrameRead", "Success", "NotFound", "ReadFailed"}

VARIABLES request, selected, frame, phase, output, result

vars == <<request, selected, frame, phase, output, result>>

Init ==
    /\ request = NoRequest
    /\ selected = NoPosition
    /\ frame = NoPosition
    /\ phase = "Idle"
    /\ output = Prior
    /\ result = "None"

Begin ==
    /\ phase = "Idle"
    /\ \E chosen \in Requests : request' = chosen
    /\ selected' = NoPosition
    /\ frame' = NoPosition
    /\ phase' = "Selecting"
    /\ output' = output
    /\ result' = "None"

Select ==
    /\ phase = "Selecting"
    /\ selected' = ExpectedPosition[request]
    /\ phase' = "Selected"
    /\ result' = "Selected"
    /\ UNCHANGED <<request, frame, output>>

ReadFrame ==
    /\ phase = "Selected"
    /\ selected \in Positions
    /\ frame' = selected
    /\ phase' = "Ready"
    /\ result' = "FrameRead"
    /\ UNCHANGED <<request, selected, output>>

PublishValue ==
    /\ phase = "Ready"
    /\ frame = selected
    /\ EntryAt[selected] \in Values
    /\ output' = EntryAt[selected]
    /\ phase' = "Terminal"
    /\ result' = "Success"
    /\ UNCHANGED <<request, selected, frame>>

PublishTombstone ==
    /\ phase = "Ready"
    /\ frame = selected
    /\ EntryAt[selected] = Tombstone
    /\ output' = NotFound
    /\ phase' = "Terminal"
    /\ result' = "NotFound"
    /\ UNCHANGED <<request, selected, frame>>

PublishAbsent ==
    /\ phase = "Selected"
    /\ selected = NoPosition
    /\ output' = NotFound
    /\ phase' = "Terminal"
    /\ result' = "NotFound"
    /\ UNCHANGED <<request, selected, frame>>

Reject ==
    /\ phase \in {"Selecting", "Selected"}
    /\ phase' = "Terminal"
    /\ result' = "ReadFailed"
    /\ UNCHANGED <<request, selected, frame, output>>

TypeOK ==
    /\ request \in Requests \union {NoRequest}
    /\ selected \in Positions \union {NoPosition}
    /\ frame \in Positions \union {NoPosition}
    /\ phase \in Phases
    /\ output \in Values \union {Prior, NotFound}
    /\ result \in Results

RequestBound == phase # "Idle" => request \in Requests

PhaseResultBound ==
    /\ (phase = "Idle" => result = "None")
    /\ (phase = "Selecting" => result = "None")
    /\ (phase = "Selected" => result = "Selected")
    /\ (phase = "Ready" => result = "FrameRead")
    /\ (phase = "Terminal" => result \in {"Success", "NotFound", "ReadFailed"})

SelectionExact ==
    phase \in {"Selected", "Ready", "Terminal"} /\ result # "ReadFailed"
    => selected = ExpectedPosition[request]

FrameBound == phase = "Ready" => /\ selected \in Positions
                                  /\ frame = selected

PrePublicationAtomic == phase # "Terminal" => output = Prior

FailureAtomic == result = "ReadFailed" => output = Prior

TerminalExact ==
    phase = "Terminal" /\ result # "ReadFailed"
    => IF selected = NoPosition
       THEN /\ result = "NotFound"
            /\ output = NotFound
       ELSE IF EntryAt[selected] = Tombstone
            THEN /\ result = "NotFound"
                 /\ output = NotFound
            ELSE /\ result = "Success"
                 /\ output = EntryAt[selected]

Safety ==
    /\ TypeOK
    /\ RequestBound
    /\ PhaseResultBound
    /\ SelectionExact
    /\ FrameBound
    /\ PrePublicationAtomic
    /\ FailureAtomic
    /\ TerminalExact

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1> QED BY DEF Init, Safety, TypeOK, RequestBound, SelectionExact,
    PhaseResultBound, FrameBound, PrePublicationAtomic, FailureAtomic,
    TerminalExact, Phases, Results, ConstantsOK

THEOREM BeginPreservesSafety == Safety /\ Begin => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Begin, TypeOK, RequestBound, SelectionExact,
    PhaseResultBound, FrameBound, PrePublicationAtomic, FailureAtomic,
    TerminalExact, Phases, Results, ConstantsOK

THEOREM SelectPreservesSafety == Safety /\ Select => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Select, TypeOK, RequestBound, SelectionExact,
    PhaseResultBound, FrameBound, PrePublicationAtomic, FailureAtomic,
    TerminalExact, Phases, Results, ConstantsOK

THEOREM ReadFramePreservesSafety == Safety /\ ReadFrame => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, ReadFrame, TypeOK, RequestBound, SelectionExact,
    PhaseResultBound, FrameBound, PrePublicationAtomic, FailureAtomic,
    TerminalExact, Phases, Results, ConstantsOK

THEOREM PublishValuePreservesSafety == Safety /\ PublishValue => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, PublishValue, TypeOK, RequestBound, SelectionExact,
    PhaseResultBound, FrameBound, PrePublicationAtomic, FailureAtomic,
    TerminalExact, Phases, Results, ConstantsOK

THEOREM PublishTombstonePreservesSafety == Safety /\ PublishTombstone => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, PublishTombstone, TypeOK, RequestBound,
    PhaseResultBound, SelectionExact, FrameBound, PrePublicationAtomic,
    FailureAtomic, TerminalExact, Phases, Results, ConstantsOK

THEOREM PublishAbsentPreservesSafety == Safety /\ PublishAbsent => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, PublishAbsent, TypeOK, RequestBound, SelectionExact,
    PhaseResultBound, FrameBound, PrePublicationAtomic, FailureAtomic,
    TerminalExact, Phases, Results, ConstantsOK

THEOREM RejectPreservesSafety == Safety /\ Reject => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Reject, TypeOK, RequestBound, SelectionExact,
    PhaseResultBound, FrameBound, PrePublicationAtomic, FailureAtomic,
    TerminalExact, Phases, Results, ConstantsOK

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, RequestBound, SelectionExact, FrameBound,
    PhaseResultBound, PrePublicationAtomic, FailureAtomic, TerminalExact, vars

=============================================================================
