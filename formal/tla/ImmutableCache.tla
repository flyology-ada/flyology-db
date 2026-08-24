---------------------------- MODULE ImmutableCache ----------------------------
EXTENDS FiniteSets, Naturals, TLC

(***************************************************************************
This finite model freezes a disposable immutable-object cache. Reads capture
the exact current generation, valid cache entries are keyed by that immutable
generation, and one in-flight fetch coalesces all explicitly joined waiters.
Corruption is rejected as a miss and complete local loss clears cache/fetch
state without changing object-store authority. Capacity zero versus one is
finite qualification geometry, not a product default or persisted decision.
No disk layout, eviction order, progress, or refinement to Ada is claimed.
***************************************************************************)

CONSTANTS E0, E1, R1, R2, NoEntry, NoReader

Entries == {E0, E1}
Readers == {R1, R2}
EntryOrNone == Entries \cup {NoEntry}
ReaderOrNone == Readers \cup {NoReader}

ActionNames == {
    "Init", "BeginRead", "CacheHit", "StartFetch", "JoinFetch",
    "CompleteFetch", "FinishRead", "AdvanceAuthority", "CorruptCache",
    "RejectCorruptHit", "EvictCache", "LocalLoss"
}

VARIABLES storedEntries, currentEntry, cacheValid, cacheCorrupt,
    fetchOwner, joined, requested, results, cacheCapacity, lastAction

vars == <<storedEntries, currentEntry, cacheValid, cacheCorrupt,
    fetchOwner, joined, requested, results, cacheCapacity, lastAction>>

Pending(r) == requested[r] # NoEntry /\ results[r] = NoEntry

Init ==
    /\ storedEntries = {E0} /\ currentEntry = E0
    /\ cacheValid = {} /\ cacheCorrupt = {}
    /\ fetchOwner = [e \in Entries |-> NoReader]
    /\ joined = {}
    /\ requested = [r \in Readers |-> NoEntry]
    /\ results = [r \in Readers |-> NoEntry]
    /\ cacheCapacity \in 0 .. 1
    /\ lastAction = "Init"

BeginRead(r) ==
    /\ r \in Readers /\ requested[r] = NoEntry /\ results[r] = NoEntry
    /\ requested' = [requested EXCEPT ![r] = currentEntry]
    /\ lastAction' = "BeginRead"
    /\ UNCHANGED <<storedEntries, currentEntry, cacheValid, cacheCorrupt,
        fetchOwner, joined, results, cacheCapacity>>

CacheHit(r) ==
    /\ r \in Readers /\ Pending(r) /\ requested[r] \in cacheValid
    /\ results' = [results EXCEPT ![r] = requested[r]]
    /\ lastAction' = "CacheHit"
    /\ UNCHANGED <<storedEntries, currentEntry, cacheValid, cacheCorrupt,
        fetchOwner, joined, requested, cacheCapacity>>

StartFetch(r) ==
    /\ r \in Readers /\ Pending(r)
    /\ requested[r] \notin cacheValid /\ requested[r] \notin cacheCorrupt
    /\ fetchOwner[requested[r]] = NoReader
    /\ fetchOwner' = [fetchOwner EXCEPT ![requested[r]] = r]
    /\ lastAction' = "StartFetch"
    /\ UNCHANGED <<storedEntries, currentEntry, cacheValid, cacheCorrupt,
        joined, requested, results, cacheCapacity>>

JoinFetch(r) ==
    /\ r \in Readers /\ Pending(r) /\ r \notin joined
    /\ fetchOwner[requested[r]] \in Readers
    /\ fetchOwner[requested[r]] # r
    /\ joined' = joined \cup {r}
    /\ lastAction' = "JoinFetch"
    /\ UNCHANGED <<storedEntries, currentEntry, cacheValid, cacheCorrupt,
        fetchOwner, requested, results, cacheCapacity>>

CompleteFetch(e) ==
    /\ e \in Entries /\ fetchOwner[e] \in Readers /\ e \in storedEntries
    /\ results' =
         [r \in Readers |->
            IF requested[r] = e
              /\ (r = fetchOwner[e] \/ r \in joined)
            THEN e
            ELSE results[r]]
    /\ fetchOwner' = [fetchOwner EXCEPT ![e] = NoReader]
    /\ joined' = {r \in joined : requested[r] # e}
    /\ cacheValid' = IF cacheCapacity = 0 THEN {} ELSE {e}
    /\ cacheCorrupt' = {}
    /\ lastAction' = "CompleteFetch"
    /\ UNCHANGED <<storedEntries, currentEntry, requested, cacheCapacity>>

