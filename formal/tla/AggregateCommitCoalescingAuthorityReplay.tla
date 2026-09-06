------------- MODULE AggregateCommitCoalescingAuthorityReplay -------------
EXTENDS FlyologyHarness, Naturals, Sequences

(***************************************************************************
Observable-boundary abstraction of AggregateCommitCoalescing's accepted HEAD
authority witness. CommitUnknown groups SupplyAggregateID, two AdmitSingleton
actions, FreezeCohort, PublishAggregate("Confirmed"), and
PublishHead("UnknownAccepted"). The adapter submits two independent real Ada
Commit operations and observes their completed receipts; it cannot stop the
coordinator at the model's internal publication phases.

The eight transitions below select one deterministic qualification witness,
not a scheduler, fairness assumption, or progress guarantee. The identities,
two single-byte keys/values, width, and ordinal are private fixture geometry.
CloseAndForget drops the complete quiescent Ada session after exporting both
authorities. The backend and caller-owned export bytes survive. This is not
an abrupt-process-crash or interruption-inside-Commit witness. The richer
model and its TLAPS kernel remain separate assurance artifacts; replay of
this abstraction is not an Ada refinement proof.
***************************************************************************)

Members == 1..2
TransactionNumbers == <<61001, 61002>>
FirstBatchOrdinal == 1000000
WholeImage ==
    <<[transaction |-> TransactionNumbers[1], sequence |-> 1, key |-> 1, value |-> 1],
      [transaction |-> TransactionNumbers[2], sequence |-> 2, key |-> 2, value |-> 2]>>
EmptyAuthority == [member |-> 0, image |-> <<>>]
EmptyReceipt == [result |-> "Invalid_State", transaction |-> 0, sequence |-> 0, batch |-> 0]
MemberReceipt(member, result) ==
    [result |-> result, transaction |-> TransactionNumbers[member],
     sequence |-> member, batch |-> FirstBatchOrdinal]

VARIABLE s
vars == <<s>>

Init ==
    s = [step |-> 0, action |-> "Init", member |-> 0, result |-> "Success",
         online |-> TRUE, forgotten |-> FALSE, reopened |-> FALSE,
         storedImage |-> <<>>, receipts |-> <<EmptyReceipt, EmptyReceipt>>,
         authorities |-> <<EmptyAuthority, EmptyAuthority>>,
         recovered |-> <<0, 0>>, highest |-> 0,
         batchPuts |-> 0, runPuts |-> 0, manifestPuts |-> 0, headPuts |-> 0,
         resolutionWrites |-> 0]

CommitUnknown ==
    /\ s.step = 0 /\ s.online
    /\ s' = [s EXCEPT !.step = 1, !.action = "CommitUnknown", !.member = 0,
          !.result = "Outcome_Unknown", !.storedImage = WholeImage,
          !.receipts = <<MemberReceipt(1, "Outcome_Unknown"),
                        MemberReceipt(2, "Outcome_Unknown")>>,
          !.batchPuts = 1, !.headPuts = 1]

ExportAuthority(member) ==
    /\ s.step \in {1, 2} /\ member = s.step /\ s.online
    /\ s.receipts[member].result = "Outcome_Unknown"
    /\ s.storedImage = WholeImage
    /\ s' = [s EXCEPT !.step = @ + 1, !.action = "ExportAuthority", !.member = member,
          !.result = "Success", !.authorities[member] = [member |-> member, image |-> s.storedImage]]

CloseAndForget ==
    /\ s.step = 3 /\ s.online
    /\ \A member \in Members : s.authorities[member].image = WholeImage
    /\ s' = [s EXCEPT !.step = 4, !.action = "CloseAndForget", !.member = 0,
          !.result = "Success", !.online = FALSE, !.forgotten = TRUE,
          !.receipts = <<EmptyReceipt, EmptyReceipt>>]

ReopenFromHead ==
    /\ s.step = 4 /\ ~s.online /\ s.storedImage = WholeImage
    /\ s' = [s EXCEPT !.step = 5, !.action = "ReopenFromHead", !.member = 0,
          !.result = "Success", !.online = TRUE, !.reopened = TRUE,
          !.recovered = <<s.storedImage[1].value, s.storedImage[2].value>>,
          !.highest = Len(s.storedImage)]

ImportAuthority(member) ==
    /\ s.step \in {5, 6} /\ member = s.step - 4 /\ s.online
    /\ s.receipts[member] = EmptyReceipt
    /\ s.authorities[member] = [member |-> member, image |-> WholeImage]
    /\ s' = [s EXCEPT !.step = @ + 1, !.action = "ImportAuthority", !.member = member,
          !.result = "Success", !.receipts[member] = MemberReceipt(member, "Outcome_Unknown")]

