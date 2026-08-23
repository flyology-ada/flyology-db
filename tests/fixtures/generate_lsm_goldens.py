#!/usr/bin/env python3
"""Generate the independent checkpoint-manifest-v2 and SST-v1 goldens.

This script deliberately does not import or invoke the Ada codec. The small
fixture counts and byte strings exercise ordering, tombstones, empty values,
run binding, and identity-ledger encoding; they are not database defaults.
"""

import struct


def crc32c(data: bytes) -> int:
    # Reflected Castagnoli polynomial and all-ones initial/final XOR are the
    # repository CRC-32C wire contract; changing either invalidates all objects.
    result = 0xFFFF_FFFF
    for octet in data:
        result ^= octet
        for _ in range(8):
            result = (result >> 1) ^ (0x82F6_3B78 if result & 1 else 0)
    return (~result) & 0xFFFF_FFFF


def identifier(last: int) -> bytes:
    # Inherited identifier wire width is exactly 16 bytes; this fixture helper
    # varies only the final byte to create visibly ordered, nonzero test IDs.
    return bytes(15) + bytes([last])


def envelope(magic: bytes, version: int, kind: int, database_id: bytes, header: bytes, payload: bytes) -> bytes:
    # Common frozen field layout: >HBB is version/kind/zero flags and >IQI is
    # header length/payload length/zeroed header CRC, all unsigned big-endian;
    # 44 = 8 + 2 + 1 + 1 + 16 + 4 + 8 + 4 exact common-envelope bytes.
    header_length = 44 + len(header)
    common = magic + struct.pack(">HBB", version, kind, 0) + database_id
    common += struct.pack(">IQI", header_length, len(payload), 0)
    complete_header = bytearray(common + header)
    complete_header[40:44] = struct.pack(">I", crc32c(complete_header))
    without_trailer = bytes(complete_header) + payload
    return without_trailer + struct.pack(">I", crc32c(without_trailer))


# Frozen fixture identity shared by both objects so the Ada tests exercise the
# common-envelope database binding. It is test/reference data, not an ID policy.
database_id = identifier(1)

# The base fields reuse the maintained manifest-v1 reference fixture: a valid
# successor registry with one family and explicit persisted limits. Changing
# these values intentionally changes the compatibility golden below.
base_manifest_header = b"".join(
    [
        identifier(7),
        identifier(3),
        identifier(4),
        struct.pack(">Q", 2),
        identifier(8),
        struct.pack(">Q", 3),
        struct.pack(">Q", 1),
        struct.pack(">Q", 2),
        struct.pack(">I", 1),
        struct.pack(">7I", 64, 64, 64, 8, 64, 64, 256),
        struct.pack(">3Q", 2 * 1024 * 1024, 16 * 1024 * 1024, 64 * 1024 * 1024),
    ]
)
# Manifest-v2 coverage values: replay through sequence 2, two available run
# slots, four identity slots, two present identities, and the mandated zero
# reserved word. These are test/reference capacities, not DB defaults.
checkpoint_header = base_manifest_header + struct.pack(">Q4I", 2, 2, 4, 2, 0)
assert len(checkpoint_header) == 220 - 44

# One family/run frame exercises every persisted v2 field. The 8-byte key/value
# bounds and 4096/16 memtable values are fixture dimensions only; changing them
# requires regenerating both goldens and reviewing their expected semantics.
family_header = struct.pack(">IIQQHHQIIII", 1, 0, 8, 8, 2, 0, 4096, 16, 2, 1, 0)
assert len(family_header) == 52
run_descriptor = identifier(9) + struct.pack(">QQIIQ", 1, 2, 3, 0, 4)
assert len(run_descriptor) == 48
# Ledger IDs 10/11 are strictly increasing, nonzero fixture authority through
# replay boundary 2; changing them changes the manifest compatibility image.
manifest_payload = family_header + b"cf" + run_descriptor + identifier(10) + identifier(11)
# Persisted manifest-v2 authority retains FLYCFM01 and kind 3 while advancing
# only its independent version to 2; changing these bytes is incompatible.
manifest = envelope(b"FLYCFM01", 2, 3, database_id, checkpoint_header, manifest_payload)
assert len(manifest) == 358

# The SST header must exactly match the manifest descriptor: family 1,
# sequences 1..2, three entries, zero reserved bits, and four logical bytes.
sst_header = identifier(9) + struct.pack(">IQQIIQ", 1, 1, 2, 3, 0, 4)
assert len(sst_header) == 96 - 44


def entry(sequence: int, operation: int, key: bytes, value: bytes = b"") -> bytes:
    # Frozen SST-v1 entry prefix: U64 sequence, U8 operation, zero U8 flags,
    # zero U16 reserved, then U32 key/value lengths, all unsigned big-endian.
    return struct.pack(">QBBHII", sequence, operation, 0, 0, len(key), len(value)) + key + value


# Ordered fixture entries cover same-key descending sequence, a tombstone, and
# a second key. Operation tags 1/2 are the frozen batch-v1 Put/Delete contract.
sst_payload = entry(2, 1, b"a", b"x") + entry(1, 2, b"a") + entry(2, 1, b"b")
# Persisted SST-v1 authority assigns FLYSST01, version 1, and next-unused kind 4;
# changing any value requires a new format decision and golden set.
sst = envelope(b"FLYSST01", 1, 4, database_id, sst_header, sst_payload)
assert len(sst) == 164

print("MANIFEST_HEX=" + manifest.hex().upper())
print("SST_HEX=" + sst.hex().upper())
