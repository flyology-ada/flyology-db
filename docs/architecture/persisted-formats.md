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

Commit batches use magic `FLYBATC1`. The header includes writer epoch, batch ID, predecessor batch ID, expected head
transition ID, publication transition ID, first and last sequence, transaction count, mutation count, and payload
length. The first batch has an all-zero predecessor; every later batch names the exact prior reachable batch. Each
transaction stores its idempotency ID, assigned sequence, mutation count, and exact mutation-frame length. Each
mutation stores a stable column-family ID, operation code (`put` or `delete`), key length, value length, then key and
value bytes. Delete has value length zero.

Transactions and mutations are encoded in proposed commit order. Sequences are contiguous and strictly increasing;
keys and values must fit configured bounds; counts and summed lengths are checked before slicing. A decoder rejects a
batch whose internal counts, sequence interval, transaction boundaries, checksums, database ID, epoch, predecessor,
or transition IDs disagree with the head that references it. Recovery validates each predecessor ID, database
identity, sequence adjacency, and checksum before following it. Sequence decreases strictly during the backward walk,
so a valid chain cannot cycle.

## Evolution

A format change records whether existing readers reject, read, or migrate it. Golden byte fixtures and explicit
corruption cases gate each supported version. Migration never rewrites a reachable immutable object in place.
