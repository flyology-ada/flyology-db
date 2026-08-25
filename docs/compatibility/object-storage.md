# Object Storage capability matrix

Exact dependency provenance is recorded separately. A capability is marked qualified only after the same black-box
DB contract and certainty cases pass for that provider; upstream conformance is corroborating evidence rather than a
substitute for the DB gate.

| Capability | Memory | Files | SQLite | Authenticated S3 | Flyology.DB use |
| --- | --- | --- | --- | --- | --- |
| Complete immutable put | Implemented upstream | Implemented upstream | Implemented upstream | Buffer-owned scoped Put | Batch, SST, and manifest objects |
| Put if absent | Atomic protected publication | Atomic filesystem publication gate | Atomic catalog transaction | Typed admission/publication result | Immutable-object creation |
| Replace expected generation | Atomic opaque-generation match | Atomic opaque-generation match | Atomic catalog transaction | Typed conditional Put result | Exact `meta/HEAD` transition |
| Exact metadata/generation | Present | Present | Present | Opaque ETag/version retained | Same-response generation authority |
| Generation-bound whole/range read | Present | Present | Present | Scoped whole/range Get and Head | Reconciliation and selected SST reads |
| Explicit unknown publication | Conservatively mapped | Conservatively mapped | Conservatively mapped | `Outcome_Unknown` is typed | Same-identity read-only reconciliation |
| Conditional delete | Batch ETag condition only | Batch ETag condition only | Batch ETag condition only | Typed scoped Delete | Later GC qualification only |
| Bounded listing | Present | Present | Present | Scoped bounded page operations | Discovery/GC only, never visibility |

The current DB campaign pins the ignored clean Object Storage build clone at
`ea8c92c84fbd53b3c82e5004d7133c5b47633f3a`. Its buffer-owned synchronous conditional Put and whole/range Get calls
are literal waits over the same caller-owned `Client.Scoped` operations used by Flyology.DB's additive
`Flush_Operation`. One moved `Unique_Buffer` token, typed terminal `Finish`, one absolute deadline, and the same
publication/admission result therefore govern both blocking and composable DB calls. Neither layer creates a helper
task, retains a borrowed request body, or automatically retries a mutation.

Flyology.DB never infers definite nonpublication from an exception or incomplete response after a mutation may have
entered the provider. An inconclusive immutable-object Put remains `Outcome_Unknown` until a generation-bound whole
read validates the exact attempted bytes. An inconclusive HEAD transition retains its exact transition identity in
`Flush_Receipt`, fences later publication, and remains unknown until read-only reconciliation observes that transition
or a conclusive successor. Listing cannot establish either result.

The maintained authenticated DB probe exercises create, commit, synchronous and composable Flush, complete-run
replacement, caller-selected three-run merge, exact-token restoration, uncertainty reconciliation, close, and
cacheless reopen. Its Flyology-memory lane is green at the current pin. Repeated RustFS, SeaweedFS, MinIO, Flyology
files, and Flyology SQLite qualification remains pending the merged/indexed HTTP stale-reused-H1 correction; no DB or
Object Storage retry/certainty workaround is accepted in its place.
