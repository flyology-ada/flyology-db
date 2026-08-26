------------------- MODULE LazyCheckpointReadSafetyProof -------------------
EXTENDS Naturals

(***************************************************************************
This action-preservation kernel abstracts fixed-snapshot selection across an
arbitrary finite immutable run slice. The finite LazyCheckpointRead model owns
the newest-visible-run calculation. Here Expected is that already established
selection function, so TLAPS proves publication/failure atomicity and cursor
preservation for arbitrary snapshot, key, value, and exact run-count domains.

This kernel does not prove the finite selection calculation, SST integrity,
allocation, provider behavior, progress, the Ada implementation, or
refinement.
***************************************************************************)

CONSTANTS Snapshots, Keys, Values, NoSnapshot, NoKey, NoValue, Tombstone,
    Prior, NotFound, CursorMax, Expected

ConstantsOK ==
    /\ Snapshots # {}
    /\ Keys # {}
    /\ Values # {}
    /\ NoSnapshot \notin Snapshots
    /\ NoKey \notin Keys
    /\ NoValue \notin Values
    /\ Tombstone \notin Values
    /\ Prior \notin Values \union {NoValue, Tombstone, NotFound}
    /\ NotFound \notin Values \union {NoValue, Tombstone}
    /\ CursorMax \in Nat
    /\ CursorMax > 0
    /\ Expected \in [Snapshots -> [Keys -> Values \union {NoValue, Tombstone}]]

ASSUME ConstantsOK

Phases == {"Idle", "Selecting", "Terminal"}
Results == {"None", "Success", "NotFound", "ReadFailed"}

VARIABLES snapshot, key, cursor, phase, output, result

vars == <<snapshot, key, cursor, phase, output, result>>

Init ==
    /\ snapshot = NoSnapshot
    /\ key = NoKey
    /\ cursor = 0
    /\ phase = "Idle"
    /\ output = Prior
    /\ result = "None"

Begin ==
    /\ phase = "Idle"
    /\ \E selectedSnapshot \in Snapshots, selectedKey \in Keys :
        /\ snapshot' = selectedSnapshot
        /\ key' = selectedKey
    /\ cursor' = CursorMax
    /\ phase' = "Selecting"
    /\ output' = output
    /\ result' = "None"

Advance ==
    /\ phase = "Selecting"
    /\ cursor > 0
    /\ cursor' = cursor - 1
    /\ UNCHANGED <<snapshot, key, phase, output, result>>

PublishValue ==
    /\ phase = "Selecting"
    /\ Expected[snapshot][key] \in Values
    /\ output' = Expected[snapshot][key]
    /\ result' = "Success"
    /\ phase' = "Terminal"
    /\ UNCHANGED <<snapshot, key, cursor>>

PublishNotFound ==
    /\ phase = "Selecting"
    /\ Expected[snapshot][key] \in {NoValue, Tombstone}
    /\ output' = NotFound
    /\ result' = "NotFound"
    /\ phase' = "Terminal"
    /\ UNCHANGED <<snapshot, key, cursor>>

Reject ==
    /\ phase = "Selecting"
    /\ result' = "ReadFailed"
    /\ phase' = "Terminal"
    /\ UNCHANGED <<snapshot, key, cursor, output>>

TypeOK ==
    /\ snapshot \in Snapshots \union {NoSnapshot}
    /\ key \in Keys \union {NoKey}
    /\ cursor \in 0 .. CursorMax
    /\ phase \in Phases
    /\ output \in Values \union {Prior, NotFound}
    /\ result \in Results

RequestBound ==
    phase \in {"Selecting", "Terminal"}
    => /\ snapshot \in Snapshots
       /\ key \in Keys

PrePublicationAtomic ==
    phase # "Terminal" => output = Prior

FailureAtomic ==
    result = "ReadFailed" => output = Prior

TerminalExact ==
    phase = "Terminal" /\ result # "ReadFailed"
    => IF Expected[snapshot][key] \in Values
       THEN /\ result = "Success"
            /\ output = Expected[snapshot][key]
       ELSE /\ result = "NotFound"
            /\ output = NotFound

Safety ==
    /\ TypeOK
    /\ RequestBound
    /\ PrePublicationAtomic
    /\ FailureAtomic
    /\ TerminalExact

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1> QED BY DEF Init, Safety, TypeOK, RequestBound, PrePublicationAtomic,
    FailureAtomic, TerminalExact, Phases, Results, ConstantsOK

THEOREM BeginPreservesSafety == Safety /\ Begin => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Begin, TypeOK, RequestBound, PrePublicationAtomic,
    FailureAtomic, TerminalExact, Phases, Results, ConstantsOK

THEOREM AdvancePreservesSafety == Safety /\ Advance => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Advance, TypeOK, RequestBound, PrePublicationAtomic,
    FailureAtomic, TerminalExact, ConstantsOK

THEOREM PublishValuePreservesSafety == Safety /\ PublishValue => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, PublishValue, TypeOK, RequestBound,
    PrePublicationAtomic, FailureAtomic, TerminalExact, Phases, Results,
    ConstantsOK

THEOREM PublishNotFoundPreservesSafety == Safety /\ PublishNotFound => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, PublishNotFound, TypeOK, RequestBound,
    PrePublicationAtomic, FailureAtomic, TerminalExact, Phases, Results,
    ConstantsOK

THEOREM RejectPreservesSafety == Safety /\ Reject => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Reject, TypeOK, RequestBound, PrePublicationAtomic,
    FailureAtomic, TerminalExact, Phases, Results, ConstantsOK

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, RequestBound, PrePublicationAtomic,
    FailureAtomic, TerminalExact, vars

=============================================================================
