------------------- MODULE AggregateCommitCoalescingProbes -------------------
EXTENDS AggregateCommitCoalescing

(***************************************************************************
Each focused configuration selects exactly one deliberately unsafe action and
its intended failed invariant. These are negative tests, never production Next.
***************************************************************************)

UnsafePartialVisibility(t) ==
    /\ s.online /\ s.phase = "Ready" /\ Width > 1 /\ t \in ActiveMembers
    /\ s' = [s EXCEPT !.visible = @ \cup {t}, !.lastAction = "UnsafePartialVisibility"]

UnsafeReplay(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown"
    /\ ExactAuthority(t, s.liveAuthority[t])
    /\ s' = [s EXCEPT !.resolutionWrites = @ + 1, !.lastAction = "UnsafeReplay"]

UnsafeMemberOnlyResolve(t) ==
    /\ s.online /\ s.receipt[t] = "Unknown"
    /\ StructuralAuthority(t, s.liveAuthority[t])
    /\ LET a == s.liveAuthority[t]
       IN /\ a.batch \in HeadBatches
          /\ a.image.payload[t] = s.images[a.batch].payload[t]
          /\ a.image # s.images[a.batch]
    \* A matching member payload cannot authenticate changed sibling bytes.
    /\ s' = [s EXCEPT !.txn[t] = "Committed", !.receipt[t] = "Committed",
          !.acknowledged = @ \cup {t}, !.lastAction = "UnsafeMemberOnlyResolve"]

UnsafeCancelAdmitted(t) ==
    /\ s.online /\ t \in Pending
    /\ s' = [s EXCEPT
          !.txn[t] = "Cancelled",
          !.receipt[t] = "Failed",
          !.queue = Without(@, t),
          !.excluded = @ \cup {t},
          !.lastAction = "UnsafeCancelAdmitted"]

UnsafeResupply(b) ==
    /\ s.online /\ s.reopened /\ s.offered = NoBatch
    /\ b \in s.usedBatches \ s.stored /\ b \notin s.localBatchIDs
    \* Removing the caller obligation admits an ID that the reopened runtime
    \* cannot distinguish from fresh input. It must fail CallerIdentityContract.
    /\ s' = [s EXCEPT !.offered = b, !.lastAction = "UnsafeResupply"]

UnsafeOrphanOverwrite(b) ==
    /\ s.online /\ s.reopened /\ s.phase = "Idle"
    /\ b \in s.stored \ HeadBatches /\ b \notin s.localBatchIDs
    \* Pretend a repeated create can enter instead of rejecting its key.
    /\ s' = [s EXCEPT !.orphanProbed = @ \cup {b}, !.batchPuts[b] = 2,
                !.lastAction = "UnsafeOrphanOverwrite"]

VisibilityProbeSpec == Init /\ [][Next \/ (\E t \in Txns : UnsafePartialVisibility(t))]_vars
ReplayProbeSpec == Init /\ [][Next \/ (\E t \in Txns : UnsafeReplay(t))]_vars
AuthorityProbeSpec == Init /\ [][Next \/ (\E t \in Txns : UnsafeMemberOnlyResolve(t))]_vars
CancellationProbeSpec == Init /\ [][Next \/ (\E t \in Txns : UnsafeCancelAdmitted(t))]_vars
IdentityProbeSpec == Init /\ [][Next \/ (\E b \in BatchIDs : UnsafeResupply(b))]_vars
OrphanProbeSpec == Init /\ [][Next \/ (\E b \in BatchIDs : UnsafeOrphanOverwrite(b))]_vars

=============================================================================
