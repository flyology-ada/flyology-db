# Canonical logical-state digest

Oracle adapters compare logical live state independently of engine formats, tombstones, manifests, and caches. The
version-1 digest is SHA-256 over the following exact byte stream:

1. ASCII `flyology.db.oracle.state.v1` followed by one NUL byte.
2. Live tuples sorted by numeric column-family ID and then by unsigned lexicographic key bytes.
3. For each tuple, its canonical UTF-8 decimal family ID, key bytes, and value bytes, in that order. Each field is
   preceded by its byte length as one unsigned 64-bit big-endian integer.

Family IDs are canonical nonzero decimal `u32` values: no sign, whitespace, or leading zero is accepted. Keys and
values are arbitrary bytes. Empty values are encoded with a zero length; absent/tombstoned keys do not appear.
Adapters must bound materialization and response projection separately from this encoding.

[`canonical_state_vectors.json`](canonical_state_vectors.json) is the machine-readable golden corpus. Its
`input_order` vector deliberately preserves a noncanonical tuple sequence to test that the hash function is order
sensitive. Its `canonical` vectors are already sorted and test the state projection used for comparisons.
[`canonical_state.py`](canonical_state.py) is the shared executable reference and vector validator.
