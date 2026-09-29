# Full-cohort speculative upload is a hypothesis, not a measured gain

The current objective is a material reduction of the equal-work durable
transaction window toward tuned SlateDB on both x86_64 and ARM64. No current
source or benchmark proves parity. The direct-copy x86 screen's one-publisher
arm was 40.098 ms versus SlateDB's 24.392 ms, leaving about 39.2% of the DB
window to remove. Its second-publisher arm was 48.188 ms and fractured the
batch/HEAD geometry from a median seven pairs to 26.5. That configuration is
rejected, not generalized to every overlap architecture.

The earlier typed provider capture is a different x86 source snapshot. Its
ten plain measured windows had a 37.806 ms median and six batch PUT wrappers
each. The median per-execution sum of those wrapper spans was 25.153 ms; the
longest single wrapper median was 5.556 ms. The median of each execution's
sum minus longest span was 19.474 ms. This is a deliberately optimistic
fixed-duration scheduling envelope: it assumes independent batch uploads
can overlap without staggered admission, preparation, CPU, filesystem or
device contention, and without delaying the ordered HEAD transitions. It is
not removable wall time, a current-source critical path, or a forecast. Its
size is sufficient to investigate an architecture that retains full cohorts
while overlapping immutable uploads. It cannot be subtracted from the later
direct-copy median to claim parity.

The current coordinator can already run independent immutable PUT workers;
only the front cohort may attempt HEAD. The missing piece is not a larger
publisher count. The selector walks the oldest ready prefix and stops at an
older member still preparing. An expired admission-derived cohort wait may
then freeze that short prefix. Greater preparation/publication concurrency
can expose that state sooner, which is consistent with the C2 fragmentation.
The counts do not isolate the entire slowdown.

The earlier serial-admission diagnostic supplies a useful arrival constraint,
but not a current-source timing estimate. Across its ten measured Flyology
executions, the shortest gap between consecutive `Commit` call starts in
each execution was 1.094–1.262 ms. The shortest span from the first to the
eighth consecutive call start was 9.915–11.274 ms (median 10.359 ms). Thus an
otherwise idle selector that seals promptly at a one-millisecond deadline
cannot fill an eight-member cohort from this width-one caller. A busy front
publisher can allow a later ready backlog to form, so these call-start spans
do not predict the actual cohort distribution; the older run observed 20–27
batch/HEAD pairs. The diagnostic is from a different source snapshot and
includes observer cost. Merely reserving unarrived members does not make them
available sooner; deferring selection changes acknowledgement latency unless
earlier publication overlaps the delay.

The current direct-copy x86 binary was then run once with its existing
admission diagnostics. Its ten measured executions all reopened the exact
11,008-key state and used six to eight batch/HEAD pairs. The shortest
adjacent `Commit` call-start gap in each execution was 0.522–0.609 ms; the
shortest span from the first call's return to the eighth call's start was
4.493–5.573 ms. Because protected admission precedes the first return, an
idle selector cannot collect eight of these serial submissions by a one-ms
deadline. Accumulated backlog or delayed selection can explain why some
actual cohorts nevertheless had eight members. The caller's serial
preparation brackets summed to a median
27.995 ms within a 41.530 ms DB transaction window; tuned SlateDB was
24.952 ms in that instrumented panel. This preparation span includes fixture
generation, `Begin_Transaction`, all `Put` calls, allocation and preemption;
it is not an irreducible CPU floor. Holding these measured serial preparation
durations fixed leaves a 27.995 ms floor, already above the 24.952 ms
SlateDB median. Publication-only parity would therefore also require shorter
observed preparation spans; this trace does not establish whether altered
contention could provide that reduction. The private
diagnostic is observer-affected and Linux power status was unknown, so none
of these window timings are promotion evidence. The reviewed driver SHA-256
is `0dd8a3e78da5a97889a0c6649a6d353a42e06248b5638f1222fd557930bd5530`;
retained `direct-admission-v1/` summary, pair, and metrics hashes are
`a7888f4ff8f59aa6ea9c166c2c9c9be6a872952b616d681003a9bdf27f9345ce`,
`a61c9cd3e5b52c868d7dab1490f99f809398c1229c758f4d1d1e2517c54cb286`,
and `354f8fb882e8b738296183c8c09c4869ddb8a8b01d48189994a2881c50b59d32`.
The owned diagnostic process exited and completed its empty-scratch and
source/binary postflight checks.

The next source-only design comparison is between two bounded selection
mechanisms, without changing public defaults or persisted bytes:

1. Reserve an admission-ordered cohort assembly frontier before member
   preparation completes, then seal only after its selected members join.
2. Defer selection of an incomplete ready prefix within a separately bounded
   assembly episode while an older immutable upload progresses.

