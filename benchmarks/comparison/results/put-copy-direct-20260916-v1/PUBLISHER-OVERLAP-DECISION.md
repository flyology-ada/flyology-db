# A second publisher does not close the gap

This is an exploratory x86_64 stop decision, not a completed balanced
qualification or a production performance claim. The same optimized
direct-copy benchmark executable and workload were used for both completed
arms: 35 transactions x 256 mutations, 16-byte keys, 1024-byte values,
eight warmup transactions, ten balanced SlateDB/Flyology.DB pairs per arm,
reopen verification of 11,008 keys, and the same final state digest. The
only configured difference was the maximum number of concurrent publisher
cohorts: one (C1) or two (C2). This knob does not by itself prove that useful
batch/HEAD I/O overlap occurred.

| Completed arm | DB median | SlateDB median | Batch/HEAD pairs |
| --- | ---: | ---: | ---: |
| C1, one publisher | 40.098 ms | 24.392 ms | median 7, range 6–7 |
| C2, two publishers | 48.188 ms | 23.946 ms | median 26.5, range 23–32 |

C2 was 20.2% slower than C1 in the two completed arms and fragmented the
cohorts. That triggers the user's monotonic-scaling stop rule. The
third arm was interrupted and the fourth was never started. Thus these two
arms are directional evidence to reject this configuration, not a balanced
C1/C2 estimate. They do not establish an isolated publisher-overlap cost or
rule out a different architecture that prepares a successor while the front
cohort publishes. The host's power profile remained unclassified, so these
timings are exploratory even though each completed arm passed exact
state/reopen and publication-geometry checks.

The retained evidence is `publisher-overlap-screen-v1/`: completed JSON,
NDJSON, logs and power files for arms 01 and 02, plus the interrupted arm 03
log and pre-arm power file. The arm-01 and arm-02 JSON SHA-256 values are
`4f116ab320dea347e74b0a197a895beb2b528e33d31e8306f8113155a44530b8`
and `302903896d2651478a78f45fe480563e16bfe5a10d620daa16a2aeec2042d7e9`.
The exact screen script SHA-256 is
`86653cb2bec3e13f28c41afc63a28c4c96a3855ef487a292e8f575fccefcd562`.
The interrupted process and its one experiment-owned 23 MB scratch database
were removed after verifying no benchmark child remained; the raw evidence
was preserved. The benchmark lane is released. The terminal cleanup and
process checks are recorded in `PUBLISHER-OVERLAP-POSTFLIGHT.md`.

Review: P0 none in completed-arm identity, state, and retained evidence.
P1: treating this one-factor configuration screen as proof of overlapping
publication would be unsound; the realized cohort geometry changed sharply.
The claim is restricted accordingly. P2: power state unknown; the two-arm
stop is not a full balanced campaign; host quiet checks do not capture every
background load; and the exploratory direct-copy binary still lacks its
maintained correctness and ARM64 gates. No production change or promotion is
accepted on this result. Do not repeat publisher-count tuning as a substitute
for a route that can eliminate roughly 40% of the remaining DB transaction
window while preserving equivalent durability and work.
