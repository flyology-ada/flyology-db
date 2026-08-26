------------------------ MODULE PhysicalScanMerge ------------------------
EXTENDS FiniteSets, Naturals, Sequences, TLC

(***************************************************************************
This finite model freezes one owned k-way merge snapshot for paged scans.
Four already-sorted sources represent the checkpoint base, an older suffix
batch, a newer suffix batch, and transaction-local mutations. Higher source
numbers have newer authority. Advancing one key consumes every source head
with that key, chooses the newest entry, and suppresses a winning tombstone.

Three keys and four sources are qualification geometry, not run-count,
history, page, key, or value policy. Current engine authority may change after
Begin; the retained source snapshot and its positions remain authoritative.
Allocation rejection changes no retained position or emitted row. The model
does not prove source-index construction, image reference counting, byte
comparison, progress, concurrency, allocation, or refinement to Ada.
***************************************************************************)

Keys == 1 .. 3
Values == {"A", "B", "C", "Tombstone"}
LiveValues == Values \ {"Tombstone"}
SourceIDs == 1 .. 4
Entries == [key : Keys, value : Values]

Entry(key, value) == [key |-> key, value |-> value]

InitialSources ==
    [source \in SourceIDs |->
        CASE source = 1 -> <<Entry(1, "A"), Entry(2, "A"), Entry(3, "A")>>
          [] source = 2 -> <<Entry(2, "B"), Entry(3, "Tombstone")>>
          [] source = 3 -> <<Entry(1, "Tombstone"), Entry(2, "C")>>
          [] OTHER -> <<Entry(1, "B")>>]

ChangedSources ==
    [source \in SourceIDs |->
        CASE source = 1 -> <<Entry(1, "A"), Entry(2, "A"), Entry(3, "A")>>
          [] source = 2 -> <<Entry(2, "Tombstone"), Entry(3, "C")>>
          [] source = 3 -> <<Entry(1, "C"), Entry(2, "A")>>
          [] OTHER -> <<>>]

SourceMaps == [SourceIDs -> Seq(Entries)]

SourcesContaining(sources, key) ==
    {source \in SourceIDs :
        \E index \in 1 .. Len(sources[source]) :
            sources[source][index].key = key}

WinnerSourceFor(sources, key) ==
    CHOOSE source \in SourcesContaining(sources, key) :
        \A other \in SourcesContaining(sources, key) : source >= other

WinnerEntryFor(sources, key) ==
    LET source == WinnerSourceFor(sources, key)
    IN  CHOOSE entry \in {sources[source][index] :
            index \in 1 .. Len(sources[source])} : entry.key = key

