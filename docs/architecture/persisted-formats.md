# Persisted formats

This document is normative for HEAD versions 1 and 2 and the independent version-1 commit-batch and
column-family-manifest encodings. Each object kind advances its own version constant: the HEAD kind accepts versions
1 and 2, batch accepts version 1, manifest accepts versions 1 through 3, and operational recovery accepts SST version
1. The private operational codec also freezes additive SST version 2 without activating it. All multibyte integers
are unsigned big-endian.
Byte strings are length-prefixed and contain arbitrary bytes. No Ada record image or enumeration position is
persisted.

The first-LSM format unit freezes current manifest version 3, readable predecessor version 2, and operational SST
version 1 below. Its private generic codec remains the bounded reference/proof implementation. A byte-identical
operational codec admits headers before whole-object allocation and retains exact dynamically sized run, identity,
entry, key, and value extents. The private SST-v2 whole-object codec extends that operational boundary without
selecting it for publication or recovery. See [`lsm-checkpoint-publication.md`](lsm-checkpoint-publication.md).

## Common envelope

Every object begins with:

| Field | Bytes | Rule |
| --- | ---: | --- |
| magic | 8 | Object-kind-specific ASCII constant |
| format version | 2 | Kind-specific supported version; unknown versions fail closed |
| object kind | 1 | Explicit stable code |
| flags | 1 | Unknown set bits fail closed |
| database UUID | 16 | Must equal the opened database |
| header length | 4 | Exact bytes through the kind-specific header |
| payload length | 8 | Must fit the complete object extent |
| header checksum | 4 | CRC-32C over the header with this field zeroed |

An object ends with a CRC-32C over every preceding byte. Decoders reject truncation, trailing bytes, arithmetic
overflow, unknown kind/version/flags, wrong UUID, and either checksum mismatch.

## Database head

`meta/HEAD` uses magic `FLYHEAD1` and contains writer epoch, highest visible sequence, latest commit object ID,
latest manifest ID, transition ID, predecessor transition ID, and a monotonic transition ordinal. IDs are fixed
16-byte opaque values; all-zero denotes the absent optional reference only where the field explicitly permits it.
The exact transition identity is `(ordinal, ID)`. Both initial HEAD shapes have ordinal one, sequence zero, no commit,
a nonzero transition ID, and an all-zero predecessor. Version 1 requires an all-zero manifest ID; version 2 requires
the nonzero root-manifest ID published before HEAD. Every later head has a nonzero predecessor and increments the
ordinal exactly once. Before the first commit, the ordinal equals the writer epoch; after a commit it is strictly
greater, rejecting states that cannot be reached by acquisition and commit transitions for that HEAD version.

A valid successor preserves the database UUID and version, increases the writer epoch only through writer
acquisition, never decreases sequence, names the prior transition ID as predecessor, advances the transition ordinal,
and has a nonzero transition ID different from its immediate predecessor. A commit transition keeps the writer epoch,
advances sequence by the exact batch transaction count, and names the published batch.

HEAD version 1 retains an all-zero latest-manifest field and remains decodable for inspection. Operational Open
returns `Unsupported_Format` for version 1 and never writes or upgrades it. HEAD version 2 is the current operational
shape: every valid state carries a nonzero latest-manifest ID, and writer acquisition and commit transitions preserve
that reference. Create publishes the canonical root manifest before conditionally creating HEAD v2; Open resolves the
complete referenced manifest chain before reading any batch.

Delayed create resolution always reads the immutable root-manifest object again and requires byte-for-byte equality
with the canonical receipt image before it retries or reconciles HEAD. An exact attempted HEAD or a fully validated
later manifest-and-batch chain confirms creation only when its root ancestor equals that manifest and publication
transition. A valid competing root is `Already_Exists`; missing, altered, or unvalidated acknowledged data is never
trusted from receipt bytes alone.

## Commit batch

Commit batches use magic `FLYBATC1`, kind code `2`, and a 156-byte header. The common envelope occupies bytes
0 through 43. The kind-specific fields are fixed as follows:

