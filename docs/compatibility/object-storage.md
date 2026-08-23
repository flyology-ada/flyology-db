# Object Storage capability matrix

Exact dependency provenance is recorded separately. A capability is marked qualified only after the same black-box
contract and fault cases pass for that provider.

| Capability | Memory | Files | SQLite | S3 client | Flyology.DB use |
| --- | --- | --- | --- | --- | --- |
| Complete immutable put | Qualified upstream | Qualified upstream | Qualified upstream | Present | Commit/SST objects |
| Put if absent | Atomic protected publication | Atomic filesystem publication gate | Atomic catalog transaction | Strict signed header maps through server | Local adapter exercised; remote pending |
| Replace expected generation | Atomic opaque-generation match | Atomic opaque-generation match | Atomic opaque-generation match | Strict signed header maps through server | Local adapter exercised; remote pending |
| Exact metadata/generation | Present through `Object_Information` | Present | Present | Present | Same-response whole reads exercised locally |
| Generation-bound range read | Present through read conditions | Present | Present | Present | Head/SST reads |
| Conditional delete | Batch ETag condition only | Batch ETag condition only | Batch ETag condition only | Present | Later GC qualification |
| Bounded listing | Present | Present | Present | Present | Discovery/GC only |
| Explicit unknown publication | Synchronous result has no admission certainty | Same | Same | Not exposed as one DB-ready result | Conservatively unknown, then reconcile |

Object Storage commit `8e6e435250433c06528ead054cebf613eabbb4ba` supplies backend-neutral `Write_Conditions`, atomic evaluation across
memory/files/SQLite, strict authenticated S3 header mapping, conformance/fault evidence, and narrow synchronous S3
conditional-put and same-response whole-get operations. The synchronous client still does not expose request-
admission certainty, so Flyology.DB must not infer definite nonpublication from exceptions: an inconclusive mutation
remains `Outcome_Unknown` until a whole read validates the attempted immutable bytes or HEAD transition. Genuine
composable typed certainty remains dependent on the later Object Storage `Client.Scoped` API.

The current DB review unit binds only `Backends.Backend'Class` and tests memory/files. Every conditional-put
exception and returned `Backend_Unavailable` after entering the call maps to unknown, including files publication
that may rename before a directory-sync failure. Immutable-batch ambiguity is reconciled byte-for-byte before HEAD;
it is not exposed as an ambiguous transaction commit. HEAD ambiguity produces the self-contained public receipt and
blocks later publication until exact-head or reachable-chain reconciliation. This is local-provider qualification,
not authenticated S3 qualification.
