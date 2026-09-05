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
rejected work is removed before the cohort is frozen and does not reject another member. The first
prototype does not admit finite-deadline operations into a cohort; those operations retain the
current singleton path. Cancellation after existing coordinator admission retains the current
Commit rule and cannot withdraw admitted work.

Once the single HEAD attempt begins, every frozen member necessarily shares that transition's
success, unknown-response, or conclusive stale/precondition-rejection fate. One authoritative
transition cannot make only part of its cohort visible. This coupling is accepted only for the
private experiment and must not become ordinary Commit policy without a separate product decision.

Every member receipt retains its own transaction ID, logical batch ID, and sequence. An unknown
receipt additionally identifies the shared attempted HEAD range and final-chain commitment. The
authoritative predecessor is derived from that range through the exact global batch chain.
Same-receipt resolution authenticates the reachable cohort chain read-only and performs no batch
or HEAD write. The first conclusive successful resolution establishes the shared HEAD transition
and releases parked suffix work; every other member receipt remains independently consumable and
resolvable from the authenticated published cohort. Durable authority export/import must bind
both member and cohort identity and reject malformed, swapped, or wrong-database authority without
changing the destination.

## Publication and failure ordering

1. Admit and conflict-check candidates in global sequence order, including intra-cohort conflicts.
2. Freeze the exact nonempty cohort and tentatively assign contiguous sequences.
3. Publish member batches in order. An ambiguous immutable Put is resolved by exact read before
   proceeding. If a member fails before the HEAD attempt, reject only that member: a confirmed
   prefix may proceed to HEAD, while the untouched suffix returns to admission and receives new
   tentative sequences after that prefix. When the prefix is nonempty, the suffix remains parked
   until the prefix HEAD is resolved: confirmed publication releases it for resequencing, while a
   conclusive stale or precondition rejection fails it under the same fence. No immutable successor
   is rewritten, and parked work never receives an unknown-publication receipt.
4. Publish one conditional HEAD from the exact predecessor to the cohort's final member and range.
5. Return success only after the HEAD is confirmed. A lost accepted response returns an independent
   unknown receipt for every member; a conclusive precondition failure fences immediately.
6. Resolve unknown receipts without publication. Crash recovery starts from HEAD and installs the
   complete exact cohort or rejects it.

Sequential member publication is the first ownership-safe implementation. Besides bounding
in-flight ownership, it permits the failed-member split above without rewriting an already stored
successor. Parallel immutable publication is a separate experiment because it needs an explicit
orphan, relinking, and cancellation-cleanup policy.

## Assurance and promotion boundary

The finite TLA+ model covers independent admission, pre-freeze rejection, exact cohort membership,
ambiguous member publication, all-or-none HEAD visibility, lost responses, fencing, crash,
parked-suffix state and terminal fate, durable-authority transfer, read-only resolution, and exact
recovery. Its
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
width or admission delay. Those two values remain explicit private runtime experiment inputs and
must be reported with every benchmark.
