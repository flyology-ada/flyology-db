# Review record

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
