# Exact-owned runtime batch-image probe

This disposable source-only prototype tests one narrow representation change:
fresh runtime batches allocate their exact final contiguous byte array once,
emit batch-v1 framing and mutation payloads directly into that array, and run
the one-shot CRC-32C over that final authority. Decoded and recovered images
retain the existing `Flyology.Bytes.Unbounded_Bytes` representation.

The prototype adds a private `Flyology.Bytes.Copy` operation that copies a
validated range directly into a caller-owned slice without constructing an
intermediate array. Shared-image length, element, and block-copy helpers hide
the two representations from provider publication, runtime lookup and scans,
unknown-outcome reconciliation, commit-authority export, and reference parity.
The exact allocation remains the sole receipt/history authority and is freed
with the shared image on every terminal path.

## Frozen inputs

- `source/flyology-db.adb` began byte-identical to
  `../commit-phase-timing-probe-v1/source/flyology-db.adb`.
- `source/flyology-db.ads` began byte-identical to the repository public/private
  specification at the time this directory was created.
- `flyology-source/flyology-bytes.ads` and `.adb` began byte-identical to the
  retained Flyology source in
  `../files-batch-etag-crc32c-to-array-probe-v1/flyology/src/`.

## Preserved boundaries

The public API, batch-v1 wire map, CRC polynomial, provider call sequence and
barriers, batch/member/transition identities, receipt resolution rules, and
decoded recovery representation are unchanged. This directory selects no
batch size, admission window, deadline, cancellation, or conflict policy.

## Retained experiment

The x86-64 EC2 host force-built the control and candidate with the same
warning-strict `-O3` project and a group-capable adapter. The final binaries
were:

- control: `9754b8789fde6f3568a80cf8183e455000dc34a23b448c5130790186bc1ab10d`;
- candidate: `dc1e94454718e02c2b7075a02e2ce43c12a45b52ed172435dec6657e2794f3cf`.

Control and candidate emitted the same established dependency-warning set and
no error. The candidate runtime source was
`b39514c68bad464d341621f79de53c195bb07185f1921eecb18debd8dbc74d90`.

`run-ab.sh` first exercised group sizes 1, 2, 4, and 8. Every run verified
10,240 keys after reopen, the exact state digest
`5283189c4531950d9f91a1aff1212a3cd36d69a2768ee759aa801ee3471b79a9`,
the expected `40 / group_size` immutable batch objects, the adapter's exact
member transaction/batch/sequence receipt assertions, and byte-identical
batch-v1 object bodies. It then ran eight balanced control/candidate pairs for
group 1 and group 8, always using fresh roots and identical work.

| Explicit group | Control median | Candidate median | Paired median gain | 95% bootstrap interval | Wins |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 131.629 ms | 115.377 ms | 12.233% | 11.810–13.607% | 8/8 |
| 8 | 88.699 ms | 71.584 ms | 19.242% | 18.562–19.878% | 8/8 |

The raw CSV SHA-256 is
`96d63fb5481ae0f77f4cf160d6199b3fc94177ea661bbfc7744411d2c96f89c0`.
`analyze.py` validates the smoke order, work, state, publication count, paired
batch digest, and balanced geometry before producing the retained statistics.
The complete evidence archive SHA-256 is
`0661bcd85d2833195b1517c60b937ab8ee0d812e5a8c5fccd9fd114990d0318c`.

The Linux power detector returned status 2 (`profile=unknown`). These are
paired same-host comparisons under an otherwise idle host, not portable
absolute measurements or a claim about a classified quiet/power profile.

Persisted byte comparison hashes the exact object bodies declared by each
Files `FOSOBJ05` envelope. The envelope's modification-time field necessarily
differs between balanced runs and is provider metadata, not batch-v1 content.

## Interpretation and adoption boundary

On one x86-64 EC2 host with an unclassified Linux power profile, the exact-owned
representation plus block-copy image path reduced the power-loss-durable Files
transaction window by a paired median 12.233% for singleton commits and 19.242%
for explicit groups of eight. All eight pairs favored the candidate. Control
and candidate reopened to the same 10,240-key digest and produced identical
batch-v1 bodies, publication counts, and group receipt identities. This is
exploratory architectural headroom, not SlateDB parity or automatic-coalescing
evidence.

The two within-geometry A/B results are balanced. A cross-geometry endpoint is
not: group 1 always preceded group 8 within a cycle, and the probe measured 32
transactions while the retained tuned-SlateDB result measured 35 independent
transactions. Explicit `Commit_Group` also atomically co-commits eight
caller-selected transactions under one batch and one HEAD identity. Automatic
coalescing would require explicit latency, deadline, cancellation,
conflict-coupling, and identity policy plus TLA+/TLAPS. A fresh equal-work,
equal-semantics, geometry-order-balanced campaign is required before claiming
competitor parity or route closure.

Static review found no batch-v1, CRC, receipt, recovery, or reference-ownership
discrepancy. At the probe boundary, product adoption still required an
exact-image allocation fault point, an explicit `Stream_Element_Offset`
capacity check, and enforcement of the exact-versus-growable representation
invariant. The adopted source adds those boundaries and passed the maintained
deterministic suite, all 18 six-provider lanes, and the 1,400-check SPARK
regression gate. Dynamic allocation and ownership remain test evidence rather
than a SPARK proof claim. Provider publication still performs its required
copy. The candidate also replaces
per-element provider source reads with block copies, so the retained result is
the combined exact-owned representation and block-copy path; narrow timing or
profile evidence must explain the roughly 6 ms group-8 saving beyond the prior
11.068 ms builder/materialization ceiling before assigning narrower causality.
