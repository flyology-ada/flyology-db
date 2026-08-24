------------------------- MODULE ImmutableCacheWitness -------------------------
EXTENDS ImmutableCache

(***************************************************************************
This exact witness coalesces two readers on E0, advances authority to E1,
loses an in-flight E1 fetch with all local cache state, retries the still-
pending read, corrupts the recovered E1 cache entry, rejects that corrupt hit,
and fetches the same immutable E1 bytes again.
***************************************************************************)

VARIABLE step
witnessVars == <<vars, step>>

InitWitness == Init /\ cacheCapacity = 1 /\ step = 0

S1  == step = 0  /\ BeginRead(R1)       /\ step' = 1
S2  == step = 1  /\ StartFetch(R1)      /\ step' = 2
S3  == step = 2  /\ BeginRead(R2)       /\ step' = 3
S4  == step = 3  /\ JoinFetch(R2)       /\ step' = 4
S5  == step = 4  /\ CompleteFetch(E0)   /\ step' = 5
S6  == step = 5  /\ FinishRead(R1)      /\ step' = 6
S7  == step = 6  /\ FinishRead(R2)      /\ step' = 7
S8  == step = 7  /\ AdvanceAuthority    /\ step' = 8
S9  == step = 8  /\ BeginRead(R1)       /\ step' = 9
S10 == step = 9  /\ StartFetch(R1)      /\ step' = 10
S11 == step = 10 /\ LocalLoss           /\ step' = 11
S12 == step = 11 /\ StartFetch(R1)      /\ step' = 12
S13 == step = 12 /\ CompleteFetch(E1)   /\ step' = 13
S14 == step = 13 /\ FinishRead(R1)      /\ step' = 14
S15 == step = 14 /\ CorruptCache(E1)    /\ step' = 15
S16 == step = 15 /\ BeginRead(R2)       /\ step' = 16
S17 == step = 16 /\ RejectCorruptHit(R2) /\ step' = 17
S18 == step = 17 /\ StartFetch(R2)      /\ step' = 18
S19 == step = 18 /\ CompleteFetch(E1)   /\ step' = 19

NextWitness ==
    \/ S1 \/ S2 \/ S3 \/ S4 \/ S5 \/ S6 \/ S7 \/ S8 \/ S9 \/ S10
    \/ S11 \/ S12 \/ S13 \/ S14 \/ S15 \/ S16 \/ S17 \/ S18 \/ S19

SpecWitness == InitWitness /\ [][NextWitness]_witnessVars

WitnessComplete ==
    /\ step = 19 /\ lastAction = "CompleteFetch"
    /\ storedEntries = {E0, E1} /\ currentEntry = E1
    /\ cacheValid = {E1} /\ cacheCorrupt = {}
    /\ results[R2] = E1 /\ requested[R2] = E1
    /\ fetchOwner = [e \in Entries |-> NoReader]
    /\ joined = {}

WitnessPending == ~WitnessComplete

WitnessAlias ==
    [action |-> lastAction, step |-> step,
     store |-> storedEntries, current |-> currentEntry,
     cache |-> [valid |-> cacheValid, corrupt |-> cacheCorrupt,
                capacity |-> cacheCapacity],
     fetch |-> fetchOwner, joined |-> joined,
     requested |-> requested, results |-> results]

=============================================================================
