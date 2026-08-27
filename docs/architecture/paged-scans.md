# Fixed-snapshot paged scans

The paged-scan API is an additive bounded alternative to complete `Scan`; it does not replace the established whole
materialization. Its purpose is to bound each published result while preserving the same canonical half-open range,
unsigned-byte key order, read-your-writes precedence, fixed transaction snapshot, and Serializable predicate rule.
It now has both storage-free initialization over already-materialized state and authenticated Object Storage
initialization, but it does not claim constant-memory source traversal.

## Public contract candidate

`Scan_Cursor` is a limited owned value colocated in `Flyology.DB`. `Start_Scan` validates one family and canonical
range, captures one immutable ordered physical source snapshot, copies every present endpoint, and atomically
replaces the cursor only on success. The cursor retains database identity, database incarnation, transaction
identity, snapshot sequence, family authority, a runtime-only transaction mutation version, retained immutable
image leases, copied transaction-local mutation bytes, per-source positions, and the last emitted key. It retains no
access value or borrow of the database, transaction, family handle, arena, coordinator, or caller endpoint arrays.

`Next_Scan_Page` receives the database, transaction, cursor, an explicit maximum row count, an explicit maximum
combined key-plus-value byte count, an existing `Scan_Result`, and returns `Done` plus `Outcome_Code`. Neither budget
has a default. They are caller backpressure for one call, not persisted database limits or a promised page size.
Persisted database and family limits remain independent upper admission authorities.

### Authenticated initialization

The additive caller-owned `Scan_Operation` and its blocking overload read the exact immutable run slice retained by
the current authenticated manifest. One caller-selected `Unique_Buffer` token supplies the sole object-read scratch
bound. Initiation validates operation ownership, lifecycle, transaction identity, family authority, endpoints, and
the exact run descriptor extent before moving that token. A busy completion set or initiation exception rolls back
the slot, lease, allocated state, and token byte/tag/metadata/length exact.

The operation traverses runs sequentially under one absolute monotonic deadline. Each run yields one canonical
snapshot-visible key/value or tombstone at a time through the generation-bound next-entry protocol. SST-v2 reads its
header, index, and one selected frame; SST-v1 uses the integrity-required whole-object compatibility fallback. The
operation compacts those selected entries into one exact owned source image per run and merges them with the captured
committed suffix and transaction-local mutations through the same physical cursor builder used by storage-free
initialization. It does not retain decoded whole SST images. There is no helper task, provider retry, prefetch,
run-count default, or cache. Typed `Finish` is the sole token restoration and cursor-publication authority; it accepts
any vacant handle from the original pool. Failure, cancellation, timeout, corruption, or allocation rejection
preserves the caller's prior cursor exactly.

The buffer-owned whole `Scan` overload is a literal blocking composition of that initialization and one complete
page request using the cursor's persisted live-row and live-byte bounds. It adds no second storage reader or merge
algorithm; page materialization retains the same atomic row and Serializable-predicate publication boundary.

This is a deliberately limited end-to-end path. The caller buffer bounds each object transfer, while the completed
cursor retains every selected snapshot-visible source entry needed by later storage-free pages. It no longer retains
whole SST objects, but its memory still grows with the selected source-entry set. A storage-backed page operation that
retains only current run heads, and any resulting constant-memory claim, remain later work; no hidden capacity or
eviction policy is inferred from this implementation.

The cursor fixes the transaction's own-write prefix by retaining the arena mutation version observed by
`Start_Scan`. Every successful `Put` or `Delete` advances that version, including replacement of an existing arena
slot whose mutation count is unchanged. The next page then returns `Invalid_State` without changing the cursor,
result, or predicate authority. Version exhaustion is classified before mutation publication as
`Capacity_Exceeded`; the value is runtime-only representational authority, not a persisted or normal-use resource
limit. A consumed transaction, wrong database/incarnation/transaction, or changed family authority is rejected the
same way. The cursor owns only the exact in-range effective transaction-local mutations, while this guard preserves
the established rule that later own writes invalidate rather than mix transaction views.

## Page selection and atomicity

For a valid active cursor, a successful page is the maximal next contiguous prefix in canonical key order that fits
both caller budgets. Every row is indivisible. Once a nonempty prefix is selected, a following row that does not fit
ends that successful resumable page. If the first remaining row cannot fit an empty page, the call returns
`Capacity_Exceeded`; it does not advance the cursor, replace the prior result, or retain a new Serializable
predicate. Allocation failure has the same atomic boundary and classification. The caller may retry with larger
budgets and receives the same next row.

A valid range with no visible rows succeeds with an empty result and `Done = True`, even when both budgets are zero.
Equal or reversed present endpoints remain `Invalid_State`; this empty-view rule does not weaken range validation.
The page containing the final row returns `Done = True`. Calling again after completion returns `Invalid_State` and
preserves the completed cursor and prior result.

`Scan_Result` remains the page owner. Successful publication replaces it atomically; every non-success outcome
leaves its exact prior descriptor/payload state unchanged. Row byte accounting is the checked sum of exact key and
value lengths. No native image, pointer, enumeration position, or cursor state is persisted.

## Isolation and concurrency

The committed portion of every page comes from the immutable source snapshot captured at the transaction's fixed
Begin sequence, so later transactions may replace, insert, delete, checkpoint, or compact keys without changing the
cursor's rows. The cursor retains exact immutable image leases but no database lifecycle lease between calls. Each
`Next_Scan_Page` reacquires the database only to validate lifecycle, identity, fencing, and family authority; the
page is built from cursor-owned sources and only the cursor/result swap is published after complete construction.

Snapshot isolation retains no scan predicate. In Serializable mode, the first successful page atomically records the
complete original range through the established normalization operation; this includes a successful empty view.
Subsequent pages do not consume another range component. If predicate retention fails, the first page is not
published and the cursor does not advance. Once retained, a later page failure preserves that already-authoritative
predicate.

## Formal and implementation boundary

`formal/tla/PagedScan.tla` checks maximal-prefix paging, tombstone masking, fixed-snapshot behavior after current
authority changes, row/byte backpressure, successful empty completion, and atomic allocation rejection. Its negative
probes skip the first visible key and publish a strict prefix when a larger page fits; both must violate safety. Its
executable witness reconstructs one frozen view after concurrent replacement, resurrection, and deletion.
`PagedScanSafetyProof.tla` proves the abstract prefix, completion, and failure-atomicity kernel.

The model dimensions are qualification geometry, not product defaults. The formal lane does not prove endpoint byte
comparison, transaction mutation-version validation, allocation, source capture, concurrency, progress, the Ada
implementation, or refinement. The current Ada implementation captures one bounded in-memory physical source
snapshot at `Start_Scan` and advances retained per-source positions without recapturing or globally sorting sources
per page. The authenticated overload reads exact SST objects sequentially from Object Storage before cursor
publication, but it does not lazily stream frames during paging or claim memory independent of retained run images.
The exact ownership and merge boundary is documented in
[`physical-scan-merge.md`](physical-scan-merge.md).
