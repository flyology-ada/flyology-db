# Direct payload copy: promising adaptive effect, unresolved attribution

This is an exploratory x86_64 diagnosis, not a qualified performance claim or
a production change. Both screens used the same optimized build settings,
35 transactions x 256 mutations, 16-byte keys, 1024-byte values, eight warmup
transactions, ten balanced SlateDB/Flyology.DB pairs per arm, exact reopening
of 11,008 keys, and final state SHA-256
`090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb`.
The direct-copy build selected the isolated source body and its `Store_Mutation`
machine code calls `memcpy` twice. The source delta changes only key/value
payload copying from byte loops to imported `memcpy`, plus its private ABI
declaration and compile-time element-size checks. It changes no public API,
persisted format, or scheduler policy. The build emitted a redundant `with`
warning; it has not passed the maintained deterministic suite or ARM64 review.

| Control | Baseline DB | Direct-copy DB | Change | SlateDB pooled median | Batch/HEAD pairs |
| --- | ---: | ---: | ---: | ---: | --- |
| Adaptive cohort, eight balanced arms | 59.726 ms | 40.320 ms | 32.49% lower latency | 24.334 ms | baseline median 21.5; direct median 7 |
| Singleton, four balanced arms | 63.971 ms | 64.982 ms | 1.58% higher latency | 23.687 ms | exactly 35 in every execution |

The first row is a repeatable end-to-end *treatment effect* of the copy-only
source delta under the same configured adaptive selector. It also changes the
selector's realized publication count substantially. That count is a mediator,
not proof that fewer publications explain all 19.4 ms saved. The singleton
control removes the large gain, but it changes the scheduler path and caller
depth as well as forcing 35 publications; it is not a copy-cost subtraction
from the adaptive measurement. No isolated copy wall-time saving or causal
split is established. The adaptive effect exceeds the normal 10% screening
floor, but production promotion and a performance claim are withheld pending
warning-clean correctness, cross-architecture measurement, and a more robust
architectural route. The measured adaptive result still trails tuned SlateDB
by about 1.66x on this host.

The power-profile detector returned `unknown` before and after every arm.
The host was quiet by the script's process checks and the SlateDB medians were
stable, but a matched power profile cannot be established; all timing remains
exploratory. The singleton control was initially invoked with an invalid
depth-32 profile and produced no timing sample. The retained successful v2
control uses the maintained valid depth-8 profile and a separate output root.

Raw, machine-readable evidence is in `paired-screen-v1/` and
`singleton-screen-v2/`. Their summary SHA-256 values are respectively
`ca3e896425502e4cd00a5d08d8d55d74a780270314f865fd10f45f5426b4ac31`
and `a4f979bdde8bfc60420f17add1853b374e664a7c6668f3fcbe5f908fd77942f1`.
The direct source binary-diff SHA-256 is
`5e9b4cf6e1b41e51b80daa34d9108d6d32e45f9b0fb782c225064d7067267df2`;
the direct benchmark executable is
`c60815178eece0dea36d099c0de75f02ad1bad40d51e809e3814783f09067f73`.

Review: no P0 in retained state/data checks. A P1 causal overclaim in the
first draft treated the singleton path as a fixed-geometry version of the
adaptive path; it was corrected after independent review. P2 limitations:
unknown power profile, redundant-with warning in the exploratory build,
missing maintained tests/ARM64 evidence, no independent check of eight-bit
target C characters, and no attribution of the adaptive gain to copy work
versus scheduler occupancy. These bar promotion, not the reported adaptive
treatment effect. A second independent source review found no x86 ABI,
bounds, or ownership defect in the private prototype; its conclusion does not
extend to a portable implementation.
