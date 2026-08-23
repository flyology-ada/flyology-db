# Persisted formats

This document is normative for HEAD versions 1 and 2 and the independent version-1 commit-batch and
column-family-manifest encodings. Each object kind advances its own version constant: the HEAD kind accepts versions
1 and 2, while batch and manifest currently accept only version 1. All multibyte integers are unsigned big-endian.
Byte strings are length-prefixed and contain arbitrary bytes. No Ada record image or enumeration position is
persisted.

The staged first-LSM design chooses a future manifest object version 2 and a new SST object kind, but freezes no byte
layout here and does not make either version operational. See
[`lsm-checkpoint-publication.md`](lsm-checkpoint-publication.md). The kind-specific supported versions in this
document remain unchanged until the separate persisted-format unit supplies exact offsets, golden bytes, corruption
tests, and decoder proof.

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
4 KiB/1 MiB default; that policy belongs to the later public family-creation API. The format ceiling permits 16
transactions per batch, while the current log-only runtime admits at most eight. Count and logical-byte budgets are
persisted configuration, not native allocation sizes. A valid configuration cannot admit more transactions per
batch than total mutations per batch, because every transaction in a batch contains at least one mutation.

A root manifest has revision one, epoch one, no predecessor or expected HEAD identity, and publication transition
number one. A successor has revision `previous + 1`, appends exactly one higher family ID without changing any prior
family or database limit, and carries exact expected/publication HEAD identities whose ordinals differ by one. An
ordinal gap from the predecessor manifest permits intervening metadata or writer-acquisition HEAD transitions under
the same recurrence and epoch-gap rules as commit batches.

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

## Evolution

These are the initial Flyology.DB batch and manifest encodings. No earlier encoding was released or persisted, so
version 1 has no legacy migration obligation. A future kind-specific format change records whether existing readers
reject, read, or migrate it. Golden byte fixtures and explicit corruption cases gate each supported version.
Migration never rewrites a reachable immutable object in place.
