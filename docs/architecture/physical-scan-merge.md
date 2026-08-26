# Owned physical scan merge

The owned physical scan slice replaces repeated whole-source capture and global sorting behind the established
`Scan_Cursor` API. `Start_Scan` and `Next_Scan_Page` retain their explicit caller page budgets. Whole `Scan` now
captures that same cursor and requires one complete page under the database's persisted live-row and live-byte
limits before replacing its result. This changes private execution and ownership only: fixed-snapshot semantics,
`Scan_Result`, and every public outcome remain unchanged. No persisted format, provider request, task, retry,
default, automatic compaction choice, or page-size policy is introduced.

## Owned source snapshot

A cursor does not retain raw coordinator, database, transaction, checkpoint, batch, or family pointers between calls.
Close, replica refresh, checkpoint activation, and compaction may replace and reclaim the engine after a page call
releases its lifecycle lease. The physical cursor instead owns a complete immutable merge snapshot:

- one copied ordered descriptor/index view for the checkpoint base;
- one copied, key-ordered, newest-per-key descriptor/index view for each visible suffix batch;
- one copied, key-ordered view of the transaction's unique own mutations;
- one retained reference for every immutable image used by those descriptors; and
- one current position per source plus the last emitted key.

The source count and every descriptor extent are derived with checked arithmetic from the exact retained checkpoint,
persisted history bounds, and transaction arena admitted under `Database_Limits` and per-family limits. Allocation is
lazy. A source snapshot is fully built before it replaces prior cursor state; allocation, corruption, stale-snapshot,
or lifecycle failure releases all candidates and preserves the previous cursor. Retained images make the cursor safe
across engine replacement without keeping a database lifecycle lease or original handle pointer.

This is an owned in-memory physical merge cursor. It removes repeated source capture and global sorting per page,
but it does not stream SST or batch objects from Object Storage and does not claim constant memory independent of the
retained source descriptors.

## Merge rule

Every source is sorted by unsigned-byte key and contains at most one effective entry for a key. At each step the
cursor finds the lowest current head key, collects every source head with that key, chooses the newest authority in
the fixed order `own mutation > newest visible suffix batch > ... > oldest suffix batch > checkpoint base`, and
advances every matching source together. A winning tombstone emits no row. A winning Put emits exactly one key/value
row. Advancing only the winner could later duplicate or resurrect an older value; choosing any older matching source
would violate snapshot visibility.

Page construction uses candidate source positions, result storage, and last-key storage. If the first remaining live
row cannot fit the explicit empty-page budgets, or any candidate allocation fails, the retained positions, prior
page, and predicate authority remain unchanged. Once a nonempty maximal page is complete, all candidate positions
and the page publish together. Tombstones may advance candidate positions while searching for the next live row, but
those advances become authoritative only with a successful page or successful empty completion.

Transaction own-mutation version validation and one-time Serializable predicate retention remain exactly as defined
by [`paged-scans.md`](paged-scans.md). Whole `Scan` requests the complete retained interval from this same private
page engine with limits derived from the cursor's persisted authority. If the captured live view cannot complete
within those limits, the page and Serializable predicate remain unpublished and `Scan` returns `Capacity_Exceeded`.

## Formal and qualification boundary

`PhysicalScanMerge.tla` checks equal-head advancement, newest-source precedence, tombstone suppression, fixed source
capture after concurrent current-authority change, and allocation rejection. One negative probe advances only the
winning source and another chooses an older value; both must violate safety. A checked witness emits own key one and
newer-suffix key two while suppressing key three through a tombstone. `PhysicalScanMergeSafetyProof.tla` proves the
abstract output-prefix, completion, and rejection-atomicity action kernel for arbitrary finite position and row sets.

The formal geometry is not product policy, and no refinement proof is claimed. Executable acceptance additionally
requires exact byte ordering, prefix-key cases, duplicate collapse within and across batches, zero-length keys and
values, tombstones between pages, allocation rollback at every new owner, snapshot and Serializable behavior,
checkpoint/compaction/reopen, close/finalization, whole-scan parity, and all supported provider lanes.
