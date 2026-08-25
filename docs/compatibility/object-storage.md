# Object Storage capability matrix

Exact dependency provenance is recorded separately. A capability is marked qualified only after the same black-box
DB contract and certainty cases pass for that provider; upstream conformance is corroborating evidence rather than a
substitute for the DB gate.

| Capability | Memory | Files | SQLite | Authenticated S3 | Flyology.DB use |
| --- | --- | --- | --- | --- | --- |
| Complete immutable put | Implemented upstream | Implemented upstream | Implemented upstream | Buffer-owned provider operation | Batch, SST, and manifest objects |
| Put if absent | Atomic protected publication | Atomic filesystem publication gate | Atomic catalog transaction | Typed admission/publication result | Immutable-object creation |
| Replace expected generation | Atomic opaque-generation match | Atomic opaque-generation match | Atomic catalog transaction | Typed conditional Put result | Exact `meta/HEAD` transition |
| Exact metadata/generation | Present | Present | Present | Opaque ETag/version retained | Same-response generation authority |
| Generation-bound whole/range read | Present | Present | Present | Provider-owned whole/range Get and Head | Reconciliation and selected SST reads |
| Explicit unknown publication | Conservatively mapped | Conservatively mapped | Conservatively mapped | `Outcome_Unknown` is typed | Same-identity read-only reconciliation |
| Conditional delete | Batch ETag condition only | Batch ETag condition only | Batch ETag condition only | Typed provider operation | Later GC qualification only |
| Bounded listing | Present | Present | Present | Provider-owned bounded page operations | Discovery/GC only, never visibility |

The current DB campaign pins the ignored clean Object Storage build clone at
`1978275b4c4cd4704adc41ec52b167a7587b411f`. Its buffer-owned synchronous conditional Put and whole/range Get calls
are literal waits over the same caller-owned `Client.Objects` operations used by Flyology.DB's additive
`Flush_Operation`. One moved `Unique_Buffer` token, typed terminal `Finish`, one absolute deadline, and the same
publication/admission result therefore govern both blocking and composable DB calls. Neither layer creates a helper
task, retains a borrowed request body, or automatically retries a mutation.

The provider package owns the whole operation vocabulary: synchronous overload, limited constructor, reusable
operation-last initiation, operation type, and typed `Finish`. Scoped lifetime remains an ownership property of that
operation and its caller-owned completion set. It is not encoded in a second package tree, which would obscure the
shared state machine and create documentation, testing, and maintenance drift.

Flyology.DB never infers definite nonpublication from an exception or incomplete response after a mutation may have
entered the provider. An inconclusive immutable-object Put remains `Outcome_Unknown` until a generation-bound whole
read validates the exact attempted bytes. An inconclusive HEAD transition retains its exact transition identity in
`Flush_Receipt`, fences later publication, and remains unknown until read-only reconciliation observes that transition
or a conclusive successor. Listing cannot establish either result.

The maintained authenticated DB probe exercises create, first checkpoint, one direct-composable differently bounded
family append with lost-HEAD-response resolution through the exact append receipt, one blocking append implemented as
a wait on that same state machine, cross-family commit and Flush, public composable complete-run replacement, a
private caller-selected three-run merge, public blocking complete replacement with lost-HEAD-response resolution,
exact-token restoration, close, and cacheless reopen of all three families.
The published no-pin Object Storage handoff is qualified across RustFS, SeaweedFS, MinIO, Flyology memory/files, and
Flyology SQLite. The guarded HTTP stale-reused-H1 safe-read correction is part of the indexed dependency closure; no
DB or Object Storage retry/certainty workaround is present.
