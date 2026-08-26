------------------------- MODULE PagedScanWitness --------------------------
EXTENDS PagedScan

(***************************************************************************
This witness begins on rows (1,A), (3,B), (4,A): key two's newer tombstone
masks its older A. It emits key one, then changes current authority by
replacing key one, resurrecting key two, and deleting key three. The frozen
cursor must still reject an undersized next page atomically, preserve state on
allocation rejection, and then emit the original key-three and key-four rows
without gaps or duplicates.
***************************************************************************)

FirstPage == <<[key |-> 1, value |-> "A"]>>
SecondPage == <<[key |-> 3, value |-> "B"]>>
FinalPage == <<[key |-> 4, value |-> "A"]>>
CompleteRows == FirstPage \o SecondPage \o FinalPage

NextWitness ==
    \/ lastAction = "Init" /\ Begin(FALSE)
    \/ lastAction = "Begin" /\ ProducePage(1, 5)
    \/ lastAction = "ProducePage" /\ emitted = FirstPage
       /\ ConcurrentAdvance
    \/ lastAction = "ConcurrentAdvance" /\ RejectCapacity(1, 2)
    \/ lastAction = "RejectCapacity" /\ RejectAllocation(1, 3)
    \/ lastAction = "RejectAllocation" /\ ProducePage(1, 3)
    \/ lastAction = "ProducePage" /\ emitted = FirstPage \o SecondPage
       /\ ProducePage(2, 5)

SpecWitness == Init /\ [][NextWitness]_vars

WitnessComplete ==
    /\ lastAction = "ProducePage"
    /\ emitted = CompleteRows
    /\ page = FinalPage
    /\ done
    /\ predicateRecorded
    /\ ~emptyView
    /\ snapshotNewest = InitialNewest
    /\ currentNewest[1] = "C"
    /\ currentNewest[2] = "C"
    /\ currentNewest[3] = "Tombstone"

WitnessPending == ~WitnessComplete

WitnessAlias ==
    [action |-> lastAction,
     result |-> result,
     rowLimit |-> lastRowLimit,
     byteLimit |-> lastByteLimit,
     page |-> page,
     emitted |-> emitted,
     done |-> done,
     predicate |-> predicateRecorded,
     emptyView |-> emptyView,
     snapshot |-> snapshotNewest,
     current |-> currentNewest]

=============================================================================
