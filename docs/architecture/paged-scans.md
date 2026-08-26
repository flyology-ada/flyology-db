# Fixed-snapshot paged scans

The first paged-scan slice is an additive bounded alternative to `Scan`; it does not replace the established whole
materialization. Its purpose is to bound each published result while preserving the same canonical half-open range,
unsigned-byte key order, read-your-writes precedence, fixed transaction snapshot, and Serializable predicate rule.
It is a stepping stone toward physical merge iteration, not a claim that source traversal is already streaming.

## Public contract candidate

`Scan_Cursor` is a limited owned value colocated in `Flyology.DB`. `Start_Scan` validates one family and canonical
range, copies every present endpoint, and atomically replaces the cursor only on success. The cursor retains database
identity, database incarnation, transaction identity, snapshot sequence, family authority, the transaction mutation
count, and the last emitted key. It retains no access value or borrow of the database, transaction, family handle, or
caller endpoint arrays.

`Next_Scan_Page` receives the database, transaction, cursor, an explicit maximum row count, an explicit maximum
combined key-plus-value byte count, an existing `Scan_Result`, and returns `Done` plus `Outcome_Code`. Neither budget
has a default. They are caller backpressure for one call, not persisted database limits or a promised page size.
Persisted database and family limits remain independent upper admission authorities.

The cursor fixes the transaction's own-write prefix by retaining the arena mutation count observed by `Start_Scan`.
Any later successful `Put` or `Delete` changes that count; the next page then returns `Invalid_State` without changing
the cursor, result, or predicate authority. A consumed transaction, wrong database/incarnation/transaction, or
changed family authority is rejected the same way. This guard preserves one logical read view without copying the
transaction arena into a second owner.

## Page selection and atomicity

For a valid active cursor, a successful page is the maximal next contiguous prefix in canonical key order that fits
both caller budgets. Every row is indivisible. If rows remain and the next row cannot fit either budget, the call
returns `Capacity_Exceeded`; it does not advance the cursor, replace the prior result, or retain a new Serializable
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

The committed portion of every page is selected at the transaction's fixed Begin sequence, so later transactions may
replace, insert, or delete keys without changing the cursor's rows. The cursor itself retains no lifecycle lease
between calls. Each `Next_Scan_Page` reacquires and validates one coherent database view, and only the cursor/result
swap is published after complete page construction.

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
comparison, transaction mutation-count validation, allocation, source capture, concurrency, progress, the Ada
implementation, or refinement. The first Ada implementation may rescan bounded in-memory source descriptors for each
page; it must be described as paged materialization until a later physical merge cursor removes that remaining source
capture and repeated traversal.
