# Generation-bound lazy SST reads

The LSM storage slice makes immutable SST-v2 runs range-readable without weakening persisted integrity or silently
adding storage I/O to the established storage-free public `Get`, `Scan`, and `Next_Scan_Page` contracts. An additive
caller-composable `Get_Operation` and buffer-owned synchronous `Get` now opt into storage-backed point reads. SST
version 1 remains readable through its generation-bound whole-object decoder. New Flush and compaction outputs use
additive SST version 2, whose exact entry frames can be authenticated independently after one authority observation,
one header range, and one index range.

This is a format and certainty mechanism, not an automatic cache, block-size, prefetch, timeout, retry, or
compaction-selection policy. The caller-driven operation supplies explicit deadline, cancellation, moved buffer
ownership, and completion-set authority. Existing public APIs that promise no storage I/O remain unchanged; callers
select the additive overload by supplying the unique scratch buffer or an established `Get_Operation`.

The checkpoint selector composes that one-run mechanism across one exact
oldest-to-newest manifest run slice at a fixed transaction snapshot. It copies
the exact descriptor extent into operation-owned storage, traverses newest to
oldest, skips a run without I/O when its lowest sequence is newer than the
snapshot, and falls through only after an authenticated key absence. The first
visible value is returned; the first visible tombstone conclusively masks all
older values. One absolute deadline, cancellation token, and moved scratch
token govern the complete traversal. Every child is finished and released
before the next starts, so there is no helper task, parallel fanout, automatic
retry, or library-selected run cap. Future-run skipping and authenticated-
absence fall-through each reschedule one bounded parent step, so an exact
persisted run count never becomes recursive owner-stack depth.

The composed path accepts mixed SST-v1/v2 runs. A bounded prefix first
authenticates either frozen header against the exact manifest descriptor and
observed generation. Version 2 continues through its index and one selected
frame. Version 1 has no independently authenticated index or frame, so it uses
one generation-bound whole Get only when the header-admitted exact object
length fits the caller-owned scratch token, decodes the complete object, and
selects the first snapshot-visible entry. Capacity rejection, generation or
length mismatch, corruption, cancellation, and failure publish no value and
do not fall through to an older run.

The same private operation has a next-visible-entry purpose used by
authenticated physical scan construction. Its caller supplies the fixed snapshot plus an optional
inclusive or strict start and an optional exclusive upper bound. The operation
selects the first canonical key whose first version no newer than the snapshot
is admitted by those bounds. A tombstone is returned with its exact key and
sequence so the later multi-source merge can suppress that key while advancing
the run; complete absence returns no key. SST-v2 authenticates the index and
only the selected frame. SST-v1 uses the required whole-object fallback. Typed
Finish returns one owned key/value pair and releases the decoded index/frame;
the operation retains no whole run after Finish and introduces no page size,
prefetch, cache, retry, or run-selection policy. The compatibility `Start_Scan`
initializer repeats this strictly after each selected key and compacts selected
entries before invoking the physical merge. The storage-backed initializer
retains only run descriptors; its page operation uses the same next-entry child
to maintain at most one authenticated head per run and advances all equal-key
heads after selecting newest authority. The buffer-owned whole `Scan` composes
that path with one complete page under persisted live limits.

## Why SST version 1 cannot stream safely

SST version 1 is one variable-length entry stream followed by a single object CRC. Its header authenticates total
extent and descriptor facts, but an individual range contains neither an independently authenticated entry nor an
index binding that entry to its key and sequence. Reading a value range without the rest of the object would skip
the format's corruption check. Provider generation binding prevents mixed object versions; it does not replace the
persisted integrity contract.

The implementation therefore must not claim lazy SST-v1 validation. A v1 run is read and checked whole, or the read
fails. Mixed manifests may retain v1 and v2 runs; compaction may read either version and emits only the current writer
version after that version is accepted.

## SST version 2 codec

SST v2 retains the same database, run, family, sequence interval, entry count, logical byte count, canonical
unsigned-byte key order, descending sequence order within a key, operation encoding, and immutable object identity.
It changes framing as follows:

