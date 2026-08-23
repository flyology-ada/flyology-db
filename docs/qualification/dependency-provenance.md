# Dependency provenance

## Current development campaign

- Dependency: `flyology_object_storage`
- Source: clean local clone `.deps/flyology-object-storage`
- Author checkout origin: `../flyology-object-storage` (observed read-only)
- Commit: `00ac6b925ea884fb94853a0e315556b9d94c1bd1`
- Commit subject: `Problem: provisional composable HTTP baseline is superseded`
- Pin: root `alire.toml` filesystem path pin
- Transitive HTTP/QUIC source: immutable Flyology.HTTP commit
  `4147160562b14d8ca9db8f7ba9758258781eeca9`
- Observed: 2026-08-23, America/Vancouver

The dependency is local-only. Before a deterministic campaign, update the clean clone by fast-forward from its local
origin, verify it is clean, and replace this record with the exact commit used. Do not update it during a running
test, proof, or benchmark campaign.

Flyology.DB names `Flyology.Cancellation` and the native task model directly, so its root manifest declares
`flyology` directly instead of relying on transitive visibility. This campaign resolves indexed Flyology 0.1.1 plus
the Object Storage pin's immutable Flyology.HTTP/QUIC revision above. The root constraint
`gnat = ">=13 & <=16.1.0"` records the qualified compiler boundary; dependency/toolchain upgrades must widen it
deliberately after the Flyology runtime preparer and this repository's gates qualify the newer compiler.

The dependency includes the reviewed backend-neutral conditional publication contract, synchronous conditional Put
and whole Get operations, and the provisional composable client baseline. This DB slice still binds only the
backend-neutral synchronous interface; adopting the composable surface remains a later focused review unit over the
same outcome and ownership core.

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