VisibleKeysFor(sources) ==
    SelectSeq(<<1, 2, 3>>,
        LAMBDA key : WinnerEntryFor(sources, key).value # "Tombstone")

ReferenceRowsFor(sources) ==
    LET keys == VisibleKeysFor(sources)
    IN  [index \in 1 .. Len(keys) |->
            [key |-> keys[index],
             value |-> WinnerEntryFor(sources, keys[index]).value]]

InitialPositions == [source \in SourceIDs |-> 1]

ActiveSourcesFor(sources, positions) ==
    {source \in SourceIDs : positions[source] <= Len(sources[source])}

HeadKey(sources, positions, source) ==
    sources[source][positions[source]].key

NextKeyFor(sources, positions) ==
    CHOOSE key \in
        {HeadKey(sources, positions, source) :
            source \in ActiveSourcesFor(sources, positions)} :
        \A other \in ActiveSourcesFor(sources, positions) :
            key <= HeadKey(sources, positions, other)

MatchingHeadsFor(sources, positions, key) ==
    {source \in ActiveSourcesFor(sources, positions) :
        HeadKey(sources, positions, source) = key}

WinningHeadFor(sources, positions, key) ==
    CHOOSE source \in MatchingHeadsFor(sources, positions, key) :
        \A other \in MatchingHeadsFor(sources, positions, key) :
            source >= other

WinningEntryFor(sources, positions, key) ==
    LET source == WinningHeadFor(sources, positions, key)
    IN  sources[source][positions[source]]

AdvanceAllFor(sources, positions, key) ==
    [source \in SourceIDs |->
        positions[source] +
            IF source \in MatchingHeadsFor(sources, positions, key)
            THEN 1 ELSE 0]

PositionAfterKey(sources, source, key) ==
    1 + Cardinality({index \in 1 .. Len(sources[source]) :
        sources[source][index].key <= key})

ExpectedRowsThrough(sources, key) ==
    SelectSeq(ReferenceRowsFor(sources), LAMBDA row : row.key <= key)

Results == {"None", "Started", "Advanced", "Success", "CapacityExceeded"}
ActionNames == {
    "Init", "Begin", "ConcurrentChange", "AdvanceVisible",
    "AdvanceTombstone", "RejectAllocation", "UnsafeAdvance",
    "UnsafeWinner"
}

VARIABLES currentSources, capturedSources, positions, lastKey, emitted, page,
    active, done, result, lastAction

vars == <<currentSources, capturedSources, positions, lastKey, emitted, page,
    active, done, result, lastAction>>

Init ==
    /\ currentSources = InitialSources
    /\ capturedSources = InitialSources
    /\ positions = InitialPositions
    /\ lastKey = 0
    /\ emitted = <<>>
    /\ page = <<>>
    /\ active = FALSE
    /\ done = FALSE
    /\ result = "None"
    /\ lastAction = "Init"

Begin ==
    /\ ~active
    /\ capturedSources' = currentSources
    /\ positions' = InitialPositions
    /\ lastKey' = 0
    /\ emitted' = <<>>
    /\ page' = <<>>
    /\ active' = TRUE
    /\ done' = FALSE
    /\ result' = "Started"
    /\ lastAction' = "Begin"
    /\ UNCHANGED currentSources

ConcurrentChange ==
    /\ active
    /\ currentSources = InitialSources
    /\ currentSources' = ChangedSources
    /\ lastAction' = "ConcurrentChange"
    /\ UNCHANGED <<capturedSources, positions, lastKey, emitted, page,
        active, done, result>>

AdvanceVisible ==
    LET key == NextKeyFor(capturedSources, positions)
        winner == WinningEntryFor(capturedSources, positions, key)
        advanced == AdvanceAllFor(capturedSources, positions, key)
        row == [key |-> key, value |-> winner.value]
    IN  /\ active /\ ~done
        /\ ActiveSourcesFor(capturedSources, positions) # {}
        /\ winner.value \in LiveValues
        /\ positions' = advanced
        /\ lastKey' = key
        /\ emitted' = Append(emitted, row)
        /\ page' = <<row>>
        /\ done' = (ActiveSourcesFor(capturedSources, advanced) = {})
        /\ result' = "Success"
        /\ lastAction' = "AdvanceVisible"
        /\ UNCHANGED <<currentSources, capturedSources, active>>

AdvanceTombstone ==
    LET key == NextKeyFor(capturedSources, positions)
        winner == WinningEntryFor(capturedSources, positions, key)
        advanced == AdvanceAllFor(capturedSources, positions, key)
    IN  /\ active /\ ~done
        /\ ActiveSourcesFor(capturedSources, positions) # {}
        /\ winner.value = "Tombstone"
        /\ positions' = advanced
        /\ lastKey' = key
        /\ done' = (ActiveSourcesFor(capturedSources, advanced) = {})
        /\ result' = "Advanced"
        /\ lastAction' = "AdvanceTombstone"
        /\ UNCHANGED <<currentSources, capturedSources, emitted, page, active>>

RejectAllocation ==
    /\ active /\ ~done
    /\ ActiveSourcesFor(capturedSources, positions) # {}
    /\ result' = "CapacityExceeded"
    /\ lastAction' = "RejectAllocation"
    /\ UNCHANGED <<currentSources, capturedSources, positions, lastKey,
        emitted, page, active, done>>

Next ==
    \/ Begin
    \/ ConcurrentChange
    \/ AdvanceVisible
    \/ AdvanceTombstone
    \/ RejectAllocation

TypeOK ==
    /\ currentSources \in SourceMaps
    /\ capturedSources \in SourceMaps
    /\ positions \in [SourceIDs -> Nat]
    /\ lastKey \in 0 .. 3
    /\ emitted \in Seq([key : Keys, value : LiveValues])
    /\ page \in Seq([key : Keys, value : LiveValues])
    /\ active \in BOOLEAN
    /\ done \in BOOLEAN
    /\ result \in Results
    /\ lastAction \in ActionNames

CapturedExact == ~active \/ capturedSources = InitialSources

PositionsExact ==
    ~active \/
        \A source \in SourceIDs :
            positions[source] =
                PositionAfterKey(capturedSources, source, lastKey)

EmittedExact ==
    ~active \/ emitted = ExpectedRowsThrough(capturedSources, lastKey)

DoneExact ==
    ~active \/
        (done <=> ActiveSourcesFor(capturedSources, positions) = {})

Safety ==
    TypeOK /\ CapturedExact /\ PositionsExact /\ EmittedExact /\ DoneExact

Spec == Init /\ [][Next]_vars

=============================================================================
