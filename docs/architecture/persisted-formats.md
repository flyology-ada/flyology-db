# Persisted formats

This document is normative for format version 1. All multibyte integers are unsigned big-endian. Byte strings are
length-prefixed and contain arbitrary bytes. No Ada record image or enumeration position is persisted.

## Common envelope

Every object begins with:

| Field | Bytes | Rule |
| --- | ---: | --- |
| magic | 8 | Object-kind-specific ASCII constant |
| format version | 2 | `1`; unknown versions fail closed |
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
The exact transition identity is `(ordinal, ID)`. The initial head has ordinal one, sequence zero, no commit or
manifest, a nonzero transition ID, and an all-zero predecessor. Every later head has a nonzero predecessor and
increments the ordinal exactly once. Before the first commit, the ordinal equals the writer epoch; after a commit it
is strictly greater, rejecting states that cannot be reached by the version-1 acquisition and commit transitions.

A valid successor preserves the database UUID and version, increases the writer epoch only through writer
acquisition, never decreases sequence, names the prior transition ID as predecessor, advances the transition ordinal,
and has a nonzero transition ID different from its immediate predecessor. A commit transition keeps the writer epoch,
advances sequence by the exact batch transaction count, and names the published batch.

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

The version-1 wire widths permit 32-bit counts and lengths and a 64-bit payload length. The initial private Ada reader
is deliberately narrower: at most 16 transactions, 64 mutations, 64 bytes per key, 256 bytes per value, 21,888
payload bytes, and 22,048 total bytes. These are operational backpressure limits, not wire-format changes. The total
image admission limit is checked before copying into the bounded representation. For an admitted image, exact extent,
magic, version, kind, flags, database identity, and both checksums are checked before declared reader caps. A
`Limit_Exceeded` result reports a declared resource requirement; it does not certify transaction or mutation structure
that the reader deliberately skipped. Corruption has separate results, and every decode failure returns an empty batch
value. Raising these caps later does not require a format-version change, but does require renewed memory-budget,
test, and proof evidence.

A latest batch is visible only when the live head has the same database and writer epoch, names the batch ID, ends at
the batch's last sequence, and carries its exact expected/publication transition identities. Historical predecessor
batches decode structurally without requiring historical HEAD objects. Recovery then checks database identity, exact
batch-ID linkage, sequence adjacency, nondecreasing epoch, and ordinal continuity. The next expected number is at least
the predecessor publication number, and the epoch delta cannot exceed that ordinal gap. A zero gap is a direct edge
and requires equal transition IDs. A gap of one is the immediate successor transition and must use a different ID. A
gap of two or more permits intervening metadata or writer-acquisition HEAD transitions and does not constrain IDs,
because a historical opaque ID may recur after another transition.

## Evolution

This is the initial Flyology.DB commit-batch encoding. No earlier batch encoding was released or persisted, so version
1 has no legacy migration obligation. A future format change records whether existing readers reject, read, or migrate
it. Golden byte fixtures and explicit corruption cases gate each supported version. Migration never rewrites a
reachable immutable object in place.
