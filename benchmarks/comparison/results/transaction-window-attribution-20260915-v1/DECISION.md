# Window-scoped attribution: a large caller-side copy path warrants a bounded experiment

This is diagnostic evidence, not a promoted optimization, a performance comparison, or completion of the
2–3× architectural objective. No runtime/model change, build, formal run, commit, or push occurred.

## Capture and verification

The fresh v2 capture used the unchanged retained optimized v5 x86 binary. Its SHA-256 is
`6bc8b3175ffdaf64a52f059d9fbb329b08c07bf88e46f82229ba2b9f364f76dd`.
The collector SHA-256 is `24557348b033fba3e6a50299d08ea96c5e705998022b32e4b8f10a94347c273c`.
Root-owned input and output remain under `/mnt/flyology-bench/experiments/` on the retained x86 host.
The profile retained natural independent singleton submissions, depth 32, preparation width one,
maximum members eight, encoded-byte target 2,159,008, 10 ms wait, and R2/C2. No private pause or packed waves.

One start/end pair on caller TID 688992 delimits 65,328,528 ns. The Ada elapsed report is 65,335,683 ns.
Markers are the authenticated post-first-Clock and pre-last-Clock instructions, not identical Clock boundaries.
All inherited benchmark threads are included within those timestamps; warmup and reopen verification are excluded.
The benchmark exited zero and verified all 11,008 keys with digest
`090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb`.
Raw perf inspection found zero `PERF_RECORD_LOST` records. Parser stderr is empty and sync enter/exit pairs match.

Raw data: `artifacts/x86_64-v2/perf.data`, SHA-256
`d4dca7e8b41b68fbe14ca764a64d9cf6d33c4b33f3d3bc94f197236abc140640`.
Window analysis: `artifacts/x86_64-v2/window-analysis.json`, SHA-256
`4051f714620ba2c4ee934a86814db47c43dd1a68c06d18868cd1be95638ed882`.

## What changes the next action

There are 289 user-CPU samples at a nominal 250 µs software-clock period, across eight sampled threads.
Caller TID 688992 has 181 samples. These are statistical CPU observations, not measured component wall times.

| Location | Samples | Share of all window user-CPU samples |
|---|---:|---:|
| DB Store_Mutation | 87 | 30.1% |
| Benchmark Value_For | 66 | 22.8% |
| Worker-side MD5 transform | 56 | 19.4% |
| All other locations | 80 | 27.7% |

Store_Mutation samples concentrate at offsets 0x78a–0x7fa from symbol base 0x330120.
Authenticated disassembly 0x330894–0x330921 shows the value-copy loop: scalar byte load/store,
repeated candidate/source bounds loads, overflow checks, and per-byte branches. The source is the
candidate-payload value copy in `src/flyology-db.adb` around line 15740, before abort-deferred adoption.
This is not evidence that the four coordinator calls dominate: their prior removal ceiling remains rejected.

The nominal 87 × 250 µs ≈ 21.75 ms of caller CPU is large enough to justify checking whether a bounded,
portable whole-array copy or packed representation can remove a substantial fraction of this loop cost.
It is not proof of a 21.75 ms saving. Sampling uncertainty, probe overhead, storage overlap, and changed
cohort occupancy must be resolved by balanced end-to-end experiments before accepting even a 10% claim.
Even nominal perfect removal yields only about 1.5× for this instrumented window, not the 2–3× goal.
This experiment must identify a meaningful removable component of a larger route, not redefine completion.
Any candidate must retain owned independent bytes, exact non-one lower bounds, mutation replacement bounds,
allocation-failure atomicity, stale/unknown/lifecycle checks, abort-deferred adoption, and compatibility.

Value_For is benchmark fixture work, not DB overhead. Its scalar signed arithmetic/modulo checks are also
visible in assembly. Both engines generate inside their clocks, so this is not unequal timing scope;
do not count accelerating only the Ada fixture as a DB improvement or hide input generation outside one timer.
Worker MD5 samples may overlap caller work and do not establish a ≥10% removable critical-path share.
No isolated MD5/CRC experiment is authorized by these shares alone.

There were 36 complete fsync calls inside the window, all successful, with summed durations 6,699,111 ns.
This sum includes concurrent threads and is not an additive wall-time share. Exact batch/HEAD counter values
were not emitted by this standalone invocation; do not infer a precise cohort distribution from syscall counts.
No fdatasync call occurred. Kernel/off-CPU/rename/write attribution is not covered by user CPU samples.

## Failed setup, cleanup, and preservation

The v1 collector failed before benchmark launch because tracefs rejected Python append-mode opening.
Its input remains retained as `input/profile-window-v1.py` and on the host. No timing is claimed from it.
The corrected v2 uses one O_WRONLY command write, no seek/append/truncation, and a fresh event namespace/output.
The capability smoke on `true` is not benchmark evidence. Hardware cycles are unavailable on this host.

Independent collector review identified and closed launch-handle, registration-interruption, descendant-drain,
and both-event-removal P1s. The final closure review found no remaining P0/P1 or actionable P2.
Handled signals are deferred until the owned target handle exists; cleanup verifies no live owned PGID member
before removing the exact two events. Both event removals are attempted. The final event inventory is empty.
The SSH/profile command exited zero. Fresh exact-basename process audit emitted RESOURCE_AUDIT_CLEAN and
FORMAL_AUDIT_CLEAN. The database root is intentionally retained; both hosts remain retained and the lane is released.

Power detection is unknown (`linux/unavailable/unknown`), so this remains an exploratory diagnostic, not
verified-profile comparative qualification. No ARM profile or A/B performance run was performed here.
An unprivileged Git read initially failed on the root-owned source; its empty-stream hash is invalid.
The corrected owning-UID read reproduced HEAD `613ad2b054725e99b73117f03ae38e213fdfaef7` and diff
`701ecac312e2c6a6a41cb14354bbe378198e340bbfa4c8f32d3e1f3829b59742`, with zero staged paths.
Retained root/benchmark locks remain `5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3`
and `440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc`.
Local tracked diff and AGENTS/APM boundary are unchanged. Full dependency inventory is not promoted by this profile.

Independent raw-evidence review reproduced every count, duration, digest, and cited artifact hash above.
It found no actionable P0/P1/P2 in the narrow next-action claim, while explicitly rejecting a 2–3× claim.

Next: independently review the narrow owned-copy/representation experiment, then measure a corrected optimized
candidate against the unchanged baseline with exact bytes/reopen/digest and actual publication counts. Stop on
semantic mismatch or insufficient end-to-end gain; close pipeline correspondence/replay/proof gaps before adoption.
