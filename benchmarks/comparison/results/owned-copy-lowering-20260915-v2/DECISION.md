# Direct owned-byte copy: isolated, not promoted

The objective remains an architectural route materially closing the tuned SlateDB gap across x86_64
and ARM64 under equal transaction and durability semantics. This is a bounded component experiment,
motivated by the retained transaction-window profile, not a substitute for that objective.

## Code-generation gate

The isolated runtime adds a direct Ada import of libc `memcpy` behind derived byte-representation
checks, with the original scalar fallback. It copies into the independently allocated candidate,
before the existing abort-deferred adoption. It changes no public API, persisted format, policy,
fixture generation, publication geometry, or public worktree source.

- Runtime source SHA-256: `1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac`.
- Mechanical patch SHA-256: `7f45e728d66566f6062b832c659ac373c20a44aa3b0722a99cf48780476dbcd2`.
- Optimized candidate binary: `f20f73cbfc9ab606c2f9a1463d6831b9bebe90fa550ed4895149e6088878477e`.
- Unchanged forced baseline: `6bc8b3175ffdaf64a52f059d9fbb329b08c07bf88e46f82229ba2b9f364f76dd`.

The once-only force-build exited zero, with the same retained 26 benchmark/dependency diagnostics.
Its enclosing SSH invocation also exited zero. This is not warning-strict release qualification.
The nested copy helper has one tail jump to `memcpy`, without scalar staging, a second payload pass,
or runtime-sized stack storage. Independent source and assembly reviews found no actionable P0/P1/P2
within the narrow code-generation gate. They approved correctness testing, not a speedup claim.

## First correctness window: stopped before execution

The isolated boundary tests cover all byte values, direct offset slices, high/non-one array bounds,
empty and varied lengths, caller overwrites through test-only volatile overlays, replacement,
allocation-failure atomicity, delete, rollback, and fresh-context reopen on Memory and Files.
The existing shared memory corpus is unchanged. Files reopen is not power-loss qualification.

Final isolated test source: `7a79552480d5939c0805a7a411e0bf123e5722d4534e66c9d7dcf670d98ad0d7`.
Test patch: `006fa5e11801c95229a6b9b0cc8700a15f0c02e5b94251cb1cca77300c383076`.

The single force-build through the maintained test GPR completed compilation, binding, and linking.
The enclosing gate exited 1 at its diagnostic comparator, before any engine execution. Its comparator
incorrectly used the benchmark-only warning inventory: the ten additional lines are existing
test-corpus `Task_Info` deprecation warnings, including line shifts caused by the inserted tests.
No new runtime or boundary-test diagnostic is present. The original failed receipt and logs remain
unchanged under `artifacts/x86_64/correctness/`; do not relabel that window as successful.

- Build log: `6a38c4da4799147db1b5907e3226ccc86e21fa3ffe9b131eb4edc228ec94d8a1`.
- Complete test diagnostics: `5e937300a9ff027dd4f61d0bedb60e6389f1500e808173a82a61d3b61924a6be`.
- Comparator-rejected lines: `12f5631ced146e85ace11702db763ad774aa3a848d601ec205669118475ccdbc`.

## Remaining gates and stopping rule

Independent diagnostic review confirmed all ten warnings are preexisting. However, actual test ELF
inspection found a second P1: `Store_Mutation` still uses the baseline scalar loops. GPRls source
resolution proved the bare test import loads the benchmark's pinned baseline DB copy, not the modified
candidate runtime. The test ELF `886b4bf752dc170825e81d6bc1e4e8ac047fa91307133fc0546bbef4c8984fa7`
therefore cannot qualify the copy change. `input/run-engine-first.sh` is UNUSED and must not be launched.
The independent reviewer reproduced the scalar paths and rejected an engine execution recommendation.

The documented `-aP` owning-root option changes the resolved DB source from
`candidate/benchmarks/comparison/.deps/flyology_db-fca74780/src/flyology-db.adb` to
`candidate/src/flyology-db.adb`, without changing the GPRs, manifests, dependencies, or config/locks.
Both retained `gprls -U -s` comparisons have empty stderr. The explicit-root source inventory SHA-256 is
`b723bb004b0dab2315c57f313ae88bea09dcfcf0da41e5b642573672d7f46fcc`.

A separately reviewed corrected build must use that same explicit root for resolution and compilation,
preserve the rejected binary and failed receipt, and authenticate actual copy and boundary-test code
generation before any engine execution. This narrow engine gate is not the full deterministic suite.

Independent runner review found no actionable P0/P1/P2 in `input/build-tests-explicit-root.sh`, SHA-256
`7b421331261d10f2e468808c5f6622e6e2ea9f91833895e9a8603a6e5539ef6c`. The single corrected build-only
window exited zero, including its enclosing SSH invocation. GPRbuild PID 722552 used the explicit
candidate `-aP`; compiler children used `-O3` and scratch beneath the owned `/mnt` root. The corrected
test binary is `f576a0a7461cea0bf86ef9084fd77b8e92c09f409791e597d0efa9af69d8adf8`. Its exact 32-warning
inventory matches the reviewed test inventory, and source/config/locks stayed unchanged. The benchmark
binary remains `f20f73cbfc9ab606c2f9a1463d6831b9bebe90fa550ed4895149e6088878477e`.

