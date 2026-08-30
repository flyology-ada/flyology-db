# Cross-engine benchmark panel

This directory defines the benchmark contract for the public Flyology.DB
comparison panel. It is benchmark-only. No adapter, source checkout, server,
or benchmark dependency becomes part of the production crate.

The panel has two independent lanes:

1. `local_durable` compares Flyology.DB Files, SlateDB with filesystem sync,
   and TidesDB with unified WAL plus full sync.
2. `remote_durable_rustfs` compares database operations whose successful
   result includes the participant's documented remote-durability barrier on
   the exact pinned RustFS server.

The lanes are not pooled or ranked together. TidesDB is explicitly
unsupported in the remote lane because the pinned implementation can ignore
object-store WAL upload failures. SlateDB is eligible only when the benchmark
awaits its durable write handle and keeps WAL enabled. Flyology.DB uses the
indexed `flyology_object_storage=0.1.0-dev` release and records its exact source
and Alire-index commits for every campaign.

`panel.json` is the machine-readable participant and lane manifest.
`workload.json` fixes the cross-engine operation semantics without turning its
fixture geometry into product policy. `result.schema.json` is the retained
result shape. `validate_result.py` binds results to all three files and rejects
unsupported or incomplete lanes, mixed durability, mismatched power metadata,
missing provenance, malformed samples, divergent state checksums, and
summaries that do not match their retained samples.

The common workload uses one writer, one mutation per transaction, 16-byte
sequential unique keys, and 1,024-byte values. The timed operation is
begin, put, and durable commit. Database creation, close, reopen, full key
verification, and SHA-256 state calculation remain outside the timed region.
Every repetition starts from a fresh database. Warmup and measured operation
counts are campaign inputs, but the retained key count must equal their sum.

No result belongs on the website until:

- every participant passes its correctness preflight;
- the power-profile detector reports a comparable profile immediately before
  each participant measurement and the artifact retains that participant's
  exact detector result;
- all participants in one comparison use the same host, power source,
  workload identity, seed, operation geometry, and repetition count;
- raw samples, errors, checksums, source identities, build flags, and storage
  configuration are retained; and
- `validate_result.py` accepts the complete campaign artifact.

A laptop campaign is directional. It is not a portable performance claim or
a production qualification. A formal baseline additionally requires the
isolated-host protocol in the repository performance rules.
