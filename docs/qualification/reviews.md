# Review record

## Accepted first-LSM exact-format candidate

- Parent: constants-skill agent-resource refresh `59597cbadf17d8f43c03192bd1aeccddf644248e`.
- Scope: exact immutable checkpoint-manifest-v2 and SST-v1 bytes, private bounded SPARK reference codecs, independent
  golden generation, corruption/cap/lower-bound tests, and proof-project integration. It does not activate checkpoint
  publication, production dynamic decoding, recovery, compaction, remote providers, or composable I/O.
- Constant authority: every consequential new persisted, derived, proof, fixture, and test value has an adjacent
  stable source comment identifying its role, authority/classification, and compatibility effect. Generic capacities
  are explicitly reference/proof representation dimensions; persisted database and family limits remain the later
  operational allocation authority.
- Verification: `./tests/scripts/test.sh` passes repository checks, the deterministic Ada format/policy/model/local
  engine, files crash/recovery, 32 comparative cases, and the pinned TidesDB 4/4 set with no compiler warning. The
  final warning-strict FSF GNATprove 16.1.0 widening proves 1,078/1,078 checks (164 flow and 914 prover) with zero
  warnings, unproved or justified checks, or `pragma Assume`. The independent Python generator reproduces the frozen
  358-byte manifest and 164-byte SST images.
- Findings cycle: the first sweep found two P2 issues and one P3 issue. Unused family LSM slots could hold nonzero
  state that the encoder silently omitted, the TLA+ README still described the now-decodable reference formats as
  future, and one private decode status was unreachable. The amendment requires canonical zero family tails and
  tests the rejection, aligns the formal boundary wording, removes the dead status, and also exercises successful
  decoding from nonzero array lower bounds. Follow-up review finds no remaining P0, P1, P2, or P3 issue.

## Pending first-LSM checkpoint model/design candidate

- Parent: owned synchronous byte-spine candidate `c909c57227596a49e4d4dedd793fd615e15bd149`.
- Scope: a staged future manifest-v2/SST semantic decision, bounded two-family checkpoint-publication TLC model,
  committed/rejected/cacheless-recovery witness validation, four integrated unsafe-action probes, and a smaller
  unbounded TLAPS safety kernel.
- Boundary: this candidate changes no Ada production code or current supported persisted-format version. It freezes
  no binary offsets or golden bytes and does not implement memtables, SST reads, flush, compaction, scans, GC, remote
  providers, or composable I/O. The proof kernel is not a codec or implementation refinement proof.
- Verification status: the focused lane exhausts 819 TLC states at depth 19, validates three deterministic witnesses,
  pins nonzero coverage for every normal action, rejects four integrated unsafe-action probes, and proves all 43
  strict TLAPS obligations. The repository-shape gate also passes. Independent review remains pending; no acceptance
  claim is made.

## Accepted owned synchronous byte-spine candidate

- Parent: accepted operational HEAD-v2/root-family commit `6b9f29fd5a4f9df6395ed2f8bafb8e34effd9610`.
- Scope: borrowed public byte-array mutation input, owned unbounded Get output, dynamically sized transaction/state/
  identity/history descriptors, exact reference-counted immutable batch images, offset/view live state, and
  allocation-failure classification for the synchronous memory/files engine.
- Evidence: `tests/scripts/test.sh` covers deterministic memory/files 20/400 and 4 KiB/1 MiB CRUD/group/cacheless
  reopen, exact/one-over family/transaction/batch/live budgets, 257-mutation/live-entry dynamic tables, whole-image
  ownership accounting, injected allocation failures, subprocess crash/recovery, and pinned TidesDB conformance.
  The repository gate and unchanged TLA+/TLAPS gate pass. A root-owned warning-strict GNATprove run proves 643/643
  checks across the five selected format/policy/reference units with zero warnings, unproved/justified checks, or
  `pragma Assume`.