| Field | Offset | Bytes |
| --- | ---: | ---: |
| writer epoch | 44 | 8 |
| batch ID | 52 | 16 |
| previous batch ID | 68 | 16 |
| expected head transition ID | 84 | 16 |
| expected head transition number | 100 | 8 |
| publication transition ID | 108 | 16 |
| publication transition number | 124 | 8 |
| first sequence | 132 | 8 |
| last sequence | 140 | 8 |
| transaction count | 148 | 4 |
| mutation count | 152 | 4 |

The two transition identities are exact `(number, ID)` pairs. The expected number is nonzero and below the maximum;
the publication number is its exact successor. A first batch has expected number equal to its writer epoch. Every
later batch has expected number greater than its epoch. The first batch has an all-zero predecessor; every later batch
names the exact prior reachable batch. Each transaction frame has a 32-byte prefix: idempotency ID (16 bytes), assigned
sequence (8), mutation count (4), and exact byte length of all following mutation frames in that transaction (4). Each
mutation frame has a 14-byte prefix: stable nonzero column-family ID (4), operation code (`1` for Put or `2` for
Delete), zero flags (1), key length (4), and value length (4), followed by the exact key and value bytes. Delete has
value length zero; a Put value and every key may be empty. The final four bytes hold CRC-32C over every preceding byte.

The operational writer uses a singleton transaction ID directly as its batch ID. An explicit transaction group uses
a caller-stable nonzero group ID. Both kinds occupy one shared never-reused identity namespace. The open engine
reserves every admitted group ID and member transaction ID, including definite failures and orphans. Recovery imports
every transaction and batch ID in the reachable history and fails closed on cross-kind reuse. It cannot rediscover
member IDs belonging only to unreachable orphan batches because normal recovery deliberately does not list. After
complete local-state loss, callers therefore remain responsible for globally never reusing every admitted ID;
conditional create additionally rejects replay when the reused identity is itself the immutable orphan's batch key.
Exact-byte reconciliation is limited to the original admitted operation whose Put outcome was unknown. This is
allocation policy over the existing 16-byte wire field, not a second encoding or probabilistic hash.

Transactions and mutations are encoded in proposed commit order. Sequences are contiguous and strictly increasing;
keys and values must fit configured bounds; counts and summed lengths are checked before slicing. A decoder rejects a
batch whose internal counts, sequence interval, transaction boundaries, checksums, database ID, epoch, predecessor,
or transition IDs disagree with the head that references it. Recovery validates each predecessor ID, database
identity, sequence adjacency, and checksum before following it. Sequence decreases strictly during the backward walk,
so a valid chain cannot cycle.

The version-1 wire widths permit 32-bit counts and key/value lengths and a 64-bit payload length. The private SPARK
reference codec remains deliberately small: at most 16 transactions, 64 mutations, 64 bytes per key, 256 bytes per
value, 21,888 payload bytes, and 22,048 total bytes. These are reference/proof-instance limits, not production
backpressure or wire-format changes. Its total image admission limit is checked before copying into the bounded
representation. For an admitted image, exact extent,
magic, version, kind, flags, database identity, and both checksums are checked before declared reader caps. A
`Limit_Exceeded` result reports a declared reference-instance requirement; it does not certify transaction or mutation
structure that the reader deliberately skipped. Corruption has separate results, and every decode failure returns an
empty batch value. The operational synchronous codec validates the same v1 fields and checks each extent/count/wire
conversion before allocating dynamic descriptors and one exact immutable image. After integrity and declared-resource
admission, it rejects a transaction count greater than the mutation count or minimum transaction/mutation framing
greater than the exact payload extent as corruption, before allocation. Golden cross-checks keep its bytes aligned
with the reference codec.

