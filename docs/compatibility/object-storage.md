# Object Storage capability matrix

Exact dependency provenance is recorded separately. A capability is marked qualified only after the same black-box
contract and fault cases pass for that provider.

| Capability | Memory | Files | SQLite | S3 client | Flyology.DB use |
| --- | --- | --- | --- | --- | --- |
| Complete immutable put | Qualified upstream | Qualified upstream | Qualified upstream | Present | Commit/SST objects |
| Put if absent | Atomic protected publication | Atomic filesystem publication gate | Atomic catalog transaction | Strict signed header maps through server | Ready for adapter qualification |
| Replace expected generation | Atomic opaque-generation match | Atomic opaque-generation match | Atomic opaque-generation match | Strict signed header maps through server | Ready for adapter qualification |
| Exact metadata/generation | Present through `Object_Information` | Present | Present | Present | Head inspection |
| Generation-bound range read | Present through read conditions | Present | Present | Present | Head/SST reads |
| Conditional delete | Batch ETag condition only | Batch ETag condition only | Batch ETag condition only | Present | Later GC qualification |
| Bounded listing | Present | Present | Present | Present | Discovery/GC only |
| Explicit unknown publication | Synchronous result has no admission certainty | Same | Same | Not exposed as one DB-ready result | Conservatively unknown, then reconcile |

Object Storage commit `a8e22e999cd12d0d51ddc07fe0563a48031dff24` supplies backend-neutral `Write_Conditions`, atomic evaluation across
memory/files/SQLite, strict authenticated S3 header mapping, and conformance/fault evidence. Flyology.DB must now run
its own adapter tests at that pin. The synchronous client does not expose request-admission certainty, so Flyology.DB
must not infer definite nonpublication from exceptions: an inconclusive mutation remains `Outcome_Unknown` until a
generation-bound whole read validates the attempted immutable bytes or HEAD transition. Genuine composable typed
certainty remains dependent on the later Object Storage `Client.Scoped` API.