- Review of exact candidate `defa21e` rejected two P1 and two P2 findings: Resolve could wait behind queued callers'
  lifecycle leases, the runtime decoder could allocate from structurally impossible admitted counts, group mutation
  totals narrowed through U32 before a wider-`Natural` guard, and proof/milestone wording overstated the selected-unit
  boundary. The amendment drains queued slots before resolution quiescence, rejects impossible framing before image
  allocation, validates the group wire width before conversion, and narrows the documentation. Committed and rejected
  resolution campaigns include queued singleton/group work. Independent re-review accepted exact amended commit
  `c909c57227596a49e4d4dedd793fd615e15bd149` with no P0, P1, P2, or P3 findings; local `main` was fast-forwarded to
  that commit.

## Pending operational HEAD-v2 root-family candidate

- Parent: accepted manifest-v1 format/policy commit `a02a569a932230ed28c4559c17f9352d94410007`.
- Scope: explicit create-time database/family limits, canonical root-manifest publication, version-aware HEAD
  inspection, operational HEAD-v2 Create/Open/recovery, stable ID/name family handles, and manifest-aware commit and
  replay validation over the existing provider-neutral synchronous engine.
- Boundary: this candidate does not add dynamic family changes, owned large-value arenas, SST/LSM state,
  authenticated S3 binding, composable provider operations, or full Milestone 2 acceptance. HEAD v1 is inspection
  only and has no migration path in this unit.
- Verification status: `./tests/scripts/test.sh` passes the deterministic memory/files engine, repository checks,
  three files subprocess crash/restart boundaries, and the pinned TidesDB suite. Focused cases cover canonical family
  permutations, exact name/ID and stale/cross-database handles, lower persisted limits, manifest ambiguity and local
  activation failure, legacy HEAD rejection, missing/corrupt/wrong-identity/over-cap manifests, and cacheless
  manifest-first replay. The unchanged selected proof-unit tree carries the root-owned warning-strict 644/644 result
  recorded in `proof-status.md`; independent re-review is pending and no acceptance is claimed.
- Independent-review amendment: the first candidate classified every non-exact observed create HEAD as a competing
  creator, rejected valid exact-cap overwrites through conservative Put counts, and allowed delayed create resolution
  to trust retained manifest bytes without rereading the immutable object. The pending amendment validates the full
  manifest-first and batch chain and its exact root ancestor before accepting a later HEAD, collapses each batch to
  its final last-write-wins image before applying live entry/byte caps, and requires an authoritative whole-manifest
  byte match for every resumable create phase. Additional closures distinguish unsupported HEAD versions, freeze an
  independent HEAD-v2
  golden and repaired semantic corruption, gate the exact manifest-key prefix boundary, and remove unused manifest
  read diagnostics. Independent re-review remains required.

## Accepted additive manifest-v1 candidate

- Parent: accepted TidesDB comparative-adapter commit `a641f89157a64a48142f041db5b40c0dfcee3a07`.
- Scope: private manifest-v1 codec/policy, independent golden and corruption/cap tests, future HEAD-v2 publication
  predicates, and a focused TLC/TLAPS registry-publication model.
- Boundary: this candidate does not activate operational manifests, change public Create/Open, qualify a remote
  provider, allocate production transaction arenas, or claim full Milestone 2 acceptance.
- Accepted candidate: `a02a569a932230ed28c4559c17f9352d94410007`.
- Verification status: deterministic Ada and repository tests plus the combined TLC/TLAPS gate are green. The final
  amended, rebased five-unit warning-strict SPARK gate proves 639/639 checks: 114 flow checks and 525 prover checks,
  with zero warnings, unproved or justified checks, or `pragma Assume` statements. Independent re-review remains
  complete. Independent re-review accepted the exact candidate before fast-forward integration.
- Initial independent-review findings: an exact or immediate-successor recovery reference did not bind the HEAD
  predecessor identity; transaction count could exceed the total batch mutation count; fixed family-name tails were
  not canonicalized; and decoder precedence wording omitted the total representation-admission check. The amended
  candidate binds both recovery edges, enforces the count relation, rejects nonzero name tails, and aligns the spec,
  tests, and format document with the implementation's admission order.

## Accepted local-provider log-only slice