A latest batch is visible only when the live head has the same database and writer epoch, names the batch ID, ends at
the batch's last sequence, and carries its exact expected/publication transition identities. Historical predecessor
batches decode structurally without requiring historical HEAD objects. Recovery then checks database identity, exact
batch-ID linkage, sequence adjacency, nondecreasing epoch, and ordinal continuity. The next expected number is at least
the predecessor publication number, and the epoch delta cannot exceed that ordinal gap. A zero gap is a direct edge
and requires equal transition IDs. A gap of one is the immediate successor transition and must use a different ID. A
gap of two or more permits intervening metadata or writer-acquisition HEAD transitions and does not constrain IDs,
because a historical opaque ID may recur after another transition.

## Column-family manifest

Column-family manifests use magic `FLYCFM01`, kind code `3`, and a 196-byte header. The common envelope occupies
bytes 0 through 43. Version 1 freezes these kind-specific fields:

| Field | Offset | Bytes |
| --- | ---: | ---: |
| manifest ID | 44 | 16 |
| previous manifest ID | 60 | 16 |
| expected HEAD transition ID | 76 | 16 |
| expected HEAD transition number | 92 | 8 |
| publication transition ID | 100 | 16 |
| publication transition number | 116 | 8 |
| writer epoch | 124 | 8 |
| registry revision | 132 | 8 |
| family count | 140 | 4 |
| maximum column families | 144 | 4 |
| maximum manifest history | 148 | 4 |
| maximum batch history | 152 | 4 |
| maximum transactions per batch | 156 | 4 |
| maximum mutations per transaction | 160 | 4 |
| maximum mutations per batch | 164 | 4 |
| maximum live entries | 168 | 4 |
| maximum logical transaction payload bytes | 172 | 8 |
| maximum logical batch payload bytes | 180 | 8 |
| maximum logical live-state bytes | 188 | 8 |

Every family frame starts with an exact 28-byte prefix: nonzero numeric family ID (4), zero flags (4), maximum key
bytes (8), maximum value bytes (8), UTF-8 name length (2), and zero reserved bits (2), followed by the exact name
bytes. IDs are strictly increasing and never reused. Names are unique by exact UTF-8 byte sequence, contain one to
255 bytes, and reject NUL, overlong encodings, surrogates, and code points above U+10FFFF. No Unicode normalization
is implied: canonically equivalent byte sequences are distinct names. The bounded Ada record representation is
canonical: every fixed-array byte after `Name_Length` is zero. Unused family slots remain outside the persisted
registry and are ignored.

`Max_Key_Bytes` and `Max_Value_Bytes` are nonzero per-family semantic authorities. The manifest-level transaction
and batch payload budgets count logical key bytes plus Put-value bytes, not wire framing. A family key/value pair
must fit both the transaction logical-payload budget and live-state byte budget. The codec does not prescribe a
4 KiB/1 MiB default; `Create` and `Add_Column_Family` persist only caller-supplied family authority. The format
ceiling permits 16
transactions per batch, while the current log-only runtime admits at most eight. Count and logical-byte budgets are
persisted configuration, not native allocation sizes. A valid configuration cannot admit more transactions per
batch than total mutations per batch, because every transaction in a batch contains at least one mutation.

A root manifest has revision one, epoch one, no predecessor or expected HEAD identity, and publication transition
number one. A successor has revision `previous + 1`, appends exactly one higher family ID without changing any prior
family or database limit, and carries exact expected/publication HEAD identities whose ordinals differ by one. An
ordinal gap from the predecessor manifest permits intervening metadata or writer-acquisition HEAD transitions under
the same recurrence and epoch-gap rules as commit batches.

A checkpoint-manifest carrier may use either of two existing base-manifest transitions: preserve the complete exact
registry while changing checkpoint/run authority, or append exactly one higher-ID family while carrying the current
checkpoint boundary forward. The latter is the dynamic-family bridge after compaction; it does not permit rename,
drop, ID reuse, reordering, limit changes, or modification of an earlier family record. Cacheless recovery selects
the carrier-aware predicate from the decoded object version rather than assuming every manifest-v3 object changes
only runs.