Either must specify what happens when the existing wait target, an operation
deadline, close, or byte/slot capacity is reached. Resetting admission
deadlines or waiting indefinitely is not acceptable. A new externally visible
latency or assembly policy requires an explicit product decision; a private
test profile may only establish a ceiling. Neither option is approved for
runtime implementation merely by this note.

Before Ada changes, a focused TLC model and TLAPS kernel must establish:
oldest-admission ordering and conflict revalidation; bounded slots, bytes and
worker borrowing; oversized-singleton and close-tail progress; exactly one
freeze of member identities, sequences and predecessor links; speculative
immutable upload only; ordered HEAD publication; unknown-front barriers and
conclusive predecessor-failure handling; cancellation/deadline classification;
and one-owner cleanup of raw arenas, canonical fragments, batch images and
member receipts. A sealed successor cannot be rebased or replayed to recover
an ambiguous predecessor. Tight-capacity and stalled-provider behaviors need
explicit progress assumptions, not just a bounded safety search.

Before choosing either selector design, the next bounded attribution must
separate fixture generation, transaction-local mutation assembly, protected
admission and readiness, cohort freeze, and overlapping immutable PUTs on
this direct-copy source. The current trace has cohort widths and caller
brackets, not timestamps for ready/freeze/PUT; it cannot distinguish avoidable
selector fragmentation from the serial input limit. If the measured
preparation span proves largely nonremovable, a publication-only redesign
cannot supply the remaining gap and should stop. A substantial transaction
assembly or streaming overlap change would require its own ownership and
API-semantic review, rather than being hidden in a selector tweak.

Only if a design is sound should a private implementation be compared with
the existing binary on the same 35 x 256, 16/1024-byte durable workload,
without a benchmark selection pause or artificial persistent workers. The
candidate must preserve total work, state digest, reopen verification,
publication/receipt identities and acknowledged durability. Measure balanced
paired order and actual cohort membership on both architectures; stop if
realized overlap fragments cohorts, moves preparation outside the clock, or
cannot materially close the roughly 15–16 ms remaining x86 gap. Host power
classification is currently unknown, so prior timings remain exploratory.

The one direct-copy CPU profile also does not justify a mutation-copy redesign.
It retained 460 whole-process sampled stacks containing `Store_Mutation`, with
the largest leaves in tasking/locking. Those samples include warmup and the
SlateDB process interval and do not give a DB-only wall-time ceiling. The
profile's exact-state run was 40.934 ms versus SlateDB's 26.084 ms, with six
to eight batch/HEAD pairs. The raw `perf.data` and full sample text remain in
the owned EC2 experiment root; the small summary and paired metrics are in
`direct-put-cpu-v1/`. This diagnosis is no reason to promote a copy change.
An additional read-only classification of that same capture found 1,116
sampled stacks under Ada `Prepare_Transaction`: 626 in the benchmark's
`Value_For` fixture generator, 460 in DB `Store_Mutation`, and 30 elsewhere.
These are sampled user-CPU stacks, not elapsed-time shares or a comparison to
SlateDB's fixture generator; the current analyzer does not classify Rust
fixture work. They make fixture generation a serious attribution confounder,
not an optimization target for the database. Both adapters generate equivalent
bytes inside their timed transaction window, so the complete-workload
comparison remains valid; it does not isolate storage-engine cost. The next
diagnostic must bracket fixture generation and transaction/`Put` work in
*both* adapters while keeping all work inside the measured window and
preserving identical generated bytes. A separate prepared-input diagnostic
could identify the engine-plus-scheduling gap, but only alongside the
generation-inclusive result: removing generation changes admission timing
and cohort occupancy, so the two windows cannot be subtracted. No
storage-engine speedup may be claimed by moving fixture work outside the
primary clock.
The read-only analyzer SHA-256 is
`234868a016e849395dba27137810c3a9287e77a239075937641ccacb22d4c866`;
its retained normalized output is `direct-put-cpu-v1/preparation-cpu-summary.json`.
The reviewed profile driver SHA-256 is
`5bac2d5ac290b99a32e4a3f12da58b809e9e7d34941c44696a1f03490efe9ace`;
the local summary and metrics hashes are
`781107d1e03260378b7a83483714079e5a735ec1b4710ff478c8741907d0a722`
and `e30dcefff3f65f6759d5d2a3f3ea4ddff46d8f43520e96ca83a76939e4735552`.
Remote `perf.data` and sample-text hashes are
`66e9bfc1b531fa93d600c8b7966fc1c3cc258dae245197f3e2ecdc5a3ebe7b38`
and `f9eabd3dd41e79a84cca1f8c0daa7a2e3d43116e6dd17d1eabe4b64e4bd72bcc`.
