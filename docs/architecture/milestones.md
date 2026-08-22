# Milestone plan and acceptance gates

Each milestone completes a focused develop, commit, independent review, fix/amend, and re-review loop. A milestone
is accepted only when its implementation, tests, proof, documentation, dependency provenance, and review record pass.

| Milestone | Acceptance gate | State |
| --- | --- | --- |
| 0 Foundation | Crate, guide, dependency clone/pin, architecture/format/oracle contracts, runners, provenance | In progress |
| 1 Publication | Atomic absent/matching-generation writes, generation reads, reconciliation, provider fault tests | In progress; dependency landed |
| 2 Log-only transactions | Create/open, stable families, pooled cross-family commits, remote recovery | Pending |
| 3 MVCC/isolation | Snapshot and serializable validation, rollback, receipts, controlled concurrency | Pending |
| 4 Memtables/SST | Per-family memtables, validated format, lookup/scan, flush recovery | Pending |
| 5 Caching | Bounded metadata/RAM/disk caches, coalescing, corruption and complete-loss tests | Pending |
| 6 Compaction/retention | Conservative compaction, snapshot retention, atomic manifests, orphan GC | Pending |
| 7 Configuration | Persisted immutable/versioned/ephemeral family settings, TTL and codec gates | Pending |
| 8 Replicas/fencing | Monotonic refresh, catch-up, stale-writer rejection, explicit promotion | Pending |
| 9 Qualification | Full oracle/fault/performance matrices, proof and supported-platform evidence | Pending |

The first implementation unit after foundation is the smallest log-only, remotely durable, multi-column-family
transaction slice. Its required cases are exact CRUD/reopen, cross-family atomicity, cacheless recovery, stale head,
lost response reconciliation, pre/post-publication faults, reference-model agreement, and no unresolved P0/P1 review
finding.