The corrected `Put` tail-jumps to `Store_Mutation` at `0x45c5e0`. Key and value paths call the nested
copy helper at `0x45ccf2` and `0x45d102`; the helper at `0x3baa60` tail-jumps to `memcpy` at `0x3baa9e`.
Helper disassembly SHA-256 is `92ad50458414c69120acefbba70141d5e28af2eeb4ebc3933b6847ea7688f75e`.
Independent review of this actual ELF and the test call chain closed the compiled-runtime P1. The
reviewed `input/run-corrected-engine.sh` harness then executed the engine exactly once and exited 1:
`raised PROGRAM_ERROR : byte-cap database create failed: STORAGE_FAILURE`. This occurred in the
unchanged shared Memory corpus, before the new owned-copy fixture. The failure establishes neither
copy correctness nor a copy regression; its cause remains to be diagnosed without capacity guesses.
The exact status and log are retained under `artifacts/x86_64/engine-corrected/`.

Source diff stayed `cddc957b5bdfe5404ab96fc9d6ca0b7f4ee46f87c0d4af5baf446d5cce8b30d9`;
config and both locks passed their original hash inventories. A terminal exact-basename audit printed
`RESOURCE_AUDIT_CLEAN` and `FORMAL_AUDIT_CLEAN`. The owned scratch directory was empty and the Files
root had not been created. The executable window is released, with no retry, cleanup, timing,
promotion, commit, or push. Files cleanup on successful execution is engine-owned, not shell-trap-owned.

## Source-derived fixture accounting repair

Independent review found a stale test-only object ledger: the existing dirty adaptive overlap case
retains batches 65,201 and 65,203, but the shared Memory fixture still budgets 12 adaptive objects.
The exact adaptive ledger is 14: initial manifest/HEAD (2), overlap batches (2), wait-tail/equality/
split/oversized/close-drain batches (6), checkpoint run/manifest (2), unknown cohort batch (1), and
family-append manifest (1). Existing HEAD replacements reuse their key. No speculative orphan slot,
production capacity, bucket capacity, byte budget, or assertion was added.

The shared test capacity is corrected from 669 to 671, with an adjacent derived-object explanation.
Reversing this narrow edit reproduces public source `a44d5693...` and isolated source `7a795524...`
exactly. Corrected public source is `cd078a86ca9c4e8732d38fea004c1362334f7700173cd129375e4c61a089ab3a`;
isolated source is `bbae4a2d17c5f7eac908f7045c684a7e57f820ee3c48f22713da661fa719ef9e`.
The failure log alone cannot distinguish provider slot exhaustion from byte-capacity failure.

Reviewed build-only harness `cec30976973002cb602e21836b2da07ea45763d0aa1c4886d1cd82c2d7cdc177`
completed once with exit zero, including enclosing SSH. It recompiled only the changed engine body,
then bound/linked the test main; all other test executables stayed up-to-date. Seven existing test
Task_Info warnings are a subset of the authenticated baseline, with no new diagnostics.
New test ELF: `a5b498ce03b4648fc4266951879f0149ed8944cdde0722de216f3a93d361e890`.
Its Run assembly passes 671 objects, four buckets and eight million bytes to Memory.Store; the
candidate Store/copy-helper assembly is byte-identical to the previous authenticated copy path.
Source/config/locks stayed exact. The old failed binary and receipts remain retained, not rewritten.
The separate reviewed full-engine harness
`ec17a9ece4e27b146877e130f3c4d287300fd8e976979ab0f16163d19496bd14` then executed once and
exited zero, including enclosing SSH. The unchanged full engine corpus reached its maintained
`Flyology.DB formats, policy, model, and local log engine: OK` sentinel. Both unconditional new
owned-copy Memory and Files calls therefore completed, including mutation/lifetime and reopen checks.
This also cleared the prior cap-bytes creation boundary without changing the byte budget.

Engine log: `1e1e7e693159c8afa70c40d3f2c15a2a1364a805d11f8e0001eab83966109449`.
Status receipt: `5fd9469f2ea90f86656176ca01f9acc05cca5f966ebaaf4428a0fda227416a9b`.
Source/config/locks/test and benchmark binaries remained exact. External terminal checks retained
`RESOURCE_AUDIT_CLEAN`, `FORMAL_AUDIT_CLEAN`, `OWNED_SCRATCH_EMPTY`, and `FILES_ROOT_REMOVED`.
The executable window is explicitly released. This is x86 engine correctness, not the complete
`tests/scripts/test.sh` campaign, ARM evidence, formal assurance, or performance qualification.

## Balanced performance screen: prerequisite identity only

Read-only authentication found existing optimized panel binaries suitable for the independent
screening design: baseline `2419663a3e5c447c7dc2afc7074d437b74ea7b65ec99c7aa3f51d02e0f3a6190`,
candidate `4226f2149562ef803caedf8107f1332da83b1bdd9295ddd937d411e78aabf70a`.
Panel and adapter source hashes agree between trees (`8f467152...`, `464d7e2c...`), and both resolve
their local Slate library with hash `d61eb0795be17619809eba50b3cccd4af2dad5c9c520d0dc931c67b94d3749bf`.
GPR hashes also agree. No performance screen has run yet.

The bounded screen must use baseline/candidate then candidate/baseline outer order, each existing
in-process S/A panel with ten balanced inner pairs, explicit warmup eight and measured iterations one.
Require exact 35 by 256 mutations, key/value widths 16/1024, depth32/R1/C1, actual publication counts,
11,008 reopened keys and exact digest. Inner S/A confidence intervals are not cross-binary B/C intervals;
two outer contrasts cannot establish a statistically qualified ten-percent floor. Unknown power-profile
results remain exploratory. Do not promote a timing improvement merely because this engine gate passed.

