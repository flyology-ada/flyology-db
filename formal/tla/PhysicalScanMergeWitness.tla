-------------------- MODULE PhysicalScanMergeWitness ---------------------
EXTENDS PhysicalScanMerge

(***************************************************************************
The witness emits transaction-local key one, changes current engine authority,
rejects one allocation without movement, emits the newer suffix value for key
two, and suppresses key three through the older suffix tombstone. The final
rows remain those of the captured source set.
***************************************************************************)

FirstRow == <<[key |-> 1, value |-> "B"]>>
SecondRow == <<[key |-> 2, value |-> "C"]>>
CompleteRows == FirstRow \o SecondRow

NextWitness ==
    \/ lastAction = "Init" /\ Begin
    \/ lastAction = "Begin" /\ AdvanceVisible
    \/ lastAction = "AdvanceVisible" /\ emitted = FirstRow
       /\ ConcurrentChange
    \/ lastAction = "ConcurrentChange" /\ RejectAllocation
    \/ lastAction = "RejectAllocation" /\ AdvanceVisible
    \/ lastAction = "AdvanceVisible" /\ emitted = CompleteRows
       /\ AdvanceTombstone

SpecWitness == Init /\ [][NextWitness]_vars

WitnessComplete ==
    /\ lastAction = "AdvanceTombstone"
    /\ emitted = CompleteRows
    /\ page = SecondRow
    /\ done
    /\ lastKey = 3
    /\ positions = [source \in SourceIDs |-> Len(capturedSources[source]) + 1]
    /\ capturedSources = InitialSources
    /\ currentSources = ChangedSources

WitnessPending == ~WitnessComplete

WitnessAlias ==
    [action |-> lastAction,
     result |-> result,
     positions |-> positions,
     lastKey |-> lastKey,
     page |-> page,
     emitted |-> emitted,
     done |-> done,
     captured |-> capturedSources,
     current |-> currentSources]

=============================================================================
