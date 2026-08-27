----------- MODULE AuthenticatedScanInitializationSafetyProof -----------
EXTENDS Naturals, Sequences

(***************************************************************************
This action-preservation kernel composes an already-exact one-run selector
over an arbitrary nonempty ordered run domain. Expected contains the exact
canonical snapshot-visible sequence for every run; an empty sequence covers a
future or range-empty run. The proof establishes exact prefix accumulation,
failure atomicity, and publication only after every run is complete.

The kernel assumes the one-run selector's exact next result. It does not prove
key ordering, SST authentication, parsing, provider behavior, progress,
allocation implementation, physical merge selection, Ada, or refinement.
***************************************************************************)

CONSTANTS RunCount, Entries, PriorCursor, Expected

Runs == 1 .. RunCount
EmptyLoaded == [run \in Runs |-> <<>>]

ConstantsOK ==
    /\ RunCount \in Nat \ {0}
    /\ Entries # {}
    /\ PriorCursor \notin [Runs -> Seq(Entries)]
    /\ Expected \in [Runs -> Seq(Entries)]

ASSUME ConstantsOK

Phases == {"Idle", "Reading", "Building", "Terminal"}
Results == {"None", "Started", "EntryRead", "RunComplete", "Success",
    "ReadFailed", "CapacityExceeded"}

VARIABLES currentRun, loaded, phase, cursor, result

vars == <<currentRun, loaded, phase, cursor, result>>

Init ==
    /\ currentRun = 0
    /\ loaded = EmptyLoaded
    /\ phase = "Idle"
    /\ cursor = PriorCursor
    /\ result = "None"

Begin ==
    /\ phase = "Idle"
    /\ currentRun' = 1
    /\ loaded' = EmptyLoaded
    /\ phase' = "Reading"
    /\ cursor' = cursor
    /\ result' = "Started"

ReadEntry ==
    /\ phase = "Reading"
    /\ Len(loaded[currentRun]) < Len(Expected[currentRun])
    /\ loaded' =
         [loaded EXCEPT
            ![currentRun] = Append(@, Expected[currentRun][Len(@) + 1])]
    /\ result' = "EntryRead"
    /\ UNCHANGED <<currentRun, phase, cursor>>

FinishRun ==
    /\ phase = "Reading"
    /\ loaded[currentRun] = Expected[currentRun]
    /\ currentRun' = IF currentRun = RunCount THEN currentRun ELSE currentRun + 1
    /\ phase' = IF currentRun = RunCount THEN "Building" ELSE "Reading"
    /\ result' = "RunComplete"
    /\ UNCHANGED <<loaded, cursor>>

Publish ==
    /\ phase = "Building"
    /\ loaded = Expected
    /\ cursor' = loaded
    /\ phase' = "Terminal"
    /\ result' = "Success"
    /\ UNCHANGED <<currentRun, loaded>>

Reject ==
    /\ phase \in {"Reading", "Building"}
    /\ result' \in {"ReadFailed", "CapacityExceeded"}
    /\ phase' = "Terminal"
    /\ UNCHANGED <<currentRun, loaded, cursor>>

PrefixOf(prefix, complete) ==
    /\ Len(prefix) <= Len(complete)
    /\ prefix = SubSeq(complete, 1, Len(prefix))

TypeOK ==
    /\ currentRun \in 0 .. RunCount
    /\ loaded \in [Runs -> Seq(Entries)]
    /\ phase \in Phases
    /\ cursor \in {PriorCursor} \union [Runs -> Seq(Entries)]
    /\ result \in Results

ProgressExact ==
    /\ (phase = "Idle" => currentRun = 0 /\ loaded = EmptyLoaded)
    /\ (phase \in {"Reading", "Building", "Terminal"} =>
          \A run \in Runs : PrefixOf(loaded[run], Expected[run]))
    /\ (phase = "Reading" =>
          /\ currentRun \in Runs
          /\ \A run \in Runs : run < currentRun => loaded[run] = Expected[run]
          /\ \A run \in Runs : run > currentRun => loaded[run] = <<>>)
    /\ (phase = "Building" => loaded = Expected)

PhaseResultBound ==
    /\ (phase = "Idle" => result = "None")
    /\ (phase = "Reading" => result \in {"Started", "EntryRead", "RunComplete"})
    /\ (phase = "Building" => result = "RunComplete")
    /\ (phase = "Terminal" => result \in {"Success", "ReadFailed", "CapacityExceeded"})

PublicationAtomic ==
    /\ (phase # "Terminal" => cursor = PriorCursor)
    /\ (result \in {"ReadFailed", "CapacityExceeded"} => cursor = PriorCursor)
    /\ (result = "Success" => cursor = Expected)

Safety == TypeOK /\ ProgressExact /\ PhaseResultBound /\ PublicationAtomic

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1> QED BY DEF Init, Safety, TypeOK, ProgressExact, PhaseResultBound,
    PublicationAtomic, PrefixOf, EmptyLoaded, Phases, Results, Runs, ConstantsOK

THEOREM BeginPreservesSafety == Safety /\ Begin => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Begin, TypeOK, ProgressExact, PhaseResultBound,
    PublicationAtomic, PrefixOf, EmptyLoaded, Phases, Results, Runs, ConstantsOK

THEOREM ReadEntryPreservesSafety == Safety /\ ReadEntry => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, ReadEntry, TypeOK, ProgressExact, PhaseResultBound,
    PublicationAtomic, PrefixOf, Phases, Results, Runs, ConstantsOK

THEOREM FinishRunPreservesSafety == Safety /\ FinishRun => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, FinishRun, TypeOK, ProgressExact, PhaseResultBound,
    PublicationAtomic, PrefixOf, Phases, Results, Runs, ConstantsOK

THEOREM PublishPreservesSafety == Safety /\ Publish => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Publish, TypeOK, ProgressExact, PhaseResultBound,
    PublicationAtomic, PrefixOf, Phases, Results, Runs, ConstantsOK

THEOREM RejectPreservesSafety == Safety /\ Reject => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Safety, Reject, TypeOK, ProgressExact, PhaseResultBound,
    PublicationAtomic, PrefixOf, Phases, Results, Runs, ConstantsOK

THEOREM QuiescencePreservesSafety == Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, ProgressExact, PhaseResultBound,
    PublicationAtomic, PrefixOf, vars

=============================================================================
