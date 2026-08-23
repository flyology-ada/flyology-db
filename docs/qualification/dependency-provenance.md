# Dependency provenance

## Current development campaign

- Dependency: `flyology_object_storage`
- Source: clean local clone `.deps/flyology-object-storage`
- Author checkout origin: `../flyology-object-storage` (observed read-only)
- Commit: `8e6e435250433c06528ead054cebf613eabbb4ba`
- Commit subject: `Expose synchronous conditional object recovery`
- Pin: root `alire.toml` filesystem path pin
- Observed: 2026-08-22, America/Vancouver

The dependency is local-only. Before a deterministic campaign, update the clean clone by fast-forward from its local
origin, verify it is clean, and replace this record with the exact commit used. Do not update it during a running
test, proof, or benchmark campaign.

Flyology.DB names `Flyology.Cancellation` and the native task model directly, so its root manifest declares
`flyology` directly instead of relying on transitive visibility. The pinned Flyology 0.1.0 implementation at commit
`8e0461080e0f110b3bf70dbff283af9ca5e53a2c` recognizes the qualified Alire GNAT toolchain through 16.1 only. The root
constraint `gnat = ">=13 & <=16.1.0"` records that compatibility boundary; dependency/toolchain upgrades must widen
it deliberately after the Flyology runtime preparer and this repository's gates qualify the newer compiler.

The dependency includes the reviewed backend-neutral conditional publication contract plus narrow synchronous S3
`Put_If_Absent`, `Put_If_Matches`, and same-response `Get_Whole` operations. This local DB unit intentionally binds
the backend-neutral interface; authenticated S3 binding remains an additive review unit over the same outcome core.

The landed conditional-publication campaign reports `./tests/scripts/test.sh`,
`./sqlite/tests/scripts/test.sh`, `FLYOLOGY_S3_MATRIX_REPEATS=3 ./tests/scripts/test-s3-matrix.sh`, and
`./tools/prove.sh` green. Its manifest-wide proof reports 625/625 checks with no warnings, unproved checks,
justifications, or assumptions. Flyology.DB reruns its own adapter gates against this exact pin rather than treating
the upstream report as substitute evidence.

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
