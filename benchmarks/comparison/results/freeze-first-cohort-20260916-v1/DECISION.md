# Raw-cohort freeze screen: no-go at the 1 ms profile

## Scope and result

This is an exploratory x86_64 success-path experiment, not a production change or a
cross-architecture qualification. It uses the exact 35-transaction, 256-mutation,
16-byte-key, 1024-byte-value sustained workload against tuned SlateDB. Every measured
execution reopened and verified 11,008 keys at digest
`090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb`.
Two reversed-order rounds used the maintained ten-sample, internally balanced paired
collector for each comparison. The benchmark's **primary transaction-window time**,
not whole-process wall time, is the decision metric.

| Round | SlateDB / raw 1 worker, 1 cohort | Raw 1/1 / raw 2 workers, 2 cohorts | SlateDB / raw 2/2 |
|---|---:|---:|---:|
| 1 | 23.442 / 57.262 ms | 56.603 / 73.084 ms | 23.812 / 71.940 ms |
| 2, reversed | 24.532 / 56.874 ms | 56.968 / 73.127 ms | 24.740 / 73.883 ms |

The raw 2/2 profile was about 29% slower than raw 1/1 in both direct pairs. It
published 34–35 immutable batches and 34–35 HEADs for 35 logical transactions
in every measured execution. Raw 1/1 published 14–25 of each. More workers
still fractured the admitted prefix and increased durable publication work;
merely moving encoding after freeze does not supply the required 2–3x path.
The experiment stops at this non-monotonic result. No wait-time sweep, ARM timed
screen, implementation promotion, or performance commit follows from it.

## Exact identity and limits

The isolated source is Git base `613ad2b054725e99b73117f03ae38e213fdfaef7`
plus tracked binary diff SHA-256
`ef9171ee9b7869609c25039eb8c8c43e427c568cb92e9b05ca103e692879b132`.
Only `src/flyology-db.adb` differs from the current foundation candidate: the
experimental worker bypasses member preparation and selects only `Queued` raw
arenas. Its SHA-256 is
`9dde0115dc8e49feb8d1305b078d09c00591eb39c5e0e08918fb89357b035b9a`.
The optimized Ada panel SHA-256 was
`e9df7c025824396d0a3e5653ade175a51539490781322a199c7bc5a9d33bf225`;
the optimized SlateDB library SHA-256 was
`5bd568c6e6d2f50abe492d5a10c479aea54c0d5d06876d71a2f4b90ffca448ef`.
The force-build completed and the GPR source map selected the isolated runtime.
The screen exited zero with its own final sentinel, unchanged source hash and
empty owned scratch. The x86 host had no benchmark/compiler descendant at
postflight.

Raw evidence is `artifacts/x86_64-evidence.tar.gz`, SHA-256
`c08b3dbdd89c649f1d446d6f779e3aa5a2a7c504dfe164b9cffa97d2aba2d2ca`.
The validated summary is
`artifacts/x86_64/evidence/screen/validated-summary.json`, SHA-256
`70f210fc91d51142f14bf6536fcc3b519c9ca21c67760391432b56448997edb8`.
Power detection was `unavailable/unknown` before and after, so this is a quiet
same-host screen, not a verified matched-power or portable comparison. The
existing foundation's full deterministic suite passed, but this isolated raw
variant did not run that suite or TLC/TLAPS. Its post-freeze encoding failure
would couple member fates differently from the prepared-member candidate; it
must not be treated as semantically qualified.

## Architectural implication

The one-worker raw path still formed 14–25 cohorts, and adding a second worker
nearly returned to one batch and HEAD per transaction. The source mechanism is
the admission-time 1 ms scheduling boundary: the oldest transaction can expire
before later serially prepared callers have admitted enough peers, and a faster
worker freezes that short prefix sooner. This is supported by publication
geometry but is not yet a source-correlated admission-time measurement.

The earlier six-publication [phase capture](../owned-copy-lowering-20260915-v2/DECISION.md)
had a 38.16 ms window, about 25.33 ms of batch-PUT marginal spans, and about
5.79 ms of build spans. These spans may
overlap and cannot be subtracted or halved as a measured saving. They suggest
investigating whether a scheduler preserving occupancy *while* overlapping
preparation and immutable publication could approach the 23–25 ms SlateDB window. A future
distinct design must make its bounded selection/latency policy explicit and
model failure coupling, raw-arena ownership, cancellation, deadlines, close,
ambiguous HEAD, and dependent-cohort cleanup before adoption. No such design
or bound has been validated here.
