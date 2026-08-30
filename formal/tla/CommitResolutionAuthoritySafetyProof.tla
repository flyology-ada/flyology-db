--------------- MODULE CommitResolutionAuthoritySafetyProof ---------------
EXTENDS FiniteSets

(***************************************************************************
This unbounded kernel proves only the durable receipt-authority transfer:
export retains the exact transaction/batch binding, crash loses volatile
unknown receipts, validated import restores only that binding, malformed input
is a no-op, and none of these actions changes provider publication state.
Concrete bytes, checksums, allocation, and Ada ownership remain separate.
***************************************************************************)

CONSTANTS Txns, BatchIds, NoBatch, TxnBatch, BatchTxns, RemoteObjects

ConstantsOK ==
    /\ NoBatch \notin BatchIds
    /\ TxnBatch \in [Txns -> BatchIds]
    /\ BatchTxns \in [BatchIds -> SUBSET Txns]
    /\ \A t \in Txns : t \in BatchTxns[TxnBatch[t]]

ASSUME ConstantsOK

ReceiptStates == {"None", "Unknown", "Committed", "PreconditionFailed"}

VARIABLES receipt, durable, lifecycle, remote, invalidImportAccepted

vars == <<receipt, durable, lifecycle, remote, invalidImportAccepted>>

Init ==
    /\ receipt = [t \in Txns |-> "Unknown"]
    /\ durable = [t \in Txns |-> NoBatch]
    /\ lifecycle = [t \in Txns |-> "None"]
    /\ remote = RemoteObjects
    /\ invalidImportAccepted = FALSE

Export(t) ==
    /\ receipt[t] = "Unknown"
    /\ durable[t] = NoBatch
    /\ durable' = [durable EXCEPT ![t] = TxnBatch[t]]
    /\ lifecycle' = [lifecycle EXCEPT ![t] = "Exported"]
    /\ UNCHANGED <<receipt, remote, invalidImportAccepted>>

Crash ==
    /\ receipt' = [t \in Txns |-> IF receipt[t] = "Unknown" THEN "None" ELSE receipt[t]]
    /\ lifecycle' =
        [t \in Txns |->
            IF receipt[t] = "Unknown" /\ lifecycle[t] \in {"Exported", "Imported"}
            THEN "Lost"
            ELSE lifecycle[t]]
    /\ UNCHANGED <<durable, remote, invalidImportAccepted>>

Import(t) ==
    /\ receipt[t] = "None"
    /\ lifecycle[t] = "Lost"
    /\ durable[t] = TxnBatch[t]
    /\ t \in BatchTxns[durable[t]]
    /\ receipt' = [receipt EXCEPT ![t] = "Unknown"]
    /\ lifecycle' = [lifecycle EXCEPT ![t] = "Imported"]
    /\ UNCHANGED <<durable, remote, invalidImportAccepted>>

RejectMalformed(t, b) ==
    /\ receipt[t] = "None"
    /\ b \in BatchIds
    /\ (b # TxnBatch[t] \/ t \notin BatchTxns[b])
    /\ UNCHANGED vars

TypeOK ==
    /\ receipt \in [Txns -> ReceiptStates]
    /\ durable \in [Txns -> BatchIds \cup {NoBatch}]
    /\ lifecycle \in [Txns -> {"None", "Exported", "Lost", "Imported"}]
    /\ invalidImportAccepted \in BOOLEAN

DurableAuthorityIsExact ==
    \A t \in Txns :
        durable[t] # NoBatch =>
            /\ durable[t] = TxnBatch[t]
            /\ t \in BatchTxns[durable[t]]

AuthorityLifecycleIsOrdered ==
    \A t \in Txns :
        /\ (lifecycle[t] = "None") = (durable[t] = NoBatch)
        /\ lifecycle[t] = "Lost" => receipt[t] = "None"

ImportDoesNotPublish == remote = RemoteObjects

MalformedImportIsNoOp == ~invalidImportAccepted

Safety ==
    /\ TypeOK
    /\ DurableAuthorityIsExact
    /\ AuthorityLifecycleIsOrdered
    /\ ImportDoesNotPublish
    /\ MalformedImportIsNoOp

THEOREM InitialSafety == Init => Safety
<1> USE ConstantsOK
<1> QED BY DEF Init, Safety, TypeOK, DurableAuthorityIsExact,
    AuthorityLifecycleIsOrdered,
    ImportDoesNotPublish, MalformedImportIsNoOp, ReceiptStates, ConstantsOK

THEOREM ExportPreservesSafety ==
    \A t \in Txns : Safety /\ Export(t) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Export, Safety, TypeOK, DurableAuthorityIsExact,
    AuthorityLifecycleIsOrdered,
    ImportDoesNotPublish, MalformedImportIsNoOp, ReceiptStates, ConstantsOK

THEOREM CrashPreservesSafety == Safety /\ Crash => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Crash, Safety, TypeOK, DurableAuthorityIsExact,
    AuthorityLifecycleIsOrdered,
    ImportDoesNotPublish, MalformedImportIsNoOp, ReceiptStates, ConstantsOK

THEOREM ImportPreservesSafety ==
    \A t \in Txns : Safety /\ Import(t) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF Import, Safety, TypeOK, DurableAuthorityIsExact,
    AuthorityLifecycleIsOrdered,
    ImportDoesNotPublish, MalformedImportIsNoOp, ReceiptStates, ConstantsOK

THEOREM RejectMalformedPreservesSafety ==
    \A t \in Txns, b \in BatchIds : Safety /\ RejectMalformed(t, b) => Safety'
<1> USE ConstantsOK
<1> QED BY DEF RejectMalformed, Safety, TypeOK, DurableAuthorityIsExact,
    AuthorityLifecycleIsOrdered,
    ImportDoesNotPublish, MalformedImportIsNoOp, ReceiptStates, ConstantsOK, vars

=============================================================================