`Valid_Root_Publication` describes the initial manifest-bearing HEAD version 2. Three-way
`Valid_Publication(Current, Candidate, Manifest)` additionally requires exact current expected identity, candidate
publication identity, one ordinal step, and preservation of database, epoch, highest sequence, and latest batch.
`Referenced_By` is deliberately narrower: it establishes that a current or later HEAD still names one decoded
manifest for recovery; it is not evidence that the exact publication transition was valid. An exact publication
HEAD binds its predecessor to the manifest's expected transition ID (zero for the root); an immediate successor
binds its predecessor to the manifest's publication transition ID. A gap of two or more retains only the documented
ordinal/epoch reachability rule because intervening transitions are not available from the current HEAD alone.

The private bounded codec instance accepts at most 64 families and 255 name bytes, so the largest image is exactly
`196 + 64 * (28 + 255) + 4 = 18,312` bytes including the final whole-object CRC-32C. These are implementation/proof
resource ceilings, not narrower wire widths or family key/value policy. Reader key/value ceilings default to unsigned
64-bit maximum and are compared without converting to `Natural`. Total representation admission rejects an image
larger than 18,312 bytes before copying or inspecting its envelope or integrity fields. For an admitted image, exact
extent, magic, kind/version/flags, database identity, and checksums precede declared reader-cap classification.
`Limit_Exceeded` therefore remains distinct from corruption but does not certify the skipped family structure. Every
other decode failure also returns an empty value.

This is the initial manifest encoding and has no prior manifest migration obligation. Operational HEAD v2 names the
latest manifest as recovery authority. Mutation/live counts are persisted U32 resource authority; the values 64 and
4,096 remain reference-campaign sizes rather than production semantic ceilings. Key/value and aggregate byte budgets
remain persisted U64 authority. The synchronous owned runtime lazily checks and allocates each actual arena/image;
reachable history longer than its own persisted cap is `Corrupt`, while an unrepresentable or failed local allocation
is `Capacity_Exceeded` and Open remains closed. A future composable provider path may additionally use `Unique_Buffer`
while sharing these format and publication predicates.

### Checkpoint manifest version 2

Manifest version 2 retains magic `FLYCFM01`, kind code `3`, every version-1 field at the same offset, and every
version-1 registry and database limit. Its header is 220 bytes. The 24-byte extension is:

| Field | Offset | Bytes |
| --- | ---: | ---: |
| replay boundary | 196 | 8 |
| maximum total L0 runs | 204 | 4 |
| maximum checkpoint identities | 208 | 4 |
| admitted identity count | 212 | 4 |
| reserved, zero | 216 | 4 |

Each family payload frame retains the version-1 fields at offsets 0 through 27 relative to its start and extends its
fixed prefix to 52 bytes:

| Field | Relative offset | Bytes |
| --- | ---: | ---: |
| family ID | 0 | 4 |
| flags, zero | 4 | 4 |
| maximum key bytes | 8 | 8 |
| maximum value bytes | 16 | 8 |
| UTF-8 name length | 24 | 2 |
| reserved, zero | 26 | 2 |
| memtable maximum logical bytes | 28 | 8 |
| memtable maximum entries | 36 | 4 |
| maximum L0 runs | 40 | 4 |
| current L0 run count | 44 | 4 |
| reserved, zero | 48 | 4 |

The exact family-name bytes follow this prefix. They are followed by `current L0 run count` fixed 48-byte run
descriptors:

| Field | Relative offset | Bytes |
| --- | ---: | ---: |
| run ID | 0 | 16 |
| lowest sequence | 16 | 8 |
| highest sequence | 24 | 8 |
| entry count | 32 | 4 |
| reserved, zero | 36 | 4 |
| logical key plus Put-value bytes | 40 | 8 |

After every family frame and its descriptors, the payload ends with `admitted identity count` exact 16-byte opaque
identities. The identities are nonzero and strictly increasing by unsigned bytewise order. Sorting makes the same
authority set encode to one canonical byte image; no ordering meaning is assigned to the identities.

