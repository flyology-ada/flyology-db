# SlateDB adapter

This directory contains the executable comparative adapter for SlateDB commit
`e0161973d8d7ffdede7c44725729838811674e99`. `Cargo.lock` fixes the adapter dependency graph, while
`scripts/build.sh` independently verifies the clean ignored source checkout, Rust 1.91.1, the disabled SlateDB
default features, and the exact source SHA before building. The script writes the effective build identity to the
ignored `build/oracles/slatedb-adapter/provenance.json` artifact.

The default executable uses SlateDB over `object_store::local::LocalFileSystem` with filesystem synchronization
enabled. This is a deterministic local durability and crash-recovery qualification profile. It does **not** claim
the normative `remote_durable` capability. A workload that expects any result other than explicit `Unsupported` from
a remote commit derives that capability even if its header omitted it, and therefore fails preflight before SlateDB
creates or opens a database. No local result is relabeled as remote durability.

## Protocol

The adapter reads one strict JSON object per line and writes one response per valid request. Each request has a
nonempty `request_id`, `operation`, and operation-specific fields; every response preserves the exact request ID.
The protocol version is `flyology.db.oracle.adapter.v1`. Binary database, transaction, receipt, key, value, and range
fields use canonical padded RFC 4648 base64. Unknown members, noncanonical base64, wrong lengths, and configured
bounds violations yield `Unsupported` without calling the engine. Request IDs are at most 256 UTF-8 bytes, and every
transaction-bearing command validates its canonical 16-byte identifier before any map or engine lookup.

`preflight` carries the validated workload header in an adapter-specific envelope. It must succeed before an engine
operation and accepts exactly one family named `default`. Its family ID must be canonical nonzero decimal `u32` and
is retained only for logical state projection. SlateDB has no column families, so the adapter never prefixes keys,
opens parallel databases, or claims
cross-family atomicity. Supported local-profile capabilities are `snapshot`, `serializable`, and `crash_recovery`;
`multi_column_family`, `remote_durable`, and `outcome_resolution` fail before effects.

The command-line database path is not an independent identity: it must equal `flyology-db-` followed by the lowercase
hexadecimal preflight database ID. This prevents a direct caller from reopening one SlateDB namespace under a
different logical database identity.

The operation surface is `create`, `open`, `reopen`, `recovery`, `begin`, `get`, `put`, `delete`, half-open `scan`,
`commit`, `rollback`, `flush`, `checkpoint`, `state`, `resolve`, and `crash`. `resolve` is explicitly unsupported.
Every wire-level `commit` requires a canonical 16-byte receipt and must select `remote` or `local_comparative`.
Missing or malformed receipts are rejected before removing the active transaction. The local profile rejects
`remote` before it consumes the transaction; a direct local comparison awaits SlateDB's returned durability handle
and labels the response `local_comparative`. `resolve` also validates its receipt before returning its capability
rejection. SlateDB's stable public `ErrorKind` is the only engine error input to normalization; exception text is
neither parsed nor returned. Any post-admission `Data` failure is ambiguous, becomes `Outcome_Unknown`, and returns
the exact receipt; only pre-admission `Data` is `Corrupt`. SlateDB consumes an engine transaction before reporting any
commit failure; the adapter retains a bounded logical marker for every definite failure so the contract-required
cleanup `rollback` still succeeds. Every terminal `Success` or `Outcome_Unknown` atomically reserves its receipt in
one phase-tagged, process-session registry. The fixed default and hard ceiling is 4,096 receipts, independently of
the active-transaction limit; `--max-receipt-ids` may lower it. A reused receipt or exhausted registry returns
pre-admission `Unsupported`, retaining the active transaction for rollback. Unknown outcomes additionally retain
their transaction identity against the declared transaction capacity, and `rollback` cannot consume them.

Because SlateDB has no persistent receipt resolution, an unresolved outcome quarantines that adapter instance:
`reopen` and clean EOF/shutdown fail while it remains unresolved, and `resolve` reports the unsupported capability
without clearing it. A supervisor must not treat abrupt process loss after an unknown outcome as permission to replay
either identity against the same namespace; this local comparative profile cannot reconstruct that process-local
ambiguity state. Successful receipt identities survive `reopen` in the same adapter process but do not block clean
shutdown. The registry is not persisted across a new process: the validated workload contract prevents receipt replay
across crash traces, while raw protocol callers must supply an equivalent durable idempotency authority if they need
cross-process enforcement.

`state` scans live keys in byte order with explicit item and projected-response byte limits. It implements the shared
[`canonical-state`](../../contract/canonical-state.md) encoding and consumes its machine-readable golden vectors.
State output includes base64 tuples and the lowercase digest. Scan and state projection account for JSON field,
family-ID, base64, comma, and response-envelope bytes before retaining each result; their hard ceiling is 64 MiB even
if a larger command-line limit is requested.
Tombstones are absent because SlateDB's public iterator exposes logical live state.

The normative workload runner validates the original workload first, adds capabilities implied by its operations,
and only then sends preflight. Workload `crash` records use `SIGKILL` from the outer runner and expect no response.
The direct protocol `crash` operation aborts without unwinding, also preventing a clean SlateDB close. The next
`reopen` after a kill is sent as `recovery` to a newly launched process.

## Reproduction

```sh
oracles/adapters/slatedb/scripts/build.sh
oracles/adapters/slatedb/scripts/run.sh OBJECT_ROOT DATABASE_PATH
oracles/adapters/slatedb/scripts/test.sh
```

The focused test gate runs Rust unit tests, black-box binary/base64/transaction/state tests, clean reopen, immediate
post-commit abort and `SIGKILL` recovery with data assertions, fail-closed family and remote-capability preflight, the
validated read-only workload fixture, and the audited upstream transaction and WAL recovery commands. Downloaded
source and all build/provenance artifacts remain ignored.
