# Serial admission diagnostic: preparation attribution, not a parity proof

## Result and scope

The first collection reached the maintained paired collector but its postflight
validator failed: it looked for raw Flyology records in the assembled comparison
metrics, and the participant name omitted the `-diagnostics` suffix that actually
enables the Ada trace. That attempt supplies no admission trace and is not used
below. The corrected driver retained that failed output and collected a distinct
`admission-v2` result with the already-built executable.

On the retained x86_64 i4i.xlarge, the corrected run used 35 transactions of
256 mutations, 16-byte keys, 1024-byte values, eight warmup transactions, ten
balanced paired measured samples, and a serial caller-preparation width of one.
All 22 executions reopened and verified 11,008 keys at state digest
`090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb`.
The measured primary transaction-window medians were 25.244 ms for tuned
SlateDB and 60.738 ms for Flyology.DB, a 2.41x gap in this diagnostic profile.
The assembled comparison's whole-process wall metric is not this primary
transaction-window metric and must not be used to claim a Flyology speedup.

The ten Flyology traces recorded a median 55.094 ms inside serial
`Prepare_Transaction` brackets, 1.959 ms in the caller `Commit` call brackets,
and 57.297 ms from the measured window origin to the last `Commit` return.
They observed 20–27 immutable batch/HEAD pairs for the 35 transactions and
zero manifest publications. The preparation bracket contains fixture key/value
generation, `Begin_Transaction`, all 8,960 `Put` calls, synchronization waits,
allocation and possible preemption. It is **elapsed caller occupation**, not
isolated Put CPU or an API-imposed floor. Worker publication overlaps it, so
subtracting 55.094 ms from 60.738 ms does not estimate a publisher-only saving.

The analyzer's 12.377 ms median fixed-eight call-start span and hypothetical
immediate-deadline groups are no-backlog sensitivities only. Actual selection
may occur later and admit backlogged members; the hypothetical 1 ms groups
are not cohort eligibility, throughput, or a proposed product timeout.

## Evidence and limits

- Source base: `613ad2b054725e99b73117f03ae38e213fdfaef7`, isolated
  tracked binary diff SHA-256
  `9882967037fe38e83b08c0e151b829dfbb600e54ea9708a255ee2d7ad27127c2`.
  The compiled source map and binary hashes were checked before the run; the
  source diff and binary hashes were unchanged afterward.
- Corrected driver SHA-256:
  `a6b900bcf606a913acc814b23060f2f8204223d6a18ef2cefe55d3c392c17686`.
  Runner SHA-256:
  `eef87a0bad6b6fafddb79f119375408752dfd025c45457dc01b9e34bab86958e`.
- Sealed raw evidence: `artifacts/admission-v2-evidence.tar.gz`, SHA-256
  `429c8c3f30311de8631cc8f4a1550e3a13b9b6dcd3ae7e0d248c22d3bc7204a0`.
  Pair JSON SHA-256 is
  `6cdd610c351a39d201bc3e34e4d9b41ed4b8d28bfffe426cf6874eade394d712`;
  raw metrics SHA-256 is
  `b61d0b6189536829c3616661fb99006ab7536def5148b64f951e0262fba83100`;
  validated analysis SHA-256 is
  `e58bdd399053c6e89941c88575e74abc639fb57356f01903be00c123b56d36cf`.
- The corrected wrapper exited zero with its exact sentinel. Its scratch was
  empty, source and binary postflight matched, and the pre/post power detector
  output was identical. Linux power detection was `unavailable/unknown` both
  times: this is exploratory quiet-host same-host evidence, not verified
  matched-power or cross-architecture qualification.

Two independent skeptical reviews found no P0 in this bounded diagnostic.
They flagged an inference hazard: 55 ms must not be called an irreducible CPU
or public-API floor. The current width-one fixture, concurrent publisher
contention, and diagnostic observer cost remain confounders. The source shows
repeated lifecycle and coordinator validation in each `Put`; that is a
mechanism to profile, not yet the measured cause of the gap.

## Decision and next gate

Do not promote the current pipeline, a wait-time sweep, or another isolated
copy/hash micro-change from this result. The next bounded attribution must
separate fixture generation, transaction-local mutation assembly, and
coordinator/lifecycle waiting on this exact workload, using caller CPU/off-CPU
or sampled wait evidence and a diagnostics-off control. Then test one
transaction-local assembly/single-validation architectural prototype only if
the measured removable share credibly exceeds 30 ms on the natural path.
Preserve immediate fencing, close, bounds, conflict checks, cancellation,
unknown receipt recovery, and acknowledged durability; qualify changed
publication semantics with TLA+/TLAPS before adoption. Repeat accepted gains
against tuned SlateDB on both x86_64 and ARM64 with the same state digest.
No production implementation, formal qualification, performance promotion,
commit, or push follows from this diagnostic alone.
