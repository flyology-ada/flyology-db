# Generation-bound lazy SST reads

The private LSM storage slice makes immutable SST-v2 runs range-readable without weakening persisted integrity or
silently adding storage I/O to the established public `Get`, `Scan`, and `Next_Scan_Page` contracts. SST version 1
remains readable through its generation-bound whole-object decoder. New Flush and compaction outputs use additive
SST version 2, whose exact entry frames can be authenticated independently after one authority observation, one
header range, and one index range.

This is a format and certainty mechanism, not an automatic cache, block-size, prefetch, timeout, retry, or
compaction-selection policy. The private caller-driven operation supplies explicit deadline, cancellation, moved
buffer ownership, and completion-set authority. Existing public APIs that promise no storage I/O remain unchanged
until a later public execution decision composes this mechanism into them.

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
and documented adjacent to their declarations and in `persisted-formats.md`. Durable run publication and private
range-read execution are active; no public lazy-read overload is exposed.

The private range-local codec consumes the exact index and frame slices described below. Index decoding
authenticates the complete index CRC before parsing any record, validates canonical contiguous frame geometry and key
ordering, and retains exact descriptor/key authority in one lazily allocated value. Frame decoding accepts one exact
index-selected extent, authenticates its CRC, and binds sequence, operation, lengths, and every key byte before
allocating output. These routines perform no Object Storage call and therefore do not themselves establish that the
slices came from one provider generation; the private caller-driven operation establishes that authority.

## Range-read protocol

1. Use `Head_Object` to observe the exact object extent and opaque provider generation without retaining a body.
2. Read the exact v2 header range with `Expected_Entity_Tag` equal to that observed generation. A replacement between
   HEAD and this range read therefore rejects before a candidate header exists.
3. Validate magic, version, kind, database/run/family identity, object length, sequence interval, entry count, logical
   bytes, checked frame/index extents, and header CRC before allocating variable storage. The object length in the
   header must equal the authoritative HEAD extent.
4. Read the exact index range with the same `Expected_Entity_Tag`. Validate its exact
   range, length, canonical records, ordering, bounds, uniqueness, and index CRC before publication.
5. Select an entry from that authenticated index. Read exactly its frame with the same required generation.
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

The formal geometry is not a format bound, cache size, request count, retry budget, or public default. The model does
not prove CRC arithmetic, byte offsets, range arithmetic, the Ada codec, provider behavior, progress, concurrency,
or refinement. The private whole-object codec covers independent v1/v2 goldens, v1 compatibility, every v2
object truncation, exact extent checks, whole/index/frame CRCs, repaired-checksum index/frame binding, intact-frame
substitution, shifted lower bounds, trailing bytes, persisted key/value limits, common-envelope identity/kind/flags
rejection, hostile U64 extent overflow, and standalone index/frame truncation, CRC, geometry, ordering, binding, and
shifted-bound cases. The executable operation covers typed start rollback and finish restoration, cancellation,
wrong-generation provider results, a found and absent key against the actual Flush output, and generation-bound
header/index/frame execution. Recovery covers complete local loss and an actual mixed-version manifest. Broad
provider qualification of this private path remains a later campaign; the maintained authenticated client fixture
is the current provider seam.
