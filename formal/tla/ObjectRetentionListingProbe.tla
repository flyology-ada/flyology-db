--------------------- MODULE ObjectRetentionListingProbe ---------------------
EXTENDS ObjectRetention

(***************************************************************************
This negative probe deletes the complete current reachability set merely
because listing found it and the age boundary marked it old. Normal deletion
rechecks all protection; TLC must reject this action because listing is never
reachability authority.
***************************************************************************)

UnsafeDeleteListedCurrent ==
    /\ current \subseteq listed \cap aged
    /\ stored' = stored \ current
    /\ listed' = listed \ current
    /\ aged' = aged \ current
    /\ deleted' = deleted \cup current
    /\ lastAction' = "DeleteEligible"
    /\ UNCHANGED <<current, snapshotPins, replicaPins, predecessorPins,
        unresolvedPins>>

NextWithProbe == Next \/ UnsafeDeleteListedCurrent
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