## Architectural alignment

The independent ceiling review confirms preparation after admission cannot remove caller work performed
before `Start_Commit`: the adapter generates input and completes `Begin`/`Put` before submission.
Per-transaction preparation before cohort freeze can overlap later validation, encoding, and index work,
not that earlier copy or fixture generation. Sample shares from the instrumented W10 profile cannot be
subtracted from the faster A-profile medians. Correlated admission/ready/freeze/encode/batch/HEAD timing
and actual physical publication counts are needed after a measured copy change before quantifying a
2–3× route. The direct-copy code-generation result alone does not establish that route.

Only after correctness may balanced same-state measurements begin. Require identical optimized builds,
work, bytes, durability, actual publication counts, receipt identities, reopen verification, and digest.
Record detectable host conditions before each measurement; unknown profiles cannot establish verified
power-profile comparability. Reject semantic mismatch or a sustained gain below the practical 10% floor.
ARM64, full qualification, independent review, and the pipeline model/runtime/replay gaps remain open.
No timing, promotion, commit, or push is claimed here.

## Completed exploratory copy screen

The reviewed collector `753885bc4e9ff5c4c0af267e09713bb2872d6b9e0640168d45cbea0646f52147`
and pinned wrapper `f40e9075ecd09e1625709925c5af9704daa25f50d0da55714ff792b41e100cb2`
ran once in B1, C1, C2, B2 order. Every panel retained ten balanced in-process Slate/DB pairs with
measured iterations one, 35 transactions by 256 mutations, key/value widths 16/1024, warmup eight,
depth32/R1/C1, and successful reopen of 11,008 keys at the exact expected digest. All four panels
exited zero with empty logs. The collector reached `DB_DIRECT_COPY_SCREEN_TERMINAL`; the enclosing
SSH and wrapper also exited zero. No timing from any rejected build or failed engine run was reused.

The literal campaign-contract smoke rejected calibration, work, digest, reopen, order, concurrency,
and publication mismatches. Native Linux literal lifecycle checks passed normal/nonzero joins and
cancellation with a TERM-resistant descendant followed by KILL and complete group join. The local
macOS lifecycle smoke could not complete process-group inspection (EPERM); it supplies no Linux
evidence and was not debugged further. Independent static review found no actionable P0/P1/P2 in the
collector, wrapper, native-resolution closure, or analysis script for this exploratory boundary.

| Outer order | Baseline DB | Candidate DB | DB window reduction | Slate baseline/candidate |
| --- | ---: | ---: | ---: | ---: |
| B1 then C1 | 46.5349 ms | 36.9151 ms | 20.6722% | 24.3066 / 24.6554 ms |
| C2 then B2 | 48.7380 ms | 37.0143 ms | 24.0544% | 25.1538 / 24.1367 ms |

Baseline batch/HEAD counts ranged 13–20, with panel medians 14.5 and 15. Candidate counts were six
in every measured execution. Manifest counts stayed zero. This is natural scheduler occupancy under
the unchanged profile, not a benchmark selection pause or forced full-cohort fixture. The observed
saving includes the change in admission/cohort occupancy; it is not an isolated memcpy wall-time
attribution. Candidate DB remains 1.4972–1.5335 times its same-panel Slate median, not parity or a
two-times architectural improvement.

All four detector results were Linux/unavailable/unknown, status two. Identical unknown outputs do
not establish verified power-profile comparability. The retained results are exploratory quiet-host
same-host comparisons, not portable absolutes or final qualification. Two opposing outer contrasts
do not provide a B/C confidence interval; the inner Slate/DB intervals cannot substitute for one.
This promising component meets the exploratory continuation criterion, not the promotion gate.

Raw evidence is under `artifacts/x86_64/copy-screen-receipt/copy-screen/`.
Screen SHA-256: `ee837a3d84215e43103711d67f4afce9af03847bfe6377a17f644d3d92302856`.
Analysis SHA-256: `adc775820c3e53bb5809920a483a462ac6f9cf55246f30ba7b209d5626361bae`.
Receipt archive SHA-256: `272d14d0fd170c6907fdde62e78c539bf7fd2a3aabc79dbc6c48cf22940df22b`.

External terminal postflight reauthenticated both complete source/native-library maps, exact three
dependency origins/HEADs/trees and cleanliness, indexed Object Storage source, config and both locks.
It retained `RESOURCE_AUDIT_CLEAN`, `FORMAL_AUDIT_CLEAN`, `OWNED_SCRATCH_EMPTY`, and
`CAMPAIGN_AND_CPU_LOCKS_RELEASED`. The EC2 executable window is explicitly released. Public tracked
diff remains `492c6975298a337c804b776e0b75b14b708b6c20bbf2e7de781d788dad6ed5f3`; zero staged.

The next gates are independent interpretation, repeated outer-block and ARM correctness/performance
qualification, then source-correlated phase attribution on the improved path. The model/runtime
preparation, ownership, deadline-boundary and concrete pipeline-replay gaps remain adoption blockers.
No performance promotion, public runtime copy edit, staging, commit, or push is authorized by this
screen alone; the overarching architectural objective remains active and unachieved.

