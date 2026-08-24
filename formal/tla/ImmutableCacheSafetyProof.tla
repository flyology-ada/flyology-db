----------------------- MODULE ImmutableCacheSafetyProof -----------------------
EXTENDS Naturals

(***************************************************************************
This unbounded kernel treats immutable entries and readers as arbitrary sets.
Requests capture an exact entry, a set contains at most one in-flight fetch
for each entry, and completion serves every request for that exact entry.
Only stored entries can be current, cached, fetched, or returned. Corruption,
eviction, and complete local loss remove local state without changing remote
authority or completed exact-generation results. Concrete capacity arithmetic,
bytes, checksums, eviction order, progress, and refinement to Ada are outside
this proof and remain finite-model or implementation gates.
***************************************************************************)

CONSTANTS Entries, Readers, InitialEntry

ASSUME /\ Entries # {} /\ Readers # {} /\ InitialEntry \in Entries

Pairs == Readers \X Entries

VARIABLES stored, current, validCache, corruptCache, fetching,
    requests, results

vars == <<stored, current, validCache, corruptCache, fetching,
    requests, results>>

Init ==
    /\ InitialEntry \in Entries
    /\ stored = {InitialEntry} /\ current = InitialEntry
    /\ validCache = {} /\ corruptCache = {} /\ fetching = {}
    /\ requests = {} /\ results = {}

Store(e) ==
    /\ e \in Entries \ stored
    /\ stored' = stored \cup {e}
    /\ UNCHANGED <<current, validCache, corruptCache, fetching,
        requests, results>>

Advance(e) ==
    /\ e \in stored
    /\ current' = e
    /\ UNCHANGED <<stored, validCache, corruptCache, fetching,
        requests, results>>

BeginRead(r) ==
    /\ r \in Readers
    /\ requests' = requests \cup {<<r, current>>}
    /\ UNCHANGED <<stored, current, validCache, corruptCache, fetching,
        results>>

StartFetch(e) ==
    /\ e \in stored /\ e \notin fetching
    /\ e \notin validCache /\ e \notin corruptCache
    /\ \E r \in Readers :
          <<r, e>> \in requests /\ <<r, e>> \notin results
    /\ fetching' = fetching \cup {e}
    /\ UNCHANGED <<stored, current, validCache, corruptCache,
        requests, results>>

CacheHit(r, e) ==
    /\ <<r, e>> \in requests /\ e \in validCache
    /\ results' = results \cup {<<r, e>>}
    /\ UNCHANGED <<stored, current, validCache, corruptCache, fetching,
        requests>>

CompleteFetch(e) ==
    /\ e \in fetching
    /\ results' = results \cup {p \in requests : p[2] = e}
    /\ validCache' = validCache \cup {e}
    /\ corruptCache' = corruptCache \ {e}
    /\ fetching' = fetching \ {e}
    /\ UNCHANGED <<stored, current, requests>>

FinishRead(r, e) ==
    /\ <<r, e>> \in results /\ e \notin fetching
    /\ requests' = requests \ {<<r, e>>}
    /\ results' = results \ {<<r, e>>}
    /\ UNCHANGED <<stored, current, validCache, corruptCache, fetching>>

Corrupt(e) ==
    /\ e \in validCache
    /\ validCache' = validCache \ {e}
    /\ corruptCache' = corruptCache \cup {e}
    /\ UNCHANGED <<stored, current, fetching, requests, results>>

RejectCorrupt(e) ==
    /\ e \in corruptCache
    /\ corruptCache' = corruptCache \ {e}
    /\ UNCHANGED <<stored, current, validCache, fetching,
        requests, results>>

Evict(e) ==
    /\ e \in validCache \cup corruptCache
    /\ validCache' = validCache \ {e}
    /\ corruptCache' = corruptCache \ {e}
    /\ UNCHANGED <<stored, current, fetching, requests, results>>

LocalLoss ==
    /\ validCache \cup corruptCache \cup fetching # {}
    /\ validCache' = {} /\ corruptCache' = {} /\ fetching' = {}
    /\ UNCHANGED <<stored, current, requests, results>>

TypeOK ==
    /\ stored \subseteq Entries /\ current \in Entries
    /\ validCache \subseteq Entries /\ corruptCache \subseteq Entries
    /\ fetching \subseteq Entries
    /\ requests \subseteq Pairs /\ results \subseteq Pairs

CurrentAuthorityStored == current \in stored

CacheContainsOnlyStoredEntries ==
    /\ validCache \subseteq stored /\ corruptCache \subseteq stored
    /\ validCache \cap corruptCache = {}

FetchesAreExactAndCoalesced ==
    /\ fetching \subseteq stored
    /\ \A e \in fetching : \E r \in Readers : <<r, e>> \in requests

ResultsMatchCapturedRequests ==
    /\ results \subseteq requests
    /\ \A p \in results : p[2] \in stored

Safety ==
    /\ TypeOK /\ CurrentAuthorityStored
    /\ CacheContainsOnlyStoredEntries /\ FetchesAreExactAndCoalesced
    /\ ResultsMatchCapturedRequests

THEOREM InitialSafety == Init => Safety
<1> QED BY DEF Init, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM StorePreservesSafety ==
    \A e \in Entries : Safety /\ Store(e) => Safety'
<1> QED BY DEF Store, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM AdvancePreservesSafety ==
    \A e \in Entries : Safety /\ Advance(e) => Safety'
<1> QED BY DEF Advance, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM BeginReadPreservesSafety ==
    \A r \in Readers : Safety /\ BeginRead(r) => Safety'
<1> QED BY DEF BeginRead, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM StartFetchPreservesSafety ==
    \A e \in Entries : Safety /\ StartFetch(e) => Safety'
<1> QED BY DEF StartFetch, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM CacheHitPreservesSafety ==
    \A r \in Readers : \A e \in Entries :
        Safety /\ CacheHit(r, e) => Safety'
<1> QED BY DEF CacheHit, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM CompleteFetchPreservesSafety ==
    \A e \in Entries : Safety /\ CompleteFetch(e) => Safety'
<1> QED BY DEF CompleteFetch, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM FinishReadPreservesSafety ==
    \A r \in Readers : \A e \in Entries :
        Safety /\ FinishRead(r, e) => Safety'
<1> QED BY DEF FinishRead, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM CorruptPreservesSafety ==
    \A e \in Entries : Safety /\ Corrupt(e) => Safety'
<1> QED BY DEF Corrupt, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM RejectCorruptPreservesSafety ==
    \A e \in Entries : Safety /\ RejectCorrupt(e) => Safety'
<1> QED BY DEF RejectCorrupt, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM EvictPreservesSafety ==
    \A e \in Entries : Safety /\ Evict(e) => Safety'
<1> QED BY DEF Evict, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM LocalLossPreservesSafety == Safety /\ LocalLoss => Safety'
<1> QED BY DEF LocalLoss, Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, Pairs

THEOREM QuiescencePreservesSafety ==
    Safety /\ UNCHANGED vars => Safety'
<1> QED BY DEF Safety, TypeOK, CurrentAuthorityStored,
    CacheContainsOnlyStoredEntries, FetchesAreExactAndCoalesced,
    ResultsMatchCapturedRequests, vars

=============================================================================
