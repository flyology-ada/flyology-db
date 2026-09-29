# Natural-admission occupancy experiment: architecture no-go for these configurations

## Objective and stopping decision

The active objective remains a defensible architectural commit-path improvement that materially closes
the tuned SlateDB gap on equal-semantics sustained workloads across x86_64 and ARM64, followed by full
correctness/formal qualification, independent review, and meaningful local commits without pushing.
This record is a rejected exploratory experiment, not completion of that objective.

The unchanged post-freeze whole-cohort runtime was measured with natural serial Begin/Put preparation,
independent asynchronous singleton commits, caller depth 32, maximum cohort members eight, and selected
wait/preparation/in-flight profiles. It used neither packed caller waves nor a private selection pause.
Only the first x86 round completed. Longer waits restored the minimum five batch/HEAD pairs but did not
improve the transaction window. The remaining repetitions were stopped; ARM repetition was not started.

## Sealed first-round results

These are paired medians from one round, not aggregate medians or final cross-architecture qualification.
R denotes runtime preparation concurrency; C denotes maximum in-flight cohorts.

| Profile | Median range across its pairs | Batch/HEAD pairs per measured operation |
|---|---:|---:|
| SlateDB, 1 ms, caller depth 32 | 23.664–25.452 ms | Not reported by this counter |
| Current A: 1 ms, R1/C1 | 47.224–50.363 ms | 12–23 |
| 5 ms, R1/C1 | 49.814–49.849 ms | 7–9 |
| 5 ms, R2/C2 | 51.507–51.946 ms | 7–9 |
| 10 ms, R2/C2 | 55.565–55.751 ms | 5, every measured operation |
| 10 ms, R4/C4 | 55.932–56.402 ms | 5, every measured operation |

The 10 ms variants were credibly 13.6–16.0% slower than their paired A controls. Five publications proves
the minimum count under the eight-member cap, not an exact ordered 8/8/8/8/3 member distribution.
This supports rejecting wait-only/current post-freeze tuning, not every possible pre-freeze or overlap
architecture. No acknowledgment-latency distribution or production claim follows from these results.

## Verification and evidence

The sealed artifact is `artifacts/x86_64/evidence/round-1.json`, SHA-256:

`d3ae72dd6dd52bec465d441e0380fa5f9160160bf3c8252fa467314ac40192ef`

The independent Astra review verified the exact nine comparisons in announced order, ten samples per
comparison with balanced 5/5 execution order, request/comparison/metrics/seal hashes, and acceptance by
the maintained `load_pair`. All 180 measured reopen verifications used 35 transactions × 256 mutations,
warmup eight, and all 11,008 keys. Each pair additionally has two calibration verifications. Every
measured state digest was:

`090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb`

Keys were 16 bytes; values were 1,024 bytes. The timed region includes Begin, every Put, and durable commit
outcome; close/reopen/full verification remain outside primary time. Recorded provenance matches the
retained v5 campaign. Direct supplemental checks matched the retained panel and Slate shared library:

- Panel: `2419663a3e5c447c7dc2afc7074d437b74ea7b65ec99c7aa3f51d02e0f3a6190`.
- Slate library: `d61eb0795be17619809eba50b3cccd4af2dad5c9c520d0dc931c67b94d3749bf`.

AWS power detection returned unknown, so the results remain exploratory same-host observations, not
comparisons under a verified matching classified power profile. Complete dependency/native-library
pre/post inventories were not added to the sealed first-round artifact. This limitation is retained,
not converted into a qualification claim.

## Terminal boundary and postflight

The exact experiment driver PID 666115 was paused while its panel child was allowed to finish. The child
was confirmed terminal before SIGTERM/CONT ended that driver. The enclosing SSH session 89512 ended
with status 143, intentionally; the full campaign did not pass or complete. Partial second-round output
remains on the host and is excluded from this decision.

Postflight found no relevant executable/formal child and emitted RESOURCE_AUDIT_CLEAN and
FORMAL_AUDIT_CLEAN. The owned scratch directory was empty and retained. Both EC2 hosts remain retained;
the EC2 executable lane is released. No source, model, formatter, proof, build, test, provider, dependency,
APM, staging, commit, or push action was performed during this measurement/rejection boundary.

The source HEAD and tracked diff remain:

- HEAD: `613ad2b054725e99b73117f03ae38e213fdfaef7`.
- Diff: `701ecac312e2c6a6a41cb14354bbe378198e340bbfa4c8f32d3e1f3829b59742`.
- Root lock: `5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3`.
- Built benchmark lock: `440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc`.

A diagnostic check initially used pre-install benchmark lock `34989452…`; the retained measured v5
provenance and this round both name the built lock `440618a8…`. Direct current hashes match the latter.
Neither lock was altered to satisfy the diagnostic check.

## Next architectural question and promotion boundary

What necessary preparation work remains on the critical path, and can a changed transaction-owned
representation eliminate repeated passes without changing the caller's work or acknowledged durability?
A post-Commit queue cannot accelerate Begin/Put work already completed by the caller.

Historical preparation-ceiling data, a different retained source snapshot, provides hypotheses rather
than a hard lower bound for a redesigned runtime. The span includes benchmark Key_For/Value_For
generation, Begin, Put, and fixture control; it is not DB-only preparation time. Current Ada and Rust
adapters both generate keys/values inside their respective transaction-window clocks. Equivalent bytes
and formulas do not establish identical fixture CPU cost across the two compilers. Four-run medians were:

| Caller preparation | x86_64 | ARM64 |
|---|---:|---:|
| Ordinary serial preparation | 31.764 ms | 57.235 ms |
| Serial preparation with four coordinator calls bypassed per mutation | 30.346 ms | 54.594 ms |
| Difference | 1.418 ms | 2.641 ms |

That bypass alone has no credible 10% end-to-end ceiling and is rejected as an independent optimization.
It also only ran while captured context could not overlap fence/unknown/close/reopen. Do not adopt it
as a safe implementation merely because the successful-path diagnostic ran.

Before another runtime redesign, profile fixture generation separately from actual necessary caller
preparation, batch construction, provider publication, and wait critical path. Existing whole-program
profiles include verification and cannot establish transaction-window component shares. The retained
x86 host has perf and strace provisioned; this boundary did not start a new profiling run.
Require evidence for removing roughly 25–30 ms rather
than accumulating micro-wins. A promotion candidate must reach the full target, survive balanced
exact-state x86/ARM tests, and close the concrete model/ownership/byte-bound/cancellation/close/unknown
recovery and replay gaps. Current unqualified model wiring is not passing assurance evidence.

## Review disposition

Independent review found no P0/P1 in the sealed round's workload, hashes, pairing, digests, or primary
time. P2 limitations are explicitly bounded here: incomplete three-round/cross-architecture campaign,
counts versus exact membership, unmeasured acknowledgment latency, unknown power classification, and
incomplete supplemental dependency/native-library authentication. No implementation is promoted and
no claim requiring those absent gates is made. The broader performance goal remains active.