Independent raw-result review confirmed all 80 measured reopen verifications and the two reported
contrasts, with no actionable P0/P1/P2 within the exploratory claim. The candidate's remaining
same-panel Slate gap requires another roughly 33–35% window reduction. Six natural publications are
already near the five-cohort minimum for 35 members at maximum width eight; occupancy alone is no
longer the leading credible route. Re-profile the candidate's natural window before assigning any
removable or overlap ceiling. Prior W10 phase totals are not the new critical-path breakdown.

The independent source mapping review identifies the smallest scheduler foundation: own canonical
per-transaction fragments in existing completion slots, freeze only the joined admission prefix,
seal in the existing pipeline ring without repeating mutation serialization, and separate CPU jobs
from bounded batch I/O. No additional ready queue is needed. It also identifies unresolved in-goal
P1 correspondence boundaries: model preparation-before-Freeze versus current Ada Freeze-before-build;
new pre-Freeze borrowers must join before terminal collection; logical `In_Flight_Bytes` does not
prove raw arena + fragment + aggregate resident accounting; concrete pipeline replay is absent.

Simply retaining the raw arena and adding a canonical fragment is not the performance solution: it
adds allocation/copying and disagrees with the model's raw-input release at JoinPrepare. Reclaiming
raw payload at join requires conflict accessors to use canonical owned storage while preserving
snapshot/read/range evidence and failure-atomic adoption. That larger ownership mapping must be
reviewed explicitly. A new resident-byte policy must not be silently substituted for the existing
logical-payload cap. Mixed worker wake predicates and saturated blocking I/O also require review.
This foundation plan establishes neither a measured parity path nor authority to invent a budget.

## Natural candidate phase capture and terminal release

The existing optimized candidate panel ran its ordinary A mode against A-diagnostics exactly once,
with ten balanced pairs, the unchanged 35 by 256 workload, key/value lengths 16/1024, warmup eight,
and depth32/R1/C1. All 20 measured executions reopened and verified 11,008 keys at the expected
digest. The panel, wrapper and enclosing SSH exited zero; the private panel log was empty.
Collector SHA-256: `e843bf60711bb2f50e53a9346ab48978d6d36be697b589b6cda3fa1593fe2308`.

Plain and diagnostic window medians were 38.1637 and 38.1667 ms. The retained paired estimator
reported +0.8252%, interval -1.9586% to +3.7684%, verdict inconclusive. This does not prove zero
observer cost. Plain publication counts were `[6,6,6,6,6,6,7,6,6,5]`; diagnostic counts were six
throughout. Width distributions also varied. Phase ratios therefore rank targets in the diagnostic
executions; they are not exact decomposition of the uninstrumented six-publication window.

Marginal elapsed medians, which must not be summed, were batch PUT 25.3295 ms, build 5.7892 ms,
validation 1.0858 ms, HEAD PUT 3.1421 ms, HEAD encode 0.0245 ms and installation 0.4717 ms.
Caller preparation was 23.4111 ms, including driver fixture generation and Begin/Put, and overlaps
worker activity. The unattributed pipeline gap was 0.9900 ms; it is not proven removable idle time.
Batch PUT includes provider CPU, file I/O, barriers and scheduling. Its large span justifies the
next narrow attribution; it is not a claim that 25 ms is disk latency or can simply disappear.
Build-only work is insufficient for the remaining roughly one-third window reduction to Slate parity.

Read-only capture authenticated the actual indexed Object Storage source, rather than substituting
the separate retained author-profile clone. Its Files Put_Object performs MD5 updates after streamed
writes and retains file sync, rename and directory sync operations. This is source geometry, not
measured CPU or syscall attribution. The optimized panel and provider disassembly are retained for
mapping a new natural-window profile; old W10 instruction offsets and sample shares must not be reused.

Validated raw SHA-256: `25af1b3d1a7d739c34bf5d677e1bb897d97f15d7ffd115d8a27412bd4a9a10fb`.
Analysis SHA-256: `08a527396339e052e226a11980888b39cb9c01a90577010c674903f9d0cab221`.
External postflight SHA-256: `0179ed0ff74e7087f7370afd7a052cd3fd0bbc6ff99be2a684f780fb385706b2`.
The detector remained Linux/unknown, so this is exploratory x86-only evidence, not promotion.
External postflight exited zero and reauthenticated the complete candidate/native-library/dependency/
config/lock closure, empty scratch, no executable/formal child, and both released locks.
`DB_NATURAL_PHASE_WINDOW_RELEASED` explicitly releases the EC2 window. No runtime edit, rebuild,
second measurement, ARM qualification, staging, commit or push occurred in this phase capture.

Independent interpretation review found no P0/P1 and one P2 causal-wording issue. The analysis now
states that publication occupancy differs between paired executions and observer perturbation cannot
be excluded; it does not attribute differing natural schedules causally to instrumentation.

The next profiling harness is a draft only and has not been deployed or run. Independent native review
verified exact candidate window offsets `0x27798c`/`0x2779ed` and batch Put_Create call/continuation
`0x36358f`/`0x363594`, with byte guards and executable LOAD mapping. This batch-wrapper boundary
excludes key construction, returned-result mapping and unknown reconciliation. It cannot classify
outside-batch events as HEAD. Flat user CPU samples are ranking evidence, not a full CPU/I/O split;
syscall elapsed includes scheduling and must not be subtracted to manufacture residual CPU time.
Exporter ownership, diagnostic/loss checks and attempt-all probe cleanup were strengthened in the
draft. Prelaunch acceptance still requires reviewed event pairing/normal-outcome correlation with
actual per-window publication counts, literal parser smokes and native tool-option authentication.
No profiling authority or acceptance is inferred merely from the draft's existence or syntax check.

