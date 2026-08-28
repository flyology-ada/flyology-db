# Getting started with Flyology.DB

This guide takes a fresh public clone through a retained-checkpoint Files workflow. The example
checkpoints one value, commits a later live suffix, closes and reconstructs every provider and database
owner, appends a second family over that checkpoint and suffix, writes the new family, Flushes both changed
families, closes and reconstructs again, and verifies the installed registry and all three values from
object storage.

Flyology.DB is experimental. This walkthrough establishes the behavior of this exact maintained example;
it is not a production, portability, performance, or unattended-operations claim.

## Prerequisites

- Git.
- Alire 2.1.1.
- A GNAT toolchain accepted by the root manifest (`>=13` and `<=16.1.0`).
- A filesystem location where the example may create and retain a new directory.

Clone the repository and materialize its exact qualified Object Storage dependency:

```sh
git clone https://github.com/flyology-ada/flyology-db.git
cd flyology-db
bash scripts/materialize-development-dependencies.sh
alr build
```

The materializer creates only `.deps/flyology-object-storage`, from the canonical public repository at the
exact revision qualified by this DB tree. A repeated invocation accepts an exact clean clone and makes no
change. It fails closed if the target is dirty, partial, symlinked, has another origin or revision, or
contains untracked files; it never fetches, resets, updates, or silently selects a newer dependency.

## Run the Files example

Pass one absolute path that does not exist. Its parent must already exist, and the path must use that
physical parent without symbolic-link, empty, dot, or parent components. The runner does not choose a
temporary location and does not delete the result, so you retain custody of the durable files on success
and failure.

```sh
bash examples/run-files-getting-started.sh "$PWD/flyology-db-example-data"
```

A successful run prints:

```text
Flyology.DB Files retained-checkpoint live-suffix family reopen: OK
Flyology.DB Files getting started: OK
Retained Files root: /absolute/path/to/retained-demo
Flyology.DB Files getting started passed
Flyology.DB Files root (never removed by this runner): /absolute/path/to/flyology-db-example-data
```

Choose another fresh path for every run. Cleanup is deliberately outside the example: inspect or remove the
retained directory only when you no longer need it.

## What the example makes explicit

The code supplies the Files backend's maximum object size and durability choice, every persisted
`Database_Limits` field, both column-family configurations, and each operation timeout. Its two-family,
three-L0-run bounds are demonstration geometry, not Flyology.DB defaults or recommendations. A real
application must derive and qualify bounds for its own workload.

The example also supplies every database, transaction, immutable-object, and transition identity. Its
deterministic identities are acceptable only for this fresh-directory, single-run demonstration. They are not
an allocator and must not be copied into a persistent application. Applications own a durable never-reused
identity allocator and must preserve the identity associated with every attempted publication.

## Typed outcomes, receipts, and no replay

Create, Commit, Add_Column_Family, and Flush return typed outcomes and receipts. `Success` is conclusive. A
definite pre-admission failure leaves the corresponding caller-owned state reusable according to the operation
contract. `Outcome_Unknown` means the exact immutable object or conditional HEAD transition might have been
admitted.

When an outcome is unknown, do not repeat the application transaction and do not choose a replacement
identity. Retain the exact receipt and invoke the matching exact-receipt reconciliation operation:

- `Resolve_Create` for the same Create receipt;
- `Resolve` for the same Commit receipt;
- `Resolve_Add_Column_Family` for the same family-publication receipt;
- `Resolve_Flush` for the same Flush receipt.

The example implements each matching branch and requires reconciliation to reach a conclusive result before
continuing, but its normal Files run does not inject an unknown outcome or cancellation. Production code must
persist enough authority to perform the same exact-receipt reconciliation after interruption. Reconciliation
may finish the original pending publication under its retained identities, but it never selects replacement
identities or replays the application transaction.

## What to try next

- Read the [limited profile](../architecture/limited-profile.md) before designing an application boundary.
- Run `./showcases/run-limited-e2e.sh` for the larger maintained Files acceptance workflow.
- Use the authenticated Object Storage showcase only with an existing caller-owned bucket and a fresh prefix;
  its endpoint, credentials, region, addressing, timeout, cleanup, and retention policy remain caller
  responsibilities.
- Consult [proof status](../qualification/proof-status.md) and [reviews](../qualification/reviews.md) for the
  exact maintained qualification boundary.