All new configured limits are nonzero persisted authority. The codec supplies no default. Each current family run
count must fit its persisted family limit, the sum must fit the persisted database run limit, and the identity count
must fit the persisted database identity limit. A run is nonempty, has a nonzero ID and positive ordered sequence
interval, and cannot extend beyond the replay boundary. Run IDs are unique across every family. Within a family,
descriptors are ordered by nonoverlapping sequence interval. A zero replay boundary permits no runs and no admitted
identities. The format does not infer the exact identity ledger from visible keys.

The private SPARK reference codec is generic over run, identity, SST-entry, key, and value representation capacities.
Those instantiation values are proof/test storage choices, not wire limits, database defaults, or operational
backpressure. An admitted image validates exact extent, envelope, database identity, and both checksums before reader
caps. A representation or declared reader-cap excess is `Limit_Exceeded`; malformed frames and noncanonical mapping
fail closed and return an empty manifest value.

The operational manifest decoder first validates exactly the 220-byte header against the transport-reported object
length. Its allocation upper bound is derived with checked arithmetic from the authenticated family count, persisted
database run ceiling, actual identity count, maximum family-name width, and frozen frame widths. A generation-bound
whole read then validates the object CRC and every frame without allocation, allocates one exact flat family/run/
identity object, populates it, and revalidates the complete structure before returning ownership. Storage exhaustion
is `Allocation_Failed`; an address-space-incompatible persisted base is `Runtime_Incompatible`; every failure returns
a null access value. The persisted theoretical maxima are not eagerly allocated and do not create replacement limits.

### Checkpoint manifest version 3

Manifest version 3 retains the complete version-2 header and payload unchanged, extends the authenticated header to
228 bytes, and appends two database-wide U32 fields:

| Field | Offset | Bytes |
| --- | ---: | ---: |
| maximum point reads per transaction | 220 | 4 |
| maximum scan ranges per transaction | 224 | 4 |

Both values are nonzero caller-selected persisted authority. They independently bound the exact point observations
and normalized scan ranges retained by a serializable transaction. They do not bound key or endpoint bytes: the
selected column family's persisted maximum key length remains that allocation authority. Reaching either count is
typed backpressure and cannot silently omit an observation or partially publish transaction state.

New Create operations emit version 3. Version 2 remains readable for snapshot operation and reports both new fields
as zero, which is an explicit absence of serializable tracking authority rather than a fallback. There is no
in-place upgrade and no library-selected replacement value. A serializable Begin against such a database must reject
as unsupported until a separately specified immutable migration publishes explicit authority. Flush likewise
rejects a v2 root as unsupported rather than silently choosing limits while creating a v3 successor.

The operational decoder probes up to the current 228-byte prefix, selects the exact 220- or 228-byte header from the
authenticated version, and derives whole-object allocation bounds from that selected width and authenticated counts.
The bounded SPARK reference codec encodes and decodes only current version 3; the operational decoder owns the exact
version-2 backward-read golden. Every new allocation remains checked, lazy, and unpublished on failure.

## Immutable SST run version 1

SST version 1 uses magic `FLYSST01` and the next unused stable object-kind code, `4`. Its header is 96 bytes:

| Field | Offset | Bytes |
| --- | ---: | ---: |
| common envelope | 0 | 44 |
| run ID | 44 | 16 |
| family ID | 60 | 4 |
| lowest sequence | 64 | 8 |
| highest sequence | 72 | 8 |
| entry count | 80 | 4 |
| reserved, zero | 84 | 4 |
| logical key plus Put-value bytes | 88 | 8 |

Every entry begins with a 20-byte prefix: sequence (8), operation (`1` Put or `2` Delete), zero flags (1), zero
reserved bits (2), key length (4), and value length (4), followed by exact key and value bytes. Delete requires zero
value length. Empty keys and empty Put values remain legal, matching commit batches. Unused bytes in the bounded
reference record are zero and are not persisted.

Entries are ordered by arbitrary key bytes ascending; entries for the same key are ordered by sequence descending.
An exact duplicate `(key, sequence)` is invalid. Every sequence lies in the positive inclusive header interval, and
the header endpoints equal the actual minimum and maximum entry sequences. The header logical byte total equals the
sum of every key plus every Put value; Delete contributes its key only. The run ID and family ID are nonzero.

