#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

test -f AGENTS.md
test -f alire.toml
test -f flyology_db.gpr
test -f src/flyology-db.ads
test -f docs/qualification/dependency-provenance.md
test -f oracles/contract/workload.schema.json
test -x oracles/contract/validate_workload.py
test -f oracles/contract/canonical-state.md
test -x oracles/contract/canonical_state.py
test -f oracles/contract/canonical_state_vectors.json
test -f oracles/adapters/slatedb/Cargo.lock
test -f oracles/adapters/slatedb/Cargo.toml
test -x oracles/adapters/slatedb/run_workload.py
test -x oracles/adapters/slatedb/scripts/build.sh
test -x oracles/adapters/slatedb/scripts/test.sh
test -x oracles/adapters/slatedb/tests/test_adapter.py
test -x formal/tla/witness_to_workload.py
test -x formal/tla/validate_reconciliation_witnesses.py
test -x formal/tla/validate_manifest_witnesses.py
test -x scripts/check-tla.sh
test -f formal/tla/CommitPublication.tla
test -f formal/tla/PublicationSafetyProof.tla
test -x oracles/adapters/tidesdb/adapter.py
test -x oracles/adapters/tidesdb/run_workload.py
test -x oracles/adapters/tidesdb/scripts/build.sh
test -x oracles/adapters/tidesdb/scripts/run.sh
test -x oracles/adapters/tidesdb/scripts/test.sh
test -x oracles/adapters/tidesdb/scripts/test-upstream.sh
test -f formal/tla/ManifestPublication.tla
test -f formal/tla/ManifestPublication.cfg
test -f formal/tla/ManifestPublicationWitness.tla
test -f formal/tla/ManifestPublicationFailureWitness.tla
test -f formal/tla/ManifestRegistryMutationProbe.tla
test -f formal/tla/ManifestSafetyProof.tla
test -f formal/tla/ImmutableCache.tla
test -f formal/tla/ImmutableCache.cfg
test -f formal/tla/ImmutableCacheStaleProbe.tla
test -f formal/tla/ImmutableCacheStaleProbe.cfg
test -f formal/tla/ImmutableCacheWitness.tla
test -f formal/tla/ImmutableCacheWitness.cfg
test -f formal/tla/ImmutableCacheSafetyProof.tla
test -x formal/tla/validate_immutable_cache_witness.py
test -f formal/tla/ObjectRetention.tla
test -f formal/tla/ObjectRetention.cfg
test -f formal/tla/ObjectRetentionListingProbe.tla
test -f formal/tla/ObjectRetentionListingProbe.cfg
test -f formal/tla/ObjectRetentionWitness.tla
test -f formal/tla/ObjectRetentionWitness.cfg
test -f formal/tla/ObjectRetentionSafetyProof.tla
test -x formal/tla/validate_object_retention_witness.py
test -f formal/tla/ReplicaRefresh.tla
test -f formal/tla/ReplicaRefresh.cfg
test -f formal/tla/ReplicaRefreshStaleWriterProbe.tla
test -f formal/tla/ReplicaRefreshStaleWriterProbe.cfg
test -f formal/tla/ReplicaRefreshRollbackProbe.tla
test -f formal/tla/ReplicaRefreshRollbackProbe.cfg
test -f formal/tla/ReplicaRefreshWitness.tla
test -f formal/tla/ReplicaRefreshWitness.cfg
test -f formal/tla/ReplicaRefreshSafetyProof.tla
test -x formal/tla/validate_replica_refresh_witness.py
test -f src/flyology-db-manifest_formats.ads
test -f src/flyology-db-manifest_formats.adb
test -f tests/src/flyology-db-manifest_format_tests.adb
grep -q '^name = "flyology_db"$' alire.toml
grep -q '^gnat = ">=13 & <=16[.]1[.]0"$' alire.toml
grep -q '^package Flyology.DB is$' src/flyology-db.ads
grep -q 'flyology_object_storage = { path=' alire.toml
dependency_commit=$(git -C .deps/flyology-object-storage rev-parse HEAD)
grep -q "$dependency_commit" docs/qualification/dependency-provenance.md
test -z "$(git -C .deps/flyology-object-storage status --short)"
slatedb_commit=$(git -C .deps/slatedb rev-parse HEAD)
tidesdb_commit=$(git -C .deps/tidesdb rev-parse HEAD)
grep -q "$slatedb_commit" docs/qualification/dependency-provenance.md
grep -q "$slatedb_commit" oracles/adapters/slatedb/src/lib.rs
grep -q "$tidesdb_commit" docs/qualification/dependency-provenance.md
test -z "$(git -C .deps/slatedb status --short)"
test -z "$(git -C .deps/tidesdb status --short)"
oracles/contract/canonical_state.py oracles/contract/canonical_state_vectors.json
grep -q "$tidesdb_commit" oracles/adapters/tidesdb/adapter.py
grep -q "$tidesdb_commit" oracles/adapters/tidesdb/oracle_shim.c
oracles/contract/validate_workload.py \
  oracles/contract/workload.schema.json \
  oracles/workloads/*.ndjson
oracles/contract/validate_workload.py \
  oracles/contract/workload.schema.json \
  oracles/contract/valid/*.ndjson
oracles/contract/validate_workload.py \
  oracles/contract/workload.schema.json \
  oracles/adapters/slatedb/tests/fixtures/*.ndjson
for invalid_workload in oracles/contract/invalid/*.ndjson
do
  if oracles/contract/validate_workload.py \
    oracles/contract/workload.schema.json "$invalid_workload" >/dev/null 2>&1
  then
    printf '%s\n' "invalid workload was accepted: $invalid_workload" >&2
    exit 1
  fi
done
git diff --check
printf '%s\n' "Flyology.DB repository checks passed"
printf '%s\n' "  Object Storage $dependency_commit"
printf '%s\n' "  SlateDB        $slatedb_commit"
printf '%s\n' "  TidesDB        $tidesdb_commit"
