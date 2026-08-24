# Dependency provenance

## Current development campaign

- Dependency: `flyology_object_storage`
- Source: clean local clone `.deps/flyology-object-storage`
- Author checkout origin: `../flyology-object-storage` (observed read-only)
- Commit: `a632cc4b0bd4687e02b09cff7923ab4f9fccbfcf`
- Commit subject: `Problem: ListObjectsV2 cannot participate in composed discovery`
- Pin: root `alire.toml` filesystem path pin
- Transitive HTTP/QUIC solve: indexed, unpinned `flyology_http=0.1.3-dev` and
  `flyology_quic=0.1.3-dev`, both from immutable source commit
  `a65f24f473bd771356a4fcb355fc10f961202534`
- Observed: 2026-08-24, America/Vancouver

The dependency is local-only. Before a deterministic campaign, update the clean clone by fast-forward from its local
origin, verify it is clean, and replace this record with the exact commit used. Do not update it during a running
test, proof, or benchmark campaign.

Flyology.DB names `Flyology.Cancellation` and the native task model directly, so its root manifest declares
`flyology` directly instead of relying on transitive visibility. This campaign resolves indexed Flyology 0.1.1 plus
the exact unpinned indexed Flyology.HTTP/QUIC revisions above. The root constraint
`gnat = ">=13 & <=16.1.0"` records the qualified compiler boundary; dependency/toolchain upgrades must widen it
deliberately after the Flyology runtime preparer and this repository's gates qualify the newer compiler.

The dependency includes the reviewed backend-neutral conditional publication contract, synchronous conditional Put
and whole Get operations, caller-owned `Client.Scoped` complete and conditional Put plus generation-bound whole/range
Get, Head, Delete, CreateMultipartUpload, UploadPart preparation, CompleteMultipartUpload, and AbortMultipartUpload
operations, bounded ListParts recovery reads, bounded ListMultipartUploads discovery reads, CopyObject, retained
SQLite generations across ordinary and multipart publication, composable DeleteObjects, and generation-aware object
mutation/read coverage. The buffer-owned synchronous calls are waits over those same scoped state machines. Both
multipart listing operations own
their prepared request, retain response bytes only to the XML decoder's maintained document bound, validate the
successful response's exact request echoes including Requester Pays admission, and preserve typed HTTP terminal
failure and admission certainty.
ListMultipartUploads additionally binds the paired key/upload cursor while documenting that separate pages do not
share a service snapshot. Multipart completion
owns its exact serialized XML and classifies every complete rejection or post-admission failure as unknown until
destination and exact-upload read-only reconciliation. Multipart abort likewise treats only validated HTTP 204 as
definite success and requires exact-upload read-only reconciliation for every complete rejection or post-admission
failure. Neither path replays, spawns a helper, or retains borrowed input. Flyology.DB composes conditional Put and
whole Get directly for its additive `Flush_Operation`, preserving the synchronous receipt and certainty mapping.
CopyObject likewise uses one empty non-replayable source and a bounded XML sink. Only exact validated success is
published; precondition failure is typed, while any possibly admitted transport, response-limit, decoding, or
embedded-error ambiguity remains unknown and requires generation-bound destination reconciliation before retry.
DeleteObjects owns its exact serialized one-shot request and retains every per-entry Deleted/Error result only after a
validated HTTP 200 response. Definite non-admission is typed; any admitted or inconclusive failure remains
`Batch_Outcome_Unknown` and requires per-generation read-only reconciliation before retry. Its synchronous overload
is a literal wait on the same scoped state machine, with no helper task, replay, or alternate protocol engine.
General complete PutObject accepts the full modeled non-body parameter record and moves one acquired payload token
only after validation and signing. Typed `Finish` restores that exact token; the buffer-owned synchronous overload is
a literal wait on the same operation. Successful checksum and RequestCharged fields are bound to the exact prepared
request, and every possibly admitted exchange failure retains conservative publication certainty. The established
borrowed-source overload remains direct, one-shot, and non-rewindable. No form retries, retains borrowed input, or
creates a helper task.
Bounded ListObjectsV2 likewise owns its prepared request facts and response bytes, retains no caller borrow, and
supports operation reuse only after typed `Finish`. Successful pages are bound to the exact requested bucket scope,
prefix, delimiter, maximum, continuation/start cursor, encoding, and Requester Pays admission. Its synchronous typed
overload is a literal wait on that same state machine; separate pages remain independent service snapshots, and no
form retries or creates a helper task.
Object Storage records no external HTTP/QUIC pin at this boundary; the generated DB solve likewise marks every
HTTP/QUIC lock entry unpinned.

The dependency's retained proof report at its qualified final base proves 936/936 checks: 180 flow and 756 prover,
with zero warnings, unproved or justified checks, or `Assume` statements. Flyology.DB reruns its own repository,
format, crash/recovery, oracle, and proof gates against the exact pin above rather than treating upstream evidence as
a substitute.

## Comparative oracle sources

- SlateDB: detached clean checkout `.deps/slatedb` at
  `e0161973d8d7ffdede7c44725729838811674e99`.
- TidesDB: detached clean checkout `.deps/tidesdb` at
  `23a67a6531bc6c0b537d3696758c7879586dcfce`.

These exact SHAs, rather than tags or workspace version strings, define the current oracle source campaign. Their
capability reports are under `docs/compatibility/`.

The SlateDB executable adapter has its own checked `Cargo.lock`. Its build gate verifies Rust 1.91.1, the exact clean
source SHA, SlateDB 0.15.0 with default features disabled, and the local-filesystem-fsync profile before emitting the
ignored `build/oracles/slatedb-adapter/provenance.json` artifact. This artifact records effective toolchain and feature
configuration for each local build; it is evidence for that build, not a portable or remote-durability claim.

TidesDB is MPL-2.0 and its source tree bundles separately licensed xxHash and inih. The adapter build consumes the
clean source pin in place and does not check in or redistribute the resulting library. Any later binary distribution
must retain those notices.

## Formal-method tools

- TLC: TLA+ Tools `v1.8.0`, release commit `9787e65`, official `tla2tools.jar` SHA-1
  `0e4cfdb976f04522d218ec62c6046bbee5098377`, SHA-256
  `eabd140a70f49eb9305a3bd3f3df944eddf87e5a90d329789085f8953a80533a`.
- TLAPS: rolling release `1.6.0-pre`, proof-manager commit `4600b24`, official arm64 macOS archive SHA-256
  `ad1cb0a047ac2b5c33d6811d5d57c5bfbad4b317cd90299fee4302514f1bebde`; extracted `tlapm` binary SHA-256
  `291db0665c3b599f5343b03c06bcfb49b48ac966c39efff8643fa730f0d296b7`.

The ignored `.deps/tla` directory contains the verified release artifacts. `scripts/check-tla.sh` verifies both
executable artifacts by SHA-256 and the TLAPS reported commit before use. TLC requires Java 11 or newer; the Java
runtime is an execution prerequisite, not a repository dependency.