Recovery accepts an SST for one manifest family only when database ID, family ID, run ID, sequence interval, entry
count, and logical byte total exactly match the manifest mapping and descriptor. Envelope integrity, exact extent,
and both checksums precede reader caps. Any corruption or noncanonical ordering returns an empty SST value; exceeding
the generic reference representation or explicit reader cap is `Limit_Exceeded` and does not authenticate skipped
entries.

The operational SST header admission requires the exact manifest descriptor. Entry count, logical payload bytes,
and frozen widths therefore determine the one admissible whole-object length before allocation. After a
generation-bound whole read, a first pass checks CRC, every U32-to-host conversion, per-family persisted key/value
limits, frame extents, sequence interval, ordering, and exact logical payload. Only then does the decoder allocate one
object containing the actual entry descriptors and compact key/value bytes. A second structural check precedes
ownership return; all failures leave the result null. The operational and bounded encoders are gated against the same
independently generated golden bytes.

## Immutable SST run version 2 codec

SST version 2 retains magic `FLYSST01`, object-kind code `4`, the common envelope, and every v1 descriptor and
ordering rule. It extends the authenticated header from 96 to 128 bytes:

| Field | Offset | Bytes |
| --- | ---: | ---: |
| version-1 header prefix | 0 | 96 |
| frame-region offset | 96 | 8 |
| frame-region extent | 104 | 8 |
| index-region offset | 112 | 8 |
| index-region extent | 120 | 8 |

The frame region starts at byte 128. Each entry frame consists of the existing 20-byte entry prefix, exact key and
value bytes, and a four-byte CRC32C over the prefix and payload. Consequently, the exact frame-region extent is
`entry_count * 24 + logical_payload_bytes`; checked arithmetic must establish that formula before allocation or
publication.

The index follows the frame region without padding. Each canonical index record contains frame offset (8), frame
extent (8), sequence (8), operation (1), zero flags (1), zero reserved bits (2), key length (4), value length (4),
and the exact key bytes. A final four-byte CRC32C authenticates the complete index before any record is trusted.
The object retains its final whole-object CRC32C for complete reads and offline validation.

The decoder authenticates the common envelope and v2 header before deriving exact extents. It then authenticates
the index CRC before parsing index records, authenticates every frame CRC, and requires each frame's offset, extent,
sequence, operation, lengths, and key to match its index record exactly. Canonical key/sequence ordering, descriptor
identity, persisted database and family limits, sequence endpoints, and logical-byte totals remain mandatory. Any
failure returns no SST; allocation occurs lazily only after checked geometry and validation and publishes no partial
state.

The private operational codec is gated by an independently generated 323-byte golden image, shifted-lower-bound
decoding, every truncation, trailing bytes, whole/index/frame checksum corruption, repaired-checksum index/frame
mismatch, intact-frame substitution, malformed extents, unsupported version, and persisted key/value-limit
rejection, common-envelope identity/kind/flags rejection, and hostile U64 extent overflow. This freezes the v2 wire
representation without activating it for durable writes. The operational writer, manifest recovery, and compaction
output remain v1 until a later focused change adds generation-bound range reads, mixed-version recovery,
complete-loss recovery, and provider qualification.

## Evolution

Batch version 1 remains the transaction-log encoding. Manifest version 1 is the legacy log-only registry encoding and
remains readable. Manifest version 2 remains readable as the first-LSM predecessor but has no serializable
observation authority. New databases use manifest version 3 from their root: the root has replay boundary zero, no
runs, and no checkpoint identities, while persisting every explicit LSM and serializable-tracking limit. A nonempty
current manifest is a later checkpoint successor and never rewrites or implicitly migrates a reachable older
manifest. SST begins at version 1 under its independent kind. The private version-2 codec is additive but is not yet
selected by the writer or recovery path. Activating it requires an explicit compatibility change rather than an
implicit rewrite of reachable v1 runs. Golden byte fixtures and explicit corruption cases gate each supported
version. Migration never rewrites a reachable immutable object in place.
