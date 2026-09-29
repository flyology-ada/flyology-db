----- MODULE PipelinedAdaptiveAggregateCommitCoalescingAdmissionSlices -----
EXTENDS PipelinedAdaptiveAggregateCommitCoalescing

(***************************************************************************
Qualification-only admission slicing. Every finite admission sequence is a
prefix of one of the 24 permutations below because transaction identities are
never reused. Across all slices, every non-admission action and every snapshot
choice remain unchanged. The runner uses PipelineSafetyView. It erases the
diagnostic lastAction field, cancellation and conflict-wait histories, and
write-only diagnostic evidence fields. It also canonicalizes transaction
preparation and batch PUT outcomes only after their requests have joined, when
retained fragments, failure ledgers, phase, and storage state determine every
successor. Cancellation, conflict-wait, and stale completion observations are
projected stutters. No retained operational guard, successor, admission
constraint, or safety clause reads the erased evidence beyond its type.
Cancellation reachability, diagnostic witnesses, close progress, and lifecycle
runs retain the complete StateView.
***************************************************************************)

CONSTANT AdmissionPermutation

Order1234 == <<1, 2, 3, 4>>
Order1243 == <<1, 2, 4, 3>>
Order1324 == <<1, 3, 2, 4>>
Order1342 == <<1, 3, 4, 2>>
Order1423 == <<1, 4, 2, 3>>
Order1432 == <<1, 4, 3, 2>>
Order2134 == <<2, 1, 3, 4>>
Order2143 == <<2, 1, 4, 3>>
Order2314 == <<2, 3, 1, 4>>
Order2341 == <<2, 3, 4, 1>>
Order2413 == <<2, 4, 1, 3>>
Order2431 == <<2, 4, 3, 1>>
Order3124 == <<3, 1, 2, 4>>
Order3142 == <<3, 1, 4, 2>>
Order3214 == <<3, 2, 1, 4>>
Order3241 == <<3, 2, 4, 1>>
Order3412 == <<3, 4, 1, 2>>
Order3421 == <<3, 4, 2, 1>>
Order4123 == <<4, 1, 2, 3>>
Order4132 == <<4, 1, 3, 2>>
Order4213 == <<4, 2, 1, 3>>
Order4231 == <<4, 2, 3, 1>>
Order4312 == <<4, 3, 1, 2>>
Order4321 == <<4, 3, 2, 1>>

AdmissionOrderConstraint ==
    /\ AdmissionPermutation \in Seq(Transactions)
    /\ Len(AdmissionPermutation) = Cardinality(Transactions)
    /\ AsSet(AdmissionPermutation) = Transactions
    /\ \A index \in 1..Len(s.admission) :
         s.admission[index] = AdmissionPermutation[index]

AtMostTwoAdmissions == Len(s.admission) <= 2

PipelineSafetyView ==
    [StateView EXCEPT
      !.cancelRequested = {},
      !.conflictWaited = {},
      !.overlappedPrepare = FALSE,
      !.outOfOrderBatch = FALSE,
      !.overlappedBatch = FALSE,
      !.closeTail = FALSE,
      !.localFailure = FALSE,
      !.closed = FALSE,
      !.stalePrepareIgnored = FALSE,
      !.staleIgnored = FALSE,
      !.prepareOutcome = [w \in PrepareWork |->
          IF w[1] = "Txn" /\ s.prepareRequest[w] = "Joined"
          THEN "None"
          ELSE @[w]],
      !.batchOutcome = [c \in Cohorts |->
          IF s.batchRequest[c] = "Joined"
          THEN "None"
          ELSE @[c]]]
=============================================================================
