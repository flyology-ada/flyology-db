# Opaque batch ETag ceiling: build-only, no timing result

This is an isolated diagnostic of a potentially large Files batch-PUT CPU cost,
not a production change or an accepted DB performance improvement. The
retained natural-window profile found 1,184 of 1,267 named/unknown batch CPU
samples in `GNAT.MD5.Transform`; its 25.33 ms batch-PUT span overlaps the
38.16 ms transaction window and is **not** itself removable wall time. The
experiment is worth screening against the 10% floor, but no speedup is proved.

The experiment changes only the private batch PUT request to supply an opaque
key-derived ETag and applies the Object Storage author's conditional MD5 guard
in an isolated indexed Files source copy. It leaves batch payload bytes,
create-if-absent, file synchronization/rename, and conditional HEAD publication
unchanged. It does change the Files batch object's opaque ETag metadata; this
is not an exact provider-metadata-identity comparison and must not be promoted
without a separate contract/compatibility and recovery review. The published
DB API and pinned production dependency are untouched.

On the retained x86 `i4i.xlarge`, both sides were copied from the same
owned-copy candidate and force-built serially with `gprbuild -aP` pointing at
each owning source root. The first candidate build lacked an explicit source
map and is rejected as evidence. The corrected `gprls` inventory selects the
patched root DB body and patched indexed Files body. Terminal receipts are
zero, the diagnostics inventories are byte-identical (26 established lines),
and the SlateDB library is byte-identical. The baseline panel SHA-256 is
`4226f2149562ef803caedf8107f1332da83b1bdd9295ddd937d411e78aabf70a`;
the candidate is
`3aca5310af4b427c50a7135c5242240b7e68fe3dddb2ce7cf81c4d827a6d49f0`.
The baseline/candidate DB bodies are `1874bc5a...`/`2fdbe179...`, and the
indexed Files bodies are `dae8fd35...`/`1877168f...` respectively.

An independently reviewed B1/C1/C2/B2 screen is prepared under `input/`.
It requires equal source/project/native-library closures apart from the two
intentional source changes, exact 35 × 256 work, 16/1,024-byte keys/values,
8 warmup transactions, ten internally balanced pairs per panel, successful
reopen of 11,008 keys at state SHA-256 `090e348a...`, actual batch/HEAD counts,
and stable detectable power conditions. Linux power detection is currently
`unknown`; even a successful screen would be exploratory, not cross-arch or
power-qualified. No screen invocation has started.

The EC2 instance reports running/healthy, but SSH timed out before
authentication after the builds. Its port 22 ingress is one `/32`; a read-only
external public-IP lookup was denied by auto-review, so the current client
address was not established and the ingress was not changed. No timing,
correctness, ARM64, formal, adoption, commit, or push claim follows. Resume
only after explicitly authorized connectivity recovery and a fresh quiet-host
audit; do not reuse an observation timeout as permission to rerun a build.
