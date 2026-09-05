--------- MODULE IndependentCommitCoalescingEmptyRecoveryWitness ---------
EXTENDS IndependentCommitCoalescing

EmptyRecoveryComplete ==
    /\ lastAction = "RecoverCohortChain"
    /\ crashObserved
    /\ headState = "Unknown"
    /\ ~headAttemptEntered
    /\ visible = {}
    /\ sequence = 0
    /\ recovered = {}
    /\ recoveryImage.members = {}
    /\ recoveryImage.final = NoTxn
    /\ batchPutCalls = 1
    /\ headPutCalls = 1
    /\ resolutionPutCalls = 0

EmptyRecoveryPending == ~EmptyRecoveryComplete

=============================================================================
