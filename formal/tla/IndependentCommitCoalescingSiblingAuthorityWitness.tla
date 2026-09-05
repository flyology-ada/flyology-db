--------- MODULE IndependentCommitCoalescingSiblingAuthorityWitness ---------
EXTENDS IndependentCommitCoalescing

SiblingAuthorityComplete ==
    /\ lastAction = "ExportMemberAuthority"
    /\ visible = {T1, T2}
    /\ txnState[T1] = "Committed"
    /\ receipt[T1] = "Committed"
    /\ txnState[T2] = "Unknown"
    /\ receipt[T2] = "Unknown"
    /\ authorityState[T2] = "Exported"
    /\ AuthorityValidFor(T2, durableAuthority[T2])
    /\ cohort = {}
    /\ headState = "Collecting"
    /\ ~headAttemptEntered
    /\ batchPutCalls = 2
    /\ headPutCalls = 1
    /\ resolutionPutCalls = 0

SiblingAuthorityPending == ~SiblingAuthorityComplete

=============================================================================