- Parent: accepted Slate/pooling contract commit `865f02e20be129c73b15e26d73570e6168ea16e5`.
- Accepted implementation candidate: `7387c66ab173d647494c282edf3fbbb0f55189d1`.
- Scope: provider-neutral memory/files adapter, bounded native group coordinator, log-only publication/recovery,
  provisional numeric-family CRUD, receipts, and deterministic storage faults.
- Acceptance boundary: this candidate does not claim authenticated remote-provider qualification, stable family
  creation authority, full Milestone 2 acceptance, MVCC isolation, or production durability/performance.
- Verification: on the final rebased source, `./scripts/check-repository.sh` validates canonical-state vectors,
  workloads, provenance, and repository shape; `./scripts/check-tla.sh` reports 112,031 TLC states at depth 14 and
  23/23 TLAPS obligations; and `./tests/scripts/test.sh` passes against memory/files, including a fresh-process files
  group crash/reopen probe. The warning-strict `./scripts/prove.sh` gate proves 421/421 checks: 84 flow and 337
  prover checks, with zero reported warnings, unproved or justified checks, or `pragma Assume` statements. The SPARK
  boundary is limited to selected deterministic packages documented in `proof-status.md`; storage I/O, lifecycle
  synchronization, and tasking are executable-test boundaries.
- Review status: accepted. The first implementation revision was rejected with P1 lifecycle, admission,
  reconciliation, deadline-isolation, identity, cap, and fault-evidence findings. Follow-up amendments reserve every
  admitted group/member identity, serialize shared storage-context fault controls and counters with a protected
  object, retain receipt identities on every admitted terminal path, and reject transaction-local reads and mutation
  buffering after a writer fence or uncertain publication. Expanded executable gates cover the 576-identity
  reservation boundary, a concurrent two-database shared-context case, and active read, buffered mutation,
  singleton/group admission, rollback, resolution, and recovery while a lost HEAD response leaves publication
  uncertain. Independent final re-review of the exact accepted candidate against the stated parent reports no
  P0, P1, P2, or P3 findings.

## Foundation root commit

- Parent: empty tree.
- Reviewer: independent read-only task `/root/foundation_review`.
- First reviewed revision: `c63cc5125c33c3ed256eaef100858d370f614e18`.
- First amended revision: `0ead79a74deb60d6400ab29262f81287814bb78c`.
- Final amended revision: `8b9ff8c338e4ffb346b0a18ff234646671dd2fd5`.
- Initial P1 findings: unreachable older batches, structurally unreachable HEAD images, and reconciliation dependent
  on unenforced transition-ID nonreuse.
- Initial P2/P3 findings: incomplete format corruption/golden coverage, overstated proof claims, permissive workload
  records, unassertive recovery workload, exposed internal children, own-write/read-capacity ordering, and unused
  AUnit.
- First follow-up P1 finding: an `Outcome_Unknown` commit remained replayable and receipt resolution was unrelated to
  the attempted transaction.
- First follow-up P2/P3 findings: equal transition/predecessor IDs remained structurally accepted, schema/validator
  drift was ungated, and planned tasking was described as implemented.
- Disposition: commit batches now require predecessor links; HEAD transitions carry monotonic ordinals and fail closed
  on unreachable shapes; reconciliation binds ID and ordinal; private units, exhaustive length/corruption tests, a
  fixed golden image, exact range deduplication, own-write ordering, operation-specific schema rules, schema-rule
  equivalence checks, receipt lifecycles, no-replay negative traces, and asserted recovery workloads were added.
  Proof documentation was narrowed, full range-union normalization was assigned to Milestone 3, and AUnit was removed.
- Verification: `./tests/scripts/test.sh`, `./scripts/prove.sh`, `./scripts/check-repository.sh`, and
  `git diff --check` pass. The current SPARK gate proves every reported check with no warning or unproved check.
- Follow-up status: accepted. The independent reviewer reported no P0, P1, P2, or P3 findings and reran every listed
  gate against the exact final revision with clean root and dependency worktrees.
