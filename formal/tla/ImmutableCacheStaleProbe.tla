---------------------- MODULE ImmutableCacheStaleProbe ----------------------
EXTENDS ImmutableCache

(***************************************************************************
This negative probe returns a valid old-generation cache entry to a read that
captured the new current generation. The normal Next relation excludes this
action; TLC must reject it through ResultsMatchCapturedAuthority.
***************************************************************************)

UnsafeStaleHit(r) ==
    /\ r \in Readers /\ Pending(r)
    /\ requested[r] = E1 /\ E0 \in cacheValid
    /\ results' = [results EXCEPT ![r] = E0]
    /\ lastAction' = "CacheHit"
    /\ UNCHANGED <<storedEntries, currentEntry, cacheValid, cacheCorrupt,
        fetchOwner, joined, requested, cacheCapacity>>

NextWithProbe == Next \/ \E r \in Readers : UnsafeStaleHit(r)
SpecWithProbe == Init /\ [][NextWithProbe]_vars

=============================================================================