FinishRead(r) ==
    /\ r \in Readers /\ results[r] \in Entries
    /\ requested' = [requested EXCEPT ![r] = NoEntry]
    /\ results' = [results EXCEPT ![r] = NoEntry]
    /\ joined' = joined \ {r}
    /\ lastAction' = "FinishRead"
    /\ UNCHANGED <<storedEntries, currentEntry, cacheValid, cacheCorrupt,
        fetchOwner, cacheCapacity>>

AdvanceAuthority ==
    /\ currentEntry = E0
    /\ storedEntries' = storedEntries \cup {E1}
    /\ currentEntry' = E1
    /\ lastAction' = "AdvanceAuthority"
    /\ UNCHANGED <<cacheValid, cacheCorrupt, fetchOwner, joined, requested,
        results, cacheCapacity>>

CorruptCache(e) ==
    /\ e \in cacheValid
    /\ cacheValid' = cacheValid \ {e}
    /\ cacheCorrupt' = cacheCorrupt \cup {e}
    /\ lastAction' = "CorruptCache"
    /\ UNCHANGED <<storedEntries, currentEntry, fetchOwner, joined,
        requested, results, cacheCapacity>>

RejectCorruptHit(r) ==
    /\ r \in Readers /\ Pending(r) /\ requested[r] \in cacheCorrupt
    /\ cacheCorrupt' = cacheCorrupt \ {requested[r]}
    /\ lastAction' = "RejectCorruptHit"
    /\ UNCHANGED <<storedEntries, currentEntry, cacheValid, fetchOwner,
        joined, requested, results, cacheCapacity>>

EvictCache(e) ==
    /\ e \in cacheValid \cup cacheCorrupt
    /\ cacheValid' = cacheValid \ {e}
    /\ cacheCorrupt' = cacheCorrupt \ {e}
    /\ lastAction' = "EvictCache"
    /\ UNCHANGED <<storedEntries, currentEntry, fetchOwner, joined,
        requested, results, cacheCapacity>>

LocalLoss ==
    /\ cacheValid \cup cacheCorrupt # {}
       \/ (\E e \in Entries : fetchOwner[e] \in Readers)
    /\ cacheValid' = {} /\ cacheCorrupt' = {}
    /\ fetchOwner' = [e \in Entries |-> NoReader]
    /\ joined' = {}
    /\ lastAction' = "LocalLoss"
    /\ UNCHANGED <<storedEntries, currentEntry, requested, results,
        cacheCapacity>>

Next ==
    \/ \E r \in Readers : BeginRead(r) \/ CacheHit(r) \/ StartFetch(r)
                              \/ JoinFetch(r) \/ FinishRead(r)
                              \/ RejectCorruptHit(r)
    \/ \E e \in Entries : CompleteFetch(e) \/ CorruptCache(e)
                              \/ EvictCache(e)
    \/ AdvanceAuthority \/ LocalLoss

TypeOK ==
    /\ storedEntries \subseteq Entries /\ currentEntry \in Entries
    /\ cacheValid \subseteq Entries /\ cacheCorrupt \subseteq Entries
    /\ fetchOwner \in [Entries -> ReaderOrNone]
    /\ joined \subseteq Readers
    /\ requested \in [Readers -> EntryOrNone]
    /\ results \in [Readers -> EntryOrNone]
    /\ cacheCapacity \in 0 .. 1 /\ lastAction \in ActionNames

CurrentAuthorityStored == currentEntry \in storedEntries

CacheIsDisposableVerifiedData ==
    /\ cacheValid \subseteq storedEntries
    /\ cacheCorrupt \subseteq storedEntries
    /\ cacheValid \cap cacheCorrupt = {}
    /\ Cardinality(cacheValid \cup cacheCorrupt) <= cacheCapacity

ResultsMatchCapturedAuthority ==
    \A r \in Readers :
        results[r] = NoEntry
        \/ (results[r] = requested[r] /\ results[r] \in storedEntries)

FetchesMatchPendingReads ==
    /\ \A e \in Entries :
          fetchOwner[e] = NoReader
          \/ (Pending(fetchOwner[e]) /\ requested[fetchOwner[e]] = e)
    /\ \A r \in joined :
          Pending(r)
          /\ fetchOwner[requested[r]] \in Readers
          /\ fetchOwner[requested[r]] # r

Safety ==
    /\ TypeOK /\ CurrentAuthorityStored /\ CacheIsDisposableVerifiedData
    /\ ResultsMatchCapturedAuthority /\ FetchesMatchPendingReads

Spec == Init /\ [][Next]_vars

=============================================================================