## Natural provider capture: failed text parser, reviewed typed recovery

This section supersedes the preceding draft-only status, without rewriting its historical evidence.
The natural provider capture ran once. Perf and the panel exited zero, phase validation passed, but
the enclosing wrapper exited one: the formatted syscall exporter emitted application buffer payloads
containing newlines, and the strict parser rejected `spec=https://github.com/flyology-ada` as a record.
The original failure, text export and perf.data remain unchanged. This is not a green original wrapper.
All four probes were removed, the scratch root was empty, the complete source/native/config/lock/
dependency closure was unchanged, and the external resource/formal postflight released both locks.

The same existing perf.data was then interpreted once through the already-installed perf Python
callbacks, retaining only event identities, numeric syscall arguments/results and CPU IP/symbol/DSO.
No benchmark, probe, rebuild, dependency update or production source edit occurred. A separate native
payload-free text inventory retained every sample identity and exposed loss records for rejection.
Both exporters and the enclosing command exited zero with empty stderr. Exact multisets of
`(pid, tid, time, period, event)` agreed for all 61,907 samples. All 22 execution windows and batch
wrappers reproduced their actual publication counts; measured identities came from the ten paired
sample records rather than an assumed warmup slice. Failed or crossing publication syscalls reject.

Literal callback tests exclude buffer contents and reject identity/numeric defects. Retained-data
controls reject deletion, duplication, identity mutation and an actual PERF_RECORD_LOST marker.
Independent Astra review found one P2: the initial loss control inserted a blank line before its
marker. The corrected control reaches and identifies the loss marker. Re-review found no remaining
actionable P0/P1/P2; the corrected local validator subsequently exited zero. The first attribution
file remains historical; `validated-attribution-v2.json` is the accepted corrected diagnostic record.

Across the ten plain plus ten diagnostics executions, marginal medians were primary probe window
37.8728 ms and batch wrapper 25.1535 ms. Batch-contained syscall medians were 310 writes, 18 fsyncs
and six renames; elapsed medians were respectively 3.1961, 4.5089 and 0.0744 ms. These are not additive
critical-path components: syscall elapsed includes scheduling, sample periods are not complete CPU
time, and outside-batch events are not HEAD attribution. The batch wrapper has the exact previously
reviewed Put_Create call/normal-continuation boundary, not the broader diagnostic phase boundary.

Participant-separated probe-window medians were 37.8064 ms plain and 38.2097 ms diagnostics. Flat
batch user-CPU ranking pooled across both was MD5 transform 1,184 samples, unknown symbols 41, buffer
filling 26 and MD5 update 16. This identifies MD5 as dominant sampled user-CPU work inside the batch
wrapper and warrants a bounded byte-compatible acceleration/overlap investigation against the
promotion floor. It does not establish a ten-percent removable wall-time share, measured speedup,
provider-neutral optimization, or permission to remove checksums/change generations/skip barriers.
Any resulting experiment must retain exact provider bytes, identities, durability and reopen digest,
and then pass balanced equal-work panels across both architectures before promotion.

Original perf.data SHA-256: `f7c349dc709f96a68764633fa60a9095df5c328a079348f7f3a8ac84b4dc7bf6`.
Typed exporter SHA-256: `514efd557759bd2566f4444a26a9afc345be55d50099345d73d5cbbfc5316e40`.
Re-export orchestrator SHA-256: `2cadab908ce3656286053ff40ffa7f4e8ef771d6961f0caa2c34b0487a700357`.
Corrected validator SHA-256: `e7ea20d3835fcf11bb23dd02a9d9c99ac096a4745089e7e5d69148b218a2031e`.
Corrected diagnostic SHA-256: `f6d4533203f7962e97a7e25d5c98a4a77f07bdc027ed7097bff67b33be1b3b38`.
The native terminal receipt reports SOURCE_AND_CAPTURE_EXACT, RESOURCE_AUDIT_CLEAN,
FORMAL_AUDIT_CLEAN and DB_TYPED_EXPORT_WINDOW_RELEASED. Both hosts remain intentionally retained.
The public tracked binary diff remains `492c6975298a337c804b776e0b75b14b708b6c20bbf2e7de781d788dad6ed5f3`.
No runtime adoption, ARM qualification, staging, commit or push occurred. The architectural objective
and the concrete preparation/ownership/resident-budget/replay correspondence gaps remain open.

## Concrete pipeline ownership cut: implementation in progress

The active objective remains an architectural route materially closing the tuned SlateDB gap on
equal-semantics sustained workloads across x86_64 and ARM64, with fully qualified, reviewed meaningful
survivors locally committed and not pushed. Neither abstract proof nor this source-only step completes it.

The architecture record now specifies an arena-owned sequence-independent mutation fragment, joined
raw retirement before collection, admission-order blocking for older preparing members, and separate
CPU preparation and batch publication. Pending byte extents derive conditionally from existing limits;
they are not an implemented total resident-byte policy or an implementation-refinement theorem.