- the authenticated header carries exact frame-region and index-region byte extents;
- each variable-length entry frame carries the established sequence, operation, key length, value length, exact key
  and value bytes, plus a CRC over that complete frame;
- the trailing index has one canonical record per entry containing the frame offset and extent plus the duplicated
  sequence, operation, lengths, and exact key bytes needed for lookup and merge;
- the index has its own CRC, and the object retains a whole-object CRC for complete reads and offline validation;
- a range-decoded frame is accepted only when every duplicated fact matches its authenticated index record.

One entry is one integrity frame. This deliberately introduces no selected block size or entries-per-block ceiling.
Frame and index extents derive by checked arithmetic from exact admitted entry/key/value lengths and the persisted
database and column-family limits. The index may be retained or cached only under separately admitted byte authority;
allocation failure is typed backpressure and publishes no partial read state.

The exact wire offsets, widths, version/magic bytes, and golden image are frozen in the private whole-object codec
and documented adjacent to their declarations and in `persisted-formats.md`. Durable run publication and
storage-backed public point-read execution are active. The storage-free overloads remain unchanged.

The private range-local codec consumes the exact index and frame slices described below. Index decoding
authenticates the complete index CRC before parsing any record, validates canonical contiguous frame geometry and key
ordering, and retains exact descriptor/key authority in one lazily allocated value. Frame decoding accepts one exact
index-selected extent, authenticates its CRC, and binds sequence, operation, lengths, and every key byte before
allocating output. These routines perform no Object Storage call and therefore do not themselves establish that the
slices came from one provider generation; the caller-driven operation establishes that authority.

## Public composition and ownership

`Get_Operation` is declared directly in `Flyology.DB`; scoped lifetime is expressed by the limited operation,
caller-owned completion set, retained borrows, cancellation, and typed `Finish`, not by a parallel namespace. The
established operation retains the open `Database`, active `Transaction`, payload pool, and optional cancellation
token until terminal publication. The caller must not use the transaction concurrently. Family and key facts are
copied before initiation returns.

Start first validates the database incarnation and fixed transaction snapshot, then resolves transaction-local
mutations and the committed post-checkpoint suffix without Object Storage I/O. Only an unresolved key copies the
exact immutable run descriptor slice and starts the mixed-version checkpoint selector. One absolute monotonic
deadline and one exact caller-owned buffer token cover the complete path. Completion-slot rejection restores the
database lease and leaves the caller's bytes, length, tag, and token ownership unchanged.

Typed `Finish` is the sole normal restoration authority after successful initiation. It accepts any vacant handle
from the same pool, restores the exact moved token, consumes the terminal result, and returns value bytes only for
`Success`. Serializable point-read authority is retained only after a conclusive external `Success` or `Not_Found`;
transaction-local reads do not create an external observation. The synchronous buffer overload is a literal
`Wait_All`/`Finish` owner-stack wait on that same operation. This first public slice provides an established reusable
operation rather than a limited constructor: an access parameter controlling the tagged `Database` and a result
controlling `Get_Operation` would make one Ada function dispatch on two tagged types. No alias or compatibility
wrapper is introduced to evade that rule.

## Range-read protocol

1. Use `Head_Object` to observe the exact object extent and opaque provider generation without retaining a body.
2. Read the exact v2 header range with `Expected_Entity_Tag` equal to that observed generation. A replacement between
   HEAD and this range read therefore rejects before a candidate header exists.
3. Validate magic, version, kind, database/run/family identity, object length, sequence interval, entry count, logical
   bytes, checked frame/index extents, and header CRC before allocating variable storage. The object length in the
   header must equal the authoritative HEAD extent.
4. Read the exact index range with the same `Expected_Entity_Tag`. Validate its exact
   range, length, canonical records, ordering, bounds, uniqueness, and index CRC before publication.
5. Select an exact key for a point read, or the first snapshot-visible key/version admitted by the normalized scan
   bounds. Read exactly its frame with the same required generation.
6. Validate the frame CRC and every index-bound field and key byte before exposing a value or advancing a scan
   position. Delete frames expose absence/tombstone authority, never value bytes.
