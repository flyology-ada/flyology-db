# Owned-copy lowering: code generation gate before timing

This is an isolated experiment, not an adopted optimization or completion of the architectural goal.
The public runtime and model are unchanged. No performance result is accepted yet.

## Evidence motivating this bounded experiment

The preceding transaction-window profile found 87 of 289 user-CPU samples in `Store_Mutation`,
concentrated in its checked scalar value-copy loop. Nominal sampled caller CPU is approximately
21.75 ms within an instrumented 65.33 ms window; this is not a measured removable wall-time share.
It supports investigating a credible 10% component, not claiming a 2–3× route by itself.
See `../transaction-window-attribution-20260915-v1/DECISION.md` and its raw evidence.

## Candidate and preservation boundary

Only the isolated candidate replaces the existing guarded key/value byte loops with contextual Ada
array aggregates. Validation, independent payload allocation, replacement accounting, abort-deferred
adoption, and old-owner release remain in the original order. No native bridge, unchecked conversion,
public API, format, policy, or fixture change is introduced.

- Baseline body SHA-256: `46d430be91f2ab987836600490399db784b8330840672b84c9d04bf7d48e97cb`.
- Candidate body SHA-256: `4b3ba41ba407426baa4f301f296339dd59bdbe905c7c2adc188fcebd45965023`.
- Mechanical patch SHA-256: `d9fae00dc4a013871b08f1411189a2c11b5fbe40aa39d32de33d4161be05859b`.
- Force-build script SHA-256: `4be335ba837c39ff8dcc527d70bc6db98665f7431f9e70d5691ec91d7f788e2e`.

The maintained provisioned formatter ran once on the candidate. A separate canonical whitespace
correction restored the entry-family declaration. Token comparison outside the two copy segments
passed; this establishes scope preservation, not semantic correctness or performance.

## Build and stopping condition

One serial force-build campaign completed at
`/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v1-x86_64`.
It builds baseline then candidate with `alr build --release -- -f`, under the unchanged actual owning
projects. The exact retained dependency diagnostic inventory is compared, not silently suppressed.
This code-generation campaign is not a warning-strict release qualification.

Before any timing, inspect the authenticated `Store_Mutation` assembly. Reject this candidate form if
it adds an intermediate/secondary-stack image, another payload pass, or retains the checked scalar
copy without a defensible improvement. Do not run timings merely to produce another result.

If code generation passes, correctness must cover arbitrary byte values and lower bounds, empty
payloads, mutation replacement, allocation-failure atomicity, rollback/finalization, and persisted
reopen. Balanced same-state baseline/candidate measurements must retain publication counts, receipt
identities, bytes, full reopen verification, and final digest. Both architectures and all applicable
qualification/review gates are required before promotion. Normally reject sustained gains below 10%.

## Independent design review

The reviewer approved only the bounded pure-Ada lowering experiment. It explicitly rejected treating
sample percentages as wall-time savings, rewriting the mutation arena as an incidental expansion,
or counting benchmark input-generation improvements as database improvements. The model/runtime
preparation, ownership, and concrete replay gaps remain separate adoption blockers.

## Result: reject before timing

Both maintained build logs report success: baseline 249.78 seconds, candidate 249.01 seconds.
Both exact diagnostic inventories match the retained inventory SHA-256
`a1ebc2650db7a65a8c6831b1a48cbd732fb2abe456a3069d71cb1f3f3bfa2061`.
The baseline binary reproduces the preceding retained binary byte-for-byte, SHA-256
`6bc8b3175ffdaf64a52f059d9fbb329b08c07bf88e46f82229ba2b9f364f76dd`.
Candidate binary SHA-256 is `f91744ac749a91afe8908e715ae93661a3b13a2307f18b9520d6a57e81a42b72`.

The assembly contradicts the desired direct lowering:

- Key: runtime stack allocation at `0x330836`, scalar load/store loop at
  `0x330869–0x330887`, then temporary-to-owned-destination `memcpy` at `0x3308ad`.
- Value: runtime stack allocation at `0x330f54`, checked scalar loop at
  `0x330f7f–0x330fe4`, then temporary-to-owned-destination `memcpy` at `0x330aac`.

The baseline copies directly into owned storage. The candidate still copies scalar bytes and adds
a second pass plus runtime-sized stack storage. A `memcpy` symbol alone is not a vectorization win.
The independent assembly reviewer reproduced both paths and classified failure of this experiment's
code-generation gate as P1. This candidate is rejected, not deferred or promoted. No timing is needed
to enforce that stopping rule; no measured performance-regression claim is made.

Retained assembly SHA-256 values:

- Baseline: `f105407508daae7d4966871c99fa496c6fa8b36911372c5b35d6d663afc63738`.
- Candidate: `f7db7d9aab4d39e7c52c7314d1a95ffc80527b9b11776aef293e8809a303cfdd`.

The original SSH observer did not return after its remote command/compiler family exited. The final
artifacts were retrieved through a fresh read-only connection; direct postflight verified identical
diagnostics, exact binaries, unchanged retained source and locks, no compiler/formal children, and a
free campaign lock. Only then was the stale local observer closed; its enclosing status was 255.
Do not report that enclosing SSH invocation as exit zero. The authenticated successful build logs and
final disassembly establish the code-generation result independently; no qualification run is claimed.

Postflight reproduced retained HEAD `613ad2b054725e99b73117f03ae38e213fdfaef7`, tracked diff
`701ecac312e2c6a6a41cb14354bbe378198e340bbfa4c8f32d3e1f3829b59742`, baseline source hash above,
zero staged paths, root lock `5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3`,
and benchmark lock `440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc` in both
copies. It emitted `RESOURCE_AUDIT_CLEAN`, `FORMAL_AUDIT_CLEAN`, and
`DB_COPY_CODEGEN_POSTFLIGHT_TERMINAL`. The experiment trees and hosts remain intentionally retained.
The EC2 executable window is released. No timing, promotion, commit, or push occurred.