The first runtime prerequisite centralizes all queued terminal transitions in the private coordinator
operation Complete_Queued_Slot. Eight existing delegate sites plus Mark_Stopped's queued branch share
the same four writes; running completion remains separate. Wake scheduling, receipt custody and arena
ownership are unchanged. A reverse reconstruction reproduced the entire previous runtime SHA-256
46d430be91f2ab987836600490399db784b8330840672b84c9d04bf7d48e97cb exactly. Independent Astra
review found no actionable P0/P1/P2 in this refactor or the proposed ownership section.

Current runtime SHA-256: 6553f529045303a77495e97e6559bdef7d64cdd5a07f57fd57ee06d6f2e474a2.
Architecture record SHA-256: 99cc1daff39186d8e3c1981170f721b6943a34289f9c81cd8a9db2a5e13eb09a.
Tracked binary diff SHA-256: 78216d6149ea906edd8505141621bec397ad0bec584481b69369816a37eb2a2a.
Diff and maintained shell syntax checks passed; index and APM artifacts remain unchanged.

No new preparation states, canonical fragments, split workers or concrete scheduler replay have been
implemented in this step. No formatter, compilation, test, timed run, formal tool, dependency update,
staging, commit or push ran. The read-only host audit found an unrelated Flyology test family active;
there is no claim of a clean executable lane. Next required implementation is the generation-bound
preparation/join gate, its terminal deferrals and FIFO ready-prefix selection, followed by canonical
packing and independently bounded CPU/I/O workers. This is an unfinished implementation unit, not a
promoted optimization or a performance result.

## Canonical preparation and split CPU/I/O: unqualified compiled foundation

This stage supersedes only the preceding implementation-in-progress source status. The full
architectural objective remains active; no new performance result, qualification or commit is claimed.
Ada slots now distinguish raw preparation, detached retirement/join and ready ownership. Canonical
mutation bodies are arena-owned, preserve the batch-v1 mutation bytes, and are copied into final
aggregates at admission-ordered freeze. CPU sealing returns an owned image to a separate bounded PUT
pool; authoritative HEAD publication remains ordered at the front.

Independent Astra source reviews covered canonical ownership/encoding, gate phase transfers, startup
and shutdown. Findings repaired in this stage include exceptional abort-deferral balance and missing
post-master cleanup. Explicit Start/terminate rendezvous protects partial task activation; descriptor
images are moved out only after native workers join and are freed outside the protected gate. The
publisher's separately transferred local image has its own deferred-abort cleanup span. The bounded
ownership reviews then found no actionable P0/P1/P2; they are not execution or refinement evidence.

One provisioned GNATformat 26.0.0 pass exited zero. Token/comment comparison with the retained
pre-format sources matched, and canonical spaces were restored at three formatter-damaged entry or
barrier sites without another formatter pass. The force-build failed on those style sites, an obsolete
unused shared wake entry and a guard-transfer warning; it also retains dependency XML/Ada/internal-GNAT
diagnostics. Those dependency diagnostics are not erased or relabeled as a warning-free closure.
The obsolete entry was removed and canonical ownership transfer made explicit through an in-out guard
helper, without warning suppression. The repaired source compiled once through `alr -n build`, exit
zero in 15.18 seconds, with no new DB diagnostics. This is compilation only, not deterministic evidence.

Compiled runtime SHA-256: `977f7cc0ca1d7781419921d30c078e5a373397c24c15c45caf164e9d4e8f4260`.
Private specification SHA-256: `cb572311cfe8ea34df68c6f9c607c4a7b6bd4938ce431273c8f3472b3e5cbb2e`.
Tracked binary diff SHA-256: `5bc46df2c77f04f1b5ae29e417bbdf2871b6aa6c0510245da613c005e3bfc092`.
Failed force-build log SHA-256: `95df828c59a462e4acda957683858cc0297b76e03af05332bc45e704a2f3fba0`.
Repaired build log SHA-256: `2886cb8c31665b1759756013246e25465c46770a74487b2c27e38ce3f529f918`.
APM, ignored config/lock and all three retained dependency source identities/cleanliness were unchanged;
index remained empty. The terminal compiler/proof process audit was empty; the diagnostic lane released.

Source/model review remains open. In particular, speculative conflict rejection against an earlier
uncommitted cohort candidate is not equivalent to rejection against an installed predecessor. Model
fragment retirement/resident credits, post-halt immutable PUT behavior, close sequencing and definite
failure resumption also need exact source correspondence. Fresh scheduler fault tests, actual Ada trace
replay, TLC/TLAPS/SPARK and balanced cross-architecture performance remain mandatory before adoption.
No tests, formal tools, timed runs, dependency/APM update, staging, commit or push ran in this stage.

The subsequent pipelined conflict hunk now keeps a younger conflicting candidate pending instead of
rejecting it against an unpublished selected prefix. Installed-history conflict rejection and the
legacy nonpipeline experiment are unchanged. Independent source review found no loop, bound or
failure-order defect in the hunk. The architecture distinguishes this successor rule from the initial
exact-width experiment. Current runtime SHA-256 is
`b0d3fc62f1b666fcd05a6d747e312465ca35f43a7c9e0794af8123503be2616a`; this later hunk has not yet
compiled or executed, so the preceding successful compilation does not authenticate it. A focused
earlier-success/earlier-definite-failure regression is being added through the existing engine harness.
The model must also represent conflict-triggered underfilled freeze explicitly. No qualification or
commit is inferred from this repair, and the other source/model/replay boundaries above remain open.

## Conflict freeze correspondence and first deterministic failure

