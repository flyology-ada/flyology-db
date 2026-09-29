# Put preparation attribution: exploratory x86 screen

These are diagnostic observations, **not** a qualified performance comparison or
an optimization result. The Linux detector returned `profile=unknown` (exit 2)
before and after each run, so matching power conditions cannot be established.
The three panel invocations were sequential, not a balanced A/B campaign.

## Fixed input and build identity

- Host: retained AWS `i4i.xlarge` x86_64 instance `i-0a08bc57aea3844c4`.
- Isolated source root:
  `/mnt/flyology-bench/experiments/put-preparation-attribution-20260916-v1-x86_64/source`.
- Source base: `613ad2b054725e99b73117f03ae38e213fdfaef7`;
  tracked binary diff SHA-256: `16bc13c4f7d3308d987c0d6f080a7de728b3af8a0ba6b1e597457b74f55f5625`.
- Benchmark executable SHA-256: `963f63ed40dabba9e5ca0ead7419f5d2d80690232c971723b87c3cd74ca93ddf`;
  SlateDB library SHA-256: `901740e7866ed5722d20815853366a5499bde9104e576786da9d85a340a6d499`.
- The forced Ada compilation succeeded; the initial link lacked the pinned
  TidesDB libraries. Byte-identical libraries from the retained prior isolated
  experiment were copied into this root; the subsequent link passed. `gprls`
  selected this root's DB, Flyology participant, SlateDB bridge, and panel sources.
- Each panel used 8 warmup and 35 measured transactions, 256 mutations each,
  16-byte keys and 1,024-byte values. All participants reopened and verified
  11,008 keys with state SHA-256
  `090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb`.

## Observations

Medians use the same ten measured paired samples within each panel; the two
unpaired warmup executions are excluded from diagnostic medians. All times are
ms. The diagnostic fields sum elapsed per-call wall spans and overlap the primary
window; they are **not** removable-time shares. Rust's measured `.put` scope
includes owned-vector teardown, while Ada's `DB.Put` borrows caller arrays.

| Profile | DB primary | Slate primary | DB `Put` | Slate `.put` | DB prep | Batch/HEAD count |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| depth 32, diagnostics | 60.510 | 25.540 | 41.319 | 2.014 | 54.937 | 18–26 per sample |
| depth 32, no diagnostics | 58.405 | 23.969 | not measured | not measured | not measured | see raw NDJSON |
| one member, depth 1, diagnostics | 106.881 | 72.518 | 24.877 | 2.044 | 35.376 | exactly 35 |

Raw machine-readable artifacts are under `x86-diagnostic-smoke-02/`,
`x86-normal-smoke-01/`, and `x86-members1-depth1-diagnostic-01/`. Each has
`result.json`, `metrics.ndjson`, and matching `power-before.env` and
`power-after.env`. The diagnostic NDJSON SHA-256 values are, respectively,
`0cbf4613cb82bc3666fb344b1db68eb73639c319951138a6258d4b9c281274e4`,
`39961113ac7132c29a2fa7f3bbe36ba20e623cb79b3227610fd4a732883b956c`,
and `e8a449460eccdc2ecb4358a3f6bf8316eeea9fe2defbc8500556c23d07c12084`.

## Inference and stopping boundary

The sequential normal/diagnostic runs suggest timer perturbation is much
smaller than the observed Flyology `.Put` span, but they do not isolate it
causally. Depth 1 and depth 32 change publication and scheduling geometry, so
their 24.9-versus-41.3 ms `Put` spans do not by themselves prove a lock-contention
cost. They do establish a large, measurable candidate for architectural
investigation at the same work count and final state.

`Store_Mutation` currently acquires a lifecycle lease and performs separate
protected Snapshot, incarnation, family, and transaction-bound checks on each
mutation before allocating/copying its owned payload. A fusion of coordinator
checks is a narrow diagnostic A/B, not yet the desired 2–3× solution. The
larger hypothesis is that faster transaction-local admission plus bounded
preparation/publication overlap can fill cohorts and reduce both caller and
per-cohort critical paths. It requires ownership/fencing review, TLC/TLAPS
qualification for changed publication semantics, and balanced exact-state
measurements on x86_64 and ARM64 before adoption. No production change or
speedup is established by this screen.
