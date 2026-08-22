# Normative workload contract

The workload contract defines Flyology.DB semantics. SlateDB and TidesDB adapters are comparative observations and
may report `Unsupported`; they do not change this contract.

Each NDJSON file begins with one `workload` record containing schema version, deterministic seed, bounded limits,
database identity, column-family configuration, and required capabilities. Later records are scheduled operations or
checkpoints. Client order and explicit barriers define the controlled schedule. Semantic time is injected separately
from measurement time.

`validate_workload.py workload.schema.json WORKLOAD...` is the executable version-1 structural and semantic gate. It
rejects duplicate JSON members and family IDs, operation-specific missing or irrelevant fields, invalid transaction
lifecycles, out-of-order steps, declared-limit violations, and checkpoints without an asserted digest or canonical
state. It also checks every operation branch, field set, outcome, capability, and conditional receipt/value rule in
the checked-in JSON Schema against the executable contract, preventing the two representations from drifting. A
`crash` record represents the outer runner terminating the adapter and therefore has no expected response.

A commit with `Outcome_Unknown` consumes the transaction and creates the named receipt. No later operation may replay,
mutate, commit, or roll back that transaction. Only `resolve` may inspect the receipt; inconclusive resolution keeps it
live, while a conclusive result consumes it. Commit receipt IDs are never reused in one workload.

Every commit in schema version 1 requests remote durability. Unless its expected outcome is explicitly `Unsupported`,
the workload header must therefore declare `remote_durable` in `required_capabilities`. Adapters reject a missing
required capability before executing any operation; local-fsync recovery is comparative evidence and never satisfies
this capability.

Normalized outcomes are `Success`, `Not_Found`, `Conflict`, `Serialization_Failure`, `Timed_Out`, `Cancelled`,
`Outcome_Unknown`, `Corrupt`, and `Unsupported`. At a checkpoint, adapters emit a canonical digest and may emit sorted
`(column_family_id, key_hex, value_hex_or_tombstone)` tuples for bounded small state.

Keys, values, IDs, and digests use lowercase hexadecimal strings. Numeric counters are exact unsigned decimal strings
when they may exceed language-neutral JSON integer precision. Unknown fields are rejected for schema version 1.

Concurrent comparisons validate allowed histories. They never require the same victim: for serializable write skew,
at most one conflicting transaction may commit, whichever engine aborts.