The finite model now includes `SelectedConflictBoundary` in the existing freeze trigger. It requires
a nonempty compatible prefix and a joined immediate successor conflicting with that prefix or an
unpublished cohort, excluding installed-history conflicts. Global guards and invariants are unchanged.
Independent Astra pre/post-hunk reviews found no actionable P0/P1/P2; no formal tools ran, so this is
correspondence source repair rather than invariant or progress evidence.
Model SHA-256: `74e83adf4d12feb456277c5a62daa32eef43ae96b784667540537521242297d0`.

Two fresh-root conflict regressions were added with a scoped five-second observation timer before
the ten-second cohort wait. They distinguish older success from definite pre-HEAD failure, check
per-member receipt identity/sequence and publication geometry, and reopen to verify the authoritative
value. Independent Astra review found no actionable P0/P1/P2. A single provisioned formatter pass
on the test body exited zero; no second formatter pass touched the runtime.
Test source SHA-256: `55b9ff3919ca069a02b0a6eb41fe9c2818d564f31e1f731540e28ff8e0ece0df`.

The maintained deterministic command compiled the current runtime, passed repository checks and built
the test executables. It then stopped on `PROGRAM_ERROR: adaptive exact-byte split changed cohort
identity`, before reaching the new regressions. This is rejected deterministic evidence, not PASS.
The enclosing tee pipeline exited zero without pipefail; that wrapper status is not the maintained
script's exit status. The retained explicit engine failure and missing final sentinel establish failure;
no retry was performed. Log SHA-256:
`3a930f0d9263da57a97e8e14b5147a9013812382e7da9ef11efd3b53cfee1ec6`.
Current compiled runtime remains `b0d3fc62f1b666fcd05a6d747e312465ca35f43a7c9e0794af8123503be2616a`.

The failed fixture pauses both coordinator selection and member preparation, expires its ten-millisecond
wait, then assumes all three queued members form a prepared prefix. Diagnosis is checking that
assumption against the new ready-only selector; no publication policy is changed to satisfy a fixture.
Known Task_Info deprecation diagnostics remain retained, including the new scoped closer's same warning
family. No new unrelated diagnostic family was observed.

The architecture's P2 residency overstatement was corrected and independently reviewed findings-clean:
the formulas cover admission-accounted pending extents and active-cohort images, not detached collector
arenas, installed history or any receipt custody. Collection releases logical credit before reclaiming
its arena, unlike preparation retirement which joins while credit is held. No enforced total resident
cap is claimed. Architecture SHA-256: `aa086a4ff07049032062b121d63aa55248257682f976be97b3f31ba1a338740c`.

APM and ignored Alire lock remained exact. The maintained suite generated release-profile config:
ADS `81fe872e46cd449fe9d2c39feedbfee8841f23c0cdcfae74c152361ba0501ea9`,
GPR `1c0a1f6fd2313ef3a27f5faff67f1610069e2f7b723adfe23bc205b2dacb572a`,
H `7107b2fb881492f14d58b87665d996681277c338342ec08b48849eef8cfb3a66`.
These maintained ignored outputs are preserved, not labeled unchanged development config.
All three retained dependencies remained at their authenticated clean commit/tree identities, and the
index remained empty. The owned test TMPDIR was empty after failure. The terminal host audit found
no DB test/compiler child; an unrelated Flyology NUMA test/build family was active and untouched.
DB releases its diagnostic executable lane. No performance/formal run, dependency/APM update, staging,
commit or push occurred; full adoption and the architectural performance objective remain incomplete.

The expired-byte fixture was subsequently corrected after independent source diagnosis. It retains
the same three transactions, bytes, expiry and durability work, but accepts only readiness-dependent
contiguous partitions 2+1, 1+2 or 1+1+1. Every member must retain its exact transaction ID and consecutive
sequence; each cohort must use its first member's batch ID, fit the encoded 256-byte bound and account
for exactly one batch and HEAD PUT. Manifest counts remain unchanged. The separate preceding equality
fixture still requires a two-member exact-256-byte cohort. No scheduler priority or timing window was
changed to manufacture occupancy. Public receipt observations do not prove maximality among members
simultaneously ready; that remains an explicit concrete conformance obligation.
Independent Astra postpatch review found no actionable P0/P1/P2. Diff, Ada 110-column and shell syntax
checks passed; no additional formatter pass or execution followed this correction.
Superseding test SHA-256: `fe5e65e6afc214c4e5adba35f5bde6157276204ae76663979716a85b7a72d832`.
Superseding tracked binary diff SHA-256:
`fc523733a0355ca3182a316bf89e9223d98d22501c57939cdbf2ee81ab9ad4a7`.
This source repair has not compiled or executed. The failed log remains unchanged and is not reused
as passing evidence; the goal remains active, with concrete shutdown/recovery replay, source/model
correspondence, full qualification and matched two-architecture performance still outstanding.

## Current canonical pipeline foundation: deterministic gate

The split CPU-seal/immutable-PUT foundation now has a guarded terminal drain for descriptors awaiting
PUT. It verifies the descriptor count before mutating ownership, classifies retained work as fenced or
storage-failed without dropping its image or identities, and blocks rather than spinning when a
transient halt has no awaiting descriptor. Independent ownership review found no actionable P0/P1/P2
in that narrow repair. Runtime source SHA-256:
`a2679b5961123e4008aee1ac5083aeeaca3518ebf5c91cf6a151c8b22972f905`.

