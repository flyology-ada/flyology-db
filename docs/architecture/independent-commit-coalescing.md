# Independent commit coalescing experiment

This document defines a private performance experiment. It is not a public API, default,
compatibility promise, or migration policy. The experiment is new-root-only so an existing
database can never interpret a familiar persisted version with different publication semantics.

## Question

Can independently submitted singleton commits retain their own transaction and immutable batch
identities while amortizing the conditional `meta/HEAD` transition across a bounded cohort?

The experiment keeps each accepted singleton as one complete immutable batch. After ordered
conflict validation, it freezes a cohort, publishes and confirms every member batch, then makes
the complete cohort visible through one conditional HEAD transition. No member succeeds before
that transition is authoritative. Recovery follows and authenticates the complete ordered member
chain; a missing, swapped, duplicated, cross-database, or noncontiguous member rejects recovery.

## Deliberate semantic boundary

Pre-freeze behavior remains independent. Invalid, conflicting, cancelled, expired, or otherwise
rejected work is removed before the cohort is frozen and does not reject another member. The
private runtime experiment rejects finite-deadline operations with `Unsupported_Format` before
coordinator admission or ownership transfer. It does not silently convert them to version-1
publication or promise a maximum wait. An underfilled exact-width cohort waits until enough work
is admitted or the database closes; this is experiment behavior, not public scheduling policy.
Cancellation after existing coordinator admission retains the current Commit rule and cannot
withdraw admitted work. Explicit `Commit_Group` remains a standard-profile operation and is
rejected under this independent-singleton experiment rather than being silently mixed into a
transparent cohort.

Once the single HEAD attempt begins, every frozen member necessarily shares that transition's
success, unknown-response, or conclusive stale/precondition-rejection fate. One authoritative
transition cannot make only part of its cohort visible. This coupling is accepted only for the
private experiment and must not become ordinary Commit policy without a separate product decision.

Every member receipt retains its own transaction ID, logical batch ID, and sequence. An unknown
receipt additionally identifies the shared attempted HEAD range and final-chain commitment. The
authoritative predecessor is derived from that range through the exact global batch chain.
Same-receipt resolution authenticates the reachable cohort chain read-only and performs no batch
or HEAD write. The first conclusive successful resolution establishes the shared HEAD transition;
every other member receipt remains independently consumable and resolvable from the authenticated
published cohort. Durable authority export/import must bind both member and cohort identity and
reject malformed, swapped, or wrong-database authority without changing the destination.

## Publication and failure ordering

1. Admit and conflict-check candidates in global sequence order, including intra-cohort conflicts.
2. Freeze the exact nonempty cohort and tentatively assign contiguous sequences.
3. Publish member batches in order. An ambiguous immutable Put is resolved by one exact read before
   proceeding. If any member fails before the HEAD attempt, fail every member of the frozen cohort,
   publish no HEAD, and leave any confirmed prefix objects unreachable. No suffix is parked,
   resequenced, or retried under a different identity. A direct immutable-key precondition failure
   or conflicting complete read is an identity collision and fences the writer; other pre-HEAD
   failures leave it available for later independent work.
4. Publish one conditional HEAD from the exact predecessor to the cohort's final member and range.
5. Return success only after the HEAD is confirmed. A lost accepted response returns an independent
   unknown receipt for every member; a conclusive precondition failure fences immediately.
6. Resolve unknown receipts without publication. Crash recovery starts from HEAD and installs the
   complete exact cohort or rejects it.

Sequential member publication is the first ownership-safe implementation. It bounds in-flight
ownership and keeps the whole-cohort failure cut before HEAD. Parallel immutable publication is a
separate experiment because it needs an explicit orphan and cancellation-cleanup policy.

## Assurance and promotion boundary

The finite TLA+ model covers independent admission, pre-freeze rejection, exact cohort membership,
ambiguous member publication, whole-cohort pre-HEAD failure, all-or-none HEAD visibility, lost
responses, fencing, crash, finite-deadline rejection, durable-authority transfer, read-only
resolution, and exact recovery. Its
four transactions and bounded cohort schedule are qualification geometry, not product limits. The
TLAPS kernel proves the central
all-or-none acknowledgement, no-replay, pre-freeze exclusion, and recovery invariants over an
arbitrary transaction set. Its fencing action abstracts immediate publication/precondition
rejection; finite TLC witnesses separately cover a conclusive successor after an unentered unknown
HEAD result. Neither artifact proves byte formats, provider behavior, Ada ownership, progress, or
refinement.

Runtime promotion requires a distinct experimental persisted profile, corruption and recovery
tests, durable-authority format tests, maintained deterministic and provider gates, and matched
same-host benchmarks. The median improvement must be at least 20 percent and the lower confidence
bound must exceed 10 percent without weakening durability, work, reopen verification, or final
state identity.

The reserved persisted selector is checkpoint-manifest version 4 with profile code `1`. Ordinary
`Standard_Publication` roots continue to encode as manifest version 3; version 4 accepts only the
`Independent_Coalescing` selector. This records semantic compatibility without freezing a cohort
width. Width is the sole private runtime experiment input and must be reported with every benchmark;
the initial exact-width design deliberately has no admission timer or wait window.

The private testing bridge may enable a caller-selected exact width bounded by the persisted
history capacity and coordinator slots on an empty independent-profile root. Qualification samples
widths 1, 2, 4, and 8; those values are not an implementation allowlist or a hardware-independent
choice. Zero keeps the publisher disabled. The width is neither persisted nor public, and changing
it requires an idle coordinator. There is no mixed version-1 fallback for an independent-profile
root.

Durable authority for this profile uses envelope version 2 around one exact batch-v2 singleton.
Import is deliberately local and structural: it authenticates the envelope, member identity,
format pair, database/profile binding, HEAD relation, and retained-history bound without issuing a
provider request. Read-only Resolve then authenticates the maximal contiguous same-publication
cohort in recovered history, including both outer boundaries, before any member can become
committed. The finite model's structurally valid imported authority corresponds to those local
checks; its resolved-valid predicate corresponds to the later recovered-chain authentication.

An unresolved authority therefore depends on the exact cohort chain remaining within the
authenticated retained batch-history window. Explicit maintenance cannot be treated as authority
migration: callers must resolve or retain the required cohort history before a later checkpoint
could move that chain beyond the recoverable boundary. This is an experimental recovery boundary,
not an automatic retention policy or a production durability claim.