7. A stale generation, malformed range, allocation failure, cancellation, or incomplete response leaves the prior
   result and cursor position unchanged. No mutation or read is automatically replayed.

Once header, index, or frame bytes are fully returned and authenticated, a later provider replacement cannot change
those owned bytes. Before that boundary, any generation mismatch rejects the candidate. Listing never participates.

## Formal and executable boundary

`LazySSTRead.tla` treats successful HEAD observation plus generation-bound header validation as one atomic `Begin`
boundary. It checks exact-generation index and frame reads, index/frame binding, allocation rejection, corruption
rejection, and success after a provider replacement that occurs only after the frame is owned. Negative probes
deliberately read a newer generation under an older header and substitute a frame for another key. A checked witness
follows Begin, index, allocation rejection, exact frame, concurrent replacement, and successful publication.
`LazySSTReadSafetyProof.tla` proves the abstract generation/binding/failure-atomicity action kernel for arbitrary
finite generation, key, and value sets. Replacement between HEAD and header validation is outside the published
candidate state and must fail through the generation-bound Object Storage range result.

`LazyCheckpointRead.tla` checks fixed-snapshot newest-to-oldest selection,
future-run skipping, authenticated-absence fall-through, tombstone masking,
exact value publication, and failure atomicity. Its three runs, two keys, and
four values are finite qualification geometry only. The companion
`LazyCheckpointReadSafetyProof.tla` proves the publication, failure, request,
and cursor-preservation action kernel for arbitrary nonempty snapshot, key,
value, and exact run-count domains; the finite model, not the kernel, owns the
newest-visible-run calculation.

`LazySSTNextEntry.tla` separately checks the within-run rule needed by a
streaming physical cursor: descending-version fallback at one snapshot,
inclusive and strict starts, an exclusive upper bound, conclusive tombstones,
one selected frame, and failure atomicity. A negative probe deliberately skips
the first visible entry. Its canonical witness selects the historical
tombstone for key `a` under `[a,b)`. `LazySSTNextEntrySafetyProof.tla` proves
the abstract request/selection/frame/output action kernel over arbitrary
request, position, and value domains. The finite model owns the concrete
three-entry ordering calculation; neither artifact is a byte-comparison,
codec, provider, progress, Ada-refinement, or constant-memory proof.

The formal geometry is not a format bound, cache size, request count, retry budget, or public default. The model does
not prove CRC arithmetic, byte offsets, range arithmetic, the Ada codec, provider behavior, progress, concurrency,
or refinement. The private whole-object codec covers independent v1/v2 goldens, v1 compatibility, every v2
object truncation, exact extent checks, whole/index/frame CRCs, repaired-checksum index/frame binding, intact-frame
substitution, shifted lower bounds, trailing bytes, persisted key/value limits, common-envelope identity/kind/flags
rejection, hostile U64 extent overflow, and standalone index/frame truncation, CRC, geometry, ordering, binding, and
shifted-bound cases. The three-entry golden also requires the whole-table and authenticated-index next-entry kernels
to agree on newest-value, historical-tombstone, strict/inclusive-start, and exclusive-upper outcomes. The executable
operation covers typed start rollback and finish restoration, cancellation, expired-deadline reuse,
wrong-generation provider results, a found and absent key against the actual Flush output, and generation-bound
header/index/frame execution. Its next-entry purpose covers actual v2 output,
the frozen v1 fallback, exact token restoration, and operation reuse. The composed client fixture uses three actual
published runs to select newest and two historical snapshots, reject an
invalid run order before I/O, and exhaust all runs for absence while preserving
the exact moved token. It then converts the oldest run to frozen v1 and repeats
historical-value and complete-absence selection across the mixed manifest.
Recovery covers complete local loss and an actual mixed-version manifest. The authenticated client fixture exercises
the public operation before a checkpoint through the committed suffix and after a checkpoint through the immutable
selector, plus transaction-local precedence, Serializable observation, exact token restoration, restart, and the
synchronous wait. Broad provider qualification of this path remains a later campaign; the maintained authenticated
client fixture is the current provider seam.
