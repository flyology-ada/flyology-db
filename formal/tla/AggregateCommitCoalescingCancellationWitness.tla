-------------- MODULE AggregateCommitCoalescingCancellationWitness --------------
EXTENDS AggregateCommitCoalescing

(***************************************************************************
The witness orders queued, frozen, and unknown-outcome cancellation requests.
Each request changes only the base model's diagnostic action name. Both members
must still drain through the original shared publication and receipt authority.
***************************************************************************)

VARIABLE pc
witnessVars == <<s, pc>>

WitnessInit == Init /\ pc = 0

WitnessNext ==
    \/ /\ pc = 0 /\ SupplyAggregateID(B1) /\ pc' = 1
    \/ /\ pc = 1 /\ AdmitSingleton(T1) /\ pc' = 2
    \/ /\ pc = 2 /\ RequestAdmittedCancellation(T1) /\ pc' = 3
    \/ /\ pc = 3 /\ AdmitSingleton(T2) /\ pc' = 4
    \/ /\ pc = 4 /\ FreezeCohort /\ pc' = 5
    \/ /\ pc = 5 /\ RequestAdmittedCancellation(T2) /\ pc' = 6
    \/ /\ pc = 6 /\ PublishAggregate("Confirmed") /\ pc' = 7
    \/ /\ pc = 7 /\ PublishHead("UnknownAccepted") /\ pc' = 8
    \/ /\ pc = 8 /\ RequestAdmittedCancellation(T1) /\ pc' = 9
    \/ /\ pc = 9 /\ ResolveMember(T1) /\ pc' = 10
    \/ /\ pc = 10 /\ ResolveMember(T2) /\ pc' = 11

WitnessSpec == WitnessInit /\ [][WitnessNext]_witnessVars

WitnessComplete ==
    /\ pc = 11
    /\ s.txn[T1] = "Committed" /\ s.txn[T2] = "Committed"
    /\ s.receipt[T1] = "Committed" /\ s.receipt[T2] = "Committed"
    /\ s.visible = {T1, T2} /\ s.acknowledged = {T1, T2}
    /\ s.memberBatch[T1] = B1 /\ s.memberBatch[T2] = B1
    /\ s.memberSequence[T1] = 1 /\ s.memberSequence[T2] = 2
    /\ s.batchPuts[B1] = 1 /\ s.headPuts[B1] = 1
    /\ s.resolutionWrites = 0

WitnessPending == ~WitnessComplete

=============================================================================
