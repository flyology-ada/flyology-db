---------------------- MODULE PublicationSafetyOverlapProbe ----------------------
EXTENDS FiniteSets

CONSTANTS B1, B2, T1

BatchIds == {B1, B2}
BatchTransactions == [b \in BatchIds |-> {T1}]
ActivePhases == {"Active", "Stored", "Accepted"}

VARIABLES phase, everUnknown

vars == <<phase, everUnknown>>

EverUnknownTxns == UNION {BatchTransactions[b] : b \in everUnknown}
ActiveTxns ==
    UNION {
        BatchTransactions[b] :
            b \in {candidate \in BatchIds : phase[candidate] \in ActivePhases}
    }

UnknownTransactionsCannotBeActive == EverUnknownTxns \intersect ActiveTxns = {}

Init ==
    /\ phase = [b \in BatchIds |-> IF b = B1 THEN "Failed" ELSE "Active"]
    /\ everUnknown = {B1}

ProbeSpec == Init /\ [][UNCHANGED vars]_vars

=============================================================================
