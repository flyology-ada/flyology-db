# Flyology.DB

Flyology.DB is an experimental embedded, object-native transactional key-value database for Ada. Its Alire crate
is `flyology_db`, and its public Ada namespace is `Flyology.DB`.

The design uses object storage as the authority for committed state. The initial topology has one fenced writer,
read-only replicas, a database-wide sequence and commit log, and independent physical state per column family.
Memory and local files are bounded caches or staging areas; removing them must not remove an acknowledged durable
transaction.

This repository is under active development. The current acceptance state and remaining work are recorded in
[the milestone plan](docs/architecture/milestones.md). No production qualification or performance claim is made.
The pending operational slice covers provider-neutral memory/files backends, HEAD-v2 root manifests, and stable
column-family handles with persisted per-family limits. Authenticated remote binding, dynamic family changes, and
owned large-value arenas remain separate review units.

## Durability rule

A transaction is durably committed only after its complete immutable batch object is published and `meta/HEAD` is
conditionally advanced from the exact expected generation. A lost response is reconciled by reading the head and
matching the transition identity; unresolved storage failure remains `Outcome_Unknown`.

The normative architecture is in [overview.md](docs/architecture/overview.md), and persisted format requirements
are in [persisted-formats.md](docs/architecture/persisted-formats.md). Differential engines are comparative oracles;
the [workload contract](oracles/contract/README.md) and Ada/SPARK model define Flyology.DB semantics.

## Build and verification

The ignored `.deps/flyology-object-storage` directory is a clean clone of the local Object Storage author checkout.
The root manifest path-pins it for development while leaving its indexed HTTP dependency unchanged.

```sh
alr build
./tests/scripts/test.sh
./scripts/prove.sh
./scripts/check-tla.sh
./scripts/check-repository.sh
```

The exact Object Storage commit used by the current campaign is recorded in
[dependency-provenance.md](docs/qualification/dependency-provenance.md).

The TLA+ gate exhausts the bounded commit-publication state machine, checks the unbounded safety kernel with TLAPS,
and regenerates a workload witness for later replay against the Ada model, Flyology.DB, and comparative oracles.