The close-tail and predecessor-conflict fixtures now assert final receipt, sequence, publication, and
reopen facts without requiring one notification order or a cohort shape that the ready-only selector
does not promise. Database-capacity fixtures use their own exactly accounted Memory store, so earlier
unrelated objects cannot consume their provider slots. Independent fixture reviews found no actionable
P0/P1/P2. Test source SHA-256:
`eceeff02002412cbe9c84903aefc1e08caa231250c0f59ea5df19379a9fc0046`.

The full maintained `./tests/scripts/test.sh` exited zero, not merely its diagnostic engine subrun.
It passed repository checks, the engine corpus, the client-backed workflow, authenticated Object
Storage end-to-end, Files crash/recovery, the limited showcase, 32 adapter tests, four selected pinned
TidesDB upstream tests, and the final `Flyology.DB deterministic test suite passed` sentinel. Retained log SHA-256:
`fcc4f80ca362d4ce0dd06465864c378a33813ce9eb5e35e0ee7fd84f69fbb994`.
The established `Task_Info` and showcase body-completion diagnostics remain informational; no new
error family appeared. `git diff --check` passed and the index remained empty.

This closes only the deterministic foundation gate. The changed adaptive model has not yet completed
TLC/TLAPS, no concrete adaptive Ada trace replay is claimed, and no post-foundation equal-semantics
x86_64/ARM64 timing has run. The 2–3x architectural performance objective is still open; neither
older packed-fixture ceilings nor the copy screen can substitute for these gates.

## Post-foundation x86 screen: current preparation-before-freeze is a no-go

The maintained full deterministic suite above qualified the source for exploratory timing. The first
new `check-tla.sh` run was deliberately interrupted during the first of 24 new admission-order slices
after the established earlier lanes had run for roughly 80 minutes. It exited 130, left no TLC/TLAPM
child or owned temp root, and is **not** formal evidence. A complete TLC/TLAPS run and concrete Ada
replay remain required for any implementation that survives the performance gate.

The x86 experiment force-built the exact current runtime `a2679b5961123e4008aee1ac5083aeeaca3518ebf5c91cf6a151c8b22972f905`
from Git base `613ad2b054725e99b73117f03ae38e213fdfaef7` plus tracked binary diff
`8c7e040fb3c56fb415f2acf8b7bd1063dbe692cea893ca497697bae02ff66c9c`. GPR source resolution
named that runtime, not the previous experiment. The optimized panel hash was
`01a211adb39213e6d6b20896e1f4c7579456bb33e02e6ee028539fb75115f8c6`; the optimized SlateDB
library hash was `acdfe30461b2c3b4f8704056682becadf4fd255dc08f1c80a4ae571e8afa1606`.
The first build-wrapper attempt failed before cloning/compilation because its checksum command used the
SSH login directory; its log was retained. The corrected force-build completed, including source-map
and unchanged-source checks. Its SSH transport lingered childless after the final build sentinel and
was closed; this does not supply a clean enclosing transport exit for that build invocation.

The subsequent independent x86 screen exited zero with its final sentinel. Each of two reversed-order
outer blocks ran ten internally balanced paired samples per comparison, eight warmup plus 35 measured
transactions of 256 mutations, 16-byte keys and 1024-byte values, and reopened all 11,008 keys at
the same exact digest. Batch/HEAD counts matched and manifests remained zero. The first block found
SlateDB 24.34 ms versus 1/1 DB 60.14 ms, and SlateDB 23.71 ms versus 2/2 DB 76.25 ms. The reverse
block found SlateDB 24.75 ms versus 1/1 DB 61.19 ms, and SlateDB 23.41 ms versus 2/2 DB 76.26 ms.
Direct 1/1-versus-2/2 pairs also made 2/2 slower in both blocks. The 2/2 SlateDB pairs published
exactly 35 batches and 35 HEADs for 35 logical commits in every measured execution; 1/1 usually
formed 18–28 cohorts. Thus extra preparation/publication concurrency fragmented the ready prefix
instead of amortizing it. This is a non-monotonic architectural failure, not a sub-10% improvement.

The Linux power detector returned `unavailable/unknown` before and after. These results are a quiet,
same-host exploratory screen, not verified power-profile comparability or a cross-architecture claim.
The exact raw evidence archive is
`../foundation-natural-screen-20260916-v1/artifacts/x86_64-evidence.tar.gz`, SHA-256
`dac03052be039191c96d5e2d93a16fc4b561a0692e1da9729624690f79859669`; its internal file
checksums verified. The validated summary SHA-256 is
`6df76091732320007deab465ad194c1a091aa921db2985648283201273132332`.
The ARM timed screen and further configuration sweeps were stopped at this no-go boundary.

Source review identifies the proximate mechanism: the shared CPU workers attempt cohort selection
before their next canonical member preparation, and the selector requires `Member_Ready` for each
prefix member. A 1 ms wait starts at admission, not readiness. With two workers, a ready oldest member
can be frozen as a singleton while younger admitted members are still preparing. This is a causal
hypothesis supported by the repeated 35-publication geometry, not yet a measured phase attribution.
The next distinct architecture to test is freeze of an ordered raw admitted cohort followed by
cohort-level CPU sealing, with bounded immutable PUT and HEAD publication overlap. The existing
batch builder has a raw-arena path, but changing the worker/slot handoff requires a fresh ownership,
failure, cancellation, deadline, and model review before adoption. The current per-member-preparation
foundation is not promoted or committed; no 2–3x/parity claim follows from this experiment.
