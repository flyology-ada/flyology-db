# Preparation attribution: significant Put occupation, not yet removable cost

## Exact run

The isolated x86_64 build used base `613ad2b054725e99b73117f03ae38e213fdfaef7`
and tracked source diff SHA-256
`b4850b89330e9489d84e63c166410c6da9ffb2f515b0cda43dff0e794df902a3`.
The force-build completed successfully in 246.96 seconds. Its GPR source map selected
the new attribution adapter, not the prior experiment. The preparation wrapper
then failed only at a `strings` check for a contiguous JSON field name; GNAT did
not preserve that text contiguously in the executable. No measurement ran under
that failed wrapper. The corrected run wrapper authenticated the source map,
build log, executable hashes, and actual emitted fields without rebuilding.

The maintained paired workload was 35 transactions x 256 mutations, 16-byte
keys, 1024-byte values, and eight warmup transactions. Diagnostic and control
series each contained ten balanced paired samples. All 44 executions reopened
and verified 11,008 keys with final state digest
`090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb`.
The diagnostic series observed 20-27 batch/HEAD pairs and zero manifests.

| Transaction-window median | SlateDB | Flyology.DB | Ratio |
| --- | ---: | ---: | ---: |
| Instrumented | 25.570 ms | 60.812 ms | 2.38x slower |
| Same-build control | 23.474 ms | 59.974 ms | 2.55x slower |

Across ten instrumented Flyology executions, the median sum of serial caller
preparation brackets was 54.939 ms. Nested elapsed brackets measured 0.663 ms
in Begin, 11.873 ms generating fixture keys/values, and 41.968 ms inside DB.Put
calls. The caller task consumed 45.427 ms of CPU during preparation; the median
wall-minus-task-CPU difference was 9.726 ms. These are medians of separate
summaries, so they are not additive. Per-mutation clocks and accounting perturb
the run. All diagnostic pairs preceded all control pairs, while SlateDB also
shifted from 25.570 to 23.474 ms. The 0.838 ms Flyology median difference is
not an isolated estimate or bound for instrumentation overhead.

The Put bracket includes synchronization, allocation, validation, copying,
and possible waiting or preemption. It does not isolate CPU or identify what
can safely be removed. Publisher work overlaps preparation, so the 41.968 ms
must not be subtracted from the 60.812 ms primary window as a predicted gain.
The same-build control is 36.500 ms behind SlateDB; the total Put bracket is
only a ceiling, not a demonstrated 36.500 ms removable opportunity.
An independent raw-data review bounded CPU occupation within Put brackets at
at least 32.337 ms median by subtracting non-Put elapsed time from total
preparation task CPU. That is observed occupation, not removable cost.

## Evidence and decision

The raw evidence is sealed in `attribution-v1-evidence.tar.gz`, SHA-256
`3015595b094f2d1e0769aa7dc8e9e81e8cb962d105d61dab16a5cd443603e912`.
Diagnostic analysis SHA-256 is
`d2f2b9d64bb17fbe697ecb95ef2519823d545f6baee523565635dd958400b557`;
diagnostic and control raw-metrics SHA-256 values are respectively
`6b805f10adb6006d0ded8ec609e9b8db6fd8a054fc715b23e746607095b6aab2`
and `2e1f7b0035e297c4264c825da66def1ce57019164b94ba8f08e8558811b5708e`.
The wrapper exited zero, source and binaries were unchanged post-run, its scratch
was empty, and the pre/post power-detector output matched. Linux power profile
remained `unavailable/unknown`, so this is exploratory quiet-host evidence, not
verified matched-power or cross-architecture qualification.

The independent review found no P0/P1 evidence error. A P2 provenance limit
remains: after the build wrapper stopped at its brittle string check, the run
wrapper created the binary hash manifest immediately before the run. Its
pre/post checks prove binary stability during measurement, not hash continuity
from the force-build instant. The build log, exact GPR source map, source diff,
and emitted attribution fields establish the selected source. Future campaigns
must retain a build-time binary manifest without overwriting it.

Do not promote the current pipeline or infer parity from this diagnostic. The
next bounded test is a diagnostics-off CPU/off-CPU profile of the unchanged Put
path, with direct balance between profiled and unprofiled controls. It must
attribute validation/gates, allocation, copying, and waiting before selecting
one specific removable cost. Consider a transaction-local mutation-assembly
prototype only if that cost supports a credible material end-to-end saving.
An independent architecture review estimated that removing three coordinator
entries per Put would need about 446 ns per entry for a 20% whole-window gain;
the current trace does not show whether that cost exists. Reaching the SlateDB
control median from 59.974 ms requires 36.500 ms, roughly 87% of the observed
Put elapsed bracket if all other costs stay fixed. A consolidated validation
call alone is therefore not a demonstrated parity route and should not be
promoted merely for a 20% gain.
Any prototype must retain close/fencing, bounds, conflicts, cancellation, exact receipts,
and durability; changed publication semantics require TLA+/TLAPS beforehand.
Measure one equal-state control/prototype pair on both x86_64 and ARM64 and
stop if the end-to-end improvement is not on a credible route to parity.
No production change, formal proof, local commit, or push follows from this run.