ResolveMember ==
    /\ s.step = 7 /\ s.online /\ s.reopened
    /\ s.authorities[1].image = s.storedImage
    /\ s.receipts[1] = MemberReceipt(1, "Outcome_Unknown")
    /\ s' = [s EXCEPT !.step = 8, !.action = "ResolveMember", !.member = 1,
          !.result = "Success", !.receipts[1] = MemberReceipt(1, "Success")]

Next ==
    CommitUnknown \/ (\E member \in Members : ExportAuthority(member))
    \/ CloseAndForget \/ ReopenFromHead
    \/ (\E member \in Members : ImportAuthority(member)) \/ ResolveMember

Spec == Init /\ [][Next]_vars

FullAuthority(member) ==
    s.authorities[member] = [member |-> member, image |-> WholeImage]

TypeOK ==
    /\ s.step \in 0..8 /\ s.member \in 0..2
    /\ s.action \in {"Init", "CommitUnknown", "ExportAuthority", "CloseAndForget",
                       "ReopenFromHead", "ImportAuthority", "ResolveMember"}
    /\ s.result \in {"Success", "Outcome_Unknown"}
    /\ s.online \in BOOLEAN /\ s.forgotten \in BOOLEAN /\ s.reopened \in BOOLEAN
    /\ s.storedImage \in {<<>>, WholeImage}
    /\ Len(s.receipts) = 2 /\ Len(s.authorities) = 2
    /\ \A member \in Members :
           /\ s.receipts[member] \in {EmptyReceipt, MemberReceipt(member, "Outcome_Unknown"),
                                       MemberReceipt(member, "Success")}
           /\ s.authorities[member] = EmptyAuthority \/ FullAuthority(member)
    /\ s.recovered \in {<<0, 0>>, <<1, 2>>} /\ s.highest \in {0, 2}
    /\ s.batchPuts \in 0..1 /\ s.headPuts \in 0..1
    /\ s.runPuts = 0 /\ s.manifestPuts = 0 /\ s.resolutionWrites = 0

Safety ==
    /\ TypeOK
    /\ s.headPuts <= s.batchPuts
    /\ s.headPuts = 1 <=> s.storedImage = WholeImage
    /\ s.reopened => s.forgotten /\ s.recovered = <<1, 2>> /\ s.highest = 2
    /\ \A member \in Members : s.receipts[member].result = "Success" =>
           s.storedImage = WholeImage /\ FullAuthority(member)

WitnessComplete ==
    /\ s.step = 8 /\ s.forgotten /\ s.reopened
    /\ s.receipts = <<MemberReceipt(1, "Success"), MemberReceipt(2, "Outcome_Unknown")>>
    /\ FullAuthority(1) /\ FullAuthority(2)
    /\ s.recovered = <<1, 2>> /\ s.highest = 2
    /\ s.batchPuts = 1 /\ s.headPuts = 1 /\ s.resolutionWrites = 0

WitnessPending == ~WitnessComplete

HarnessInput ==
    [width |-> 2, first_batch_ordinal |-> FirstBatchOrdinal,
     transaction_1 |-> TransactionNumbers[1], transaction_2 |-> TransactionNumbers[2],
     key_1 |-> 1, key_2 |-> 2, value_1 |-> 1, value_2 |-> 2, member |-> s.member]

HarnessOutcome == [result |-> s.result]

HarnessState ==
    [online |-> s.online, forgotten |-> s.forgotten, reopened |-> s.reopened,
     receipts |-> s.receipts,
     exported |-> <<s.authorities[1] # EmptyAuthority, s.authorities[2] # EmptyAuthority>>,
     full_authority |-> <<FullAuthority(1), FullAuthority(2)>>,
     shared_image |-> FullAuthority(1) /\ FullAuthority(2)
                         /\ s.authorities[1].image = s.authorities[2].image,
     recovered |-> s.recovered, highest |-> s.highest,
     batch_puts |-> s.batchPuts, run_puts |-> s.runPuts,
     manifest_puts |-> s.manifestPuts, head_puts |-> s.headPuts,
     resolution_writes |-> s.resolutionWrites]

lastAction == s.action
HarnessAlias ==
    TraceAlias(lastAction, "aggregate-authority-recovery", HarnessInput, HarnessOutcome, HarnessState)

=============================================================================
