#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tools_root="$project_root/.deps/tla"
tlc_jar="$tools_root/tla2tools.jar"
tlapm="$tools_root/tlapm/bin/tlapm"
model_root="$project_root/formal/tla"
expected_workload="$project_root/oracles/workloads/tla_commit_publication_witness.ndjson"

if test -n "${FLYOLOGY_TLA_JAVA:-}"
then
  java_command=$FLYOLOGY_TLA_JAVA
elif command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1
then
  java_command=$(command -v java)
elif test -x "/Applications/Protégé.app/Contents/jre/bin/java"
then
  java_command="/Applications/Protégé.app/Contents/jre/bin/java"
else
  printf '%s\n' "TLC requires Java 11 or newer; set FLYOLOGY_TLA_JAVA" >&2
  exit 1
fi

test -f "$tlc_jar"
test -x "$tlapm"
test "$(shasum -a 256 "$tlc_jar" | awk '{print $1}')" = \
  "eabd140a70f49eb9305a3bd3f3df944eddf87e5a90d329789085f8953a80533a"
test "$(shasum -a 256 "$tlapm" | awk '{print $1}')" = \
  "291db0665c3b599f5343b03c06bcfb49b48ac966c39efff8643fa730f0d296b7"
test "$($tlapm --version)" = "4600b24"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-tla.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

cd "$model_root"
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-safety-states" \
  -config CommitPublication.cfg CommitPublication \
  >"$temporary_root/tlc-safety.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-safety.log"
! grep -q '^Warning:' "$temporary_root/tlc-safety.log"
grep -q '112031 distinct states found' "$temporary_root/tlc-safety.log"
grep -q 'The depth of the complete state graph search is 14.' \
  "$temporary_root/tlc-safety.log"
for action in PrepareGroup PreparePooled StoreBatch PublishHead ObserveSuccess \
  LoseAcceptedResponse LoseUnacceptedResponse ObservePreconditionFailure \
  ResolveCommitted ResolvePreconditionFailure AcquireWriter Crash Recover
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-safety.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE -metadir "$temporary_root/tlc-stale-probe-states" \
  -config CommitPublicationStaleProbe.cfg CommitPublicationStaleProbe \
  >"$temporary_root/tlc-stale-probe.log" 2>&1
stale_probe_status=$?
set -e
test "$stale_probe_status" -eq 12
grep -q 'Invariant NoStaleWriterPublication is violated.' \
  "$temporary_root/tlc-stale-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-stale-probe.log"

for reconciliation in committed failed
do
  if test "$reconciliation" = committed
  then
    witness_module=CommitPublicationDescendantCommittedWitness
    witness_invariant=DescendantCommittedPending
  else
    witness_module=CommitPublicationDescendantFailureWitness
    witness_invariant=DescendantFailurePending
  fi
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-descendant-$reconciliation-states" \
    -config "$witness_module.cfg" \
    -dumpTrace json "$temporary_root/descendant-$reconciliation.json" \
    "$witness_module" \
    >"$temporary_root/tlc-descendant-$reconciliation.log" 2>&1
  witness_status=$?
  set -e
  test "$witness_status" -eq 12
  grep -q "Invariant $witness_invariant is violated." \
    "$temporary_root/tlc-descendant-$reconciliation.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-descendant-$reconciliation.log"
  "$model_root/validate_reconciliation_witnesses.py" \
    "$reconciliation" "$temporary_root/descendant-$reconciliation.json"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-overlap-probe-states" \
  -config PublicationSafetyOverlapProbe.cfg PublicationSafetyOverlapProbe \
  >"$temporary_root/tlc-overlap-probe.log" 2>&1
overlap_probe_status=$?
set -e
test "$overlap_probe_status" -eq 12
grep -q 'Invariant UnknownTransactionsCannotBeActive is violated.' \
  "$temporary_root/tlc-overlap-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-overlap-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE -metadir "$temporary_root/tlc-witness-states" \
  -config CommitPublicationWitness.cfg \
  -dumpTrace json "$temporary_root/witness.json" CommitPublicationWitness \
  >"$temporary_root/tlc-witness.log" 2>&1
witness_status=$?
set -e
test "$witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' "$temporary_root/tlc-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-witness.log"

"$model_root/witness_to_workload.py" "$temporary_root/witness.json" \
  >"$temporary_root/workload.ndjson"
cmp "$temporary_root/workload.ndjson" "$expected_workload"
"$project_root/oracles/contract/validate_workload.py" \
  "$project_root/oracles/contract/workload.schema.json" \
  "$expected_workload"

"$tlapm" --cache-dir "$temporary_root/tlapm-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/PublicationSafetyProof.tla" \
  >"$temporary_root/tlaps.log" 2>&1
grep -q 'All 23 obligations proved.' "$temporary_root/tlaps.log"

"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-manifest-states" \
  -config ManifestPublication.cfg ManifestPublication \
  >"$temporary_root/tlc-manifest.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-manifest.log"
! grep -q '^Warning:' "$temporary_root/tlc-manifest.log"
grep -q '286 distinct states found' "$temporary_root/tlc-manifest.log"
grep -q 'The depth of the complete state graph search is 10.' \
  "$temporary_root/tlc-manifest.log"
for action in StoreRoot LoseRootPutResponseStored LoseRootPutResponseAbsent \
  ConfirmRootBytes ResolveRootPutAbsent PublishRoot LoseAcceptedRootResponse \
  LoseUnacceptedRootResponse ExternalStoreSuccessor ExternalPublishSuccessor \
  StoreCompetingRoot PublishCompetingRoot ObserveSuccess ResolveCommitted \
  ResolveFailed Crash Recover
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-manifest.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-manifest-mutation-states" \
  -config ManifestRegistryMutationProbe.cfg ManifestRegistryMutationProbe \
  >"$temporary_root/tlc-manifest-mutation.log" 2>&1
manifest_mutation_status=$?
set -e
test "$manifest_mutation_status" -eq 12
grep -q 'Invariant RegistryIsMonotonic is violated' \
  "$temporary_root/tlc-manifest-mutation.log"
! grep -q '^Warning:' "$temporary_root/tlc-manifest-mutation.log"

for reconciliation in committed failed
do
  if test "$reconciliation" = committed
  then
    manifest_witness_module=ManifestPublicationWitness
    manifest_witness_invariant=WitnessPending
  else
    manifest_witness_module=ManifestPublicationFailureWitness
    manifest_witness_invariant=FailureWitnessPending
  fi
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-manifest-$reconciliation-states" \
    -config "$manifest_witness_module.cfg" \
    -dumpTrace json "$temporary_root/manifest-$reconciliation.json" \
    "$manifest_witness_module" \
    >"$temporary_root/tlc-manifest-$reconciliation.log" 2>&1
  manifest_witness_status=$?
  set -e
  test "$manifest_witness_status" -eq 12
  grep -q "Invariant $manifest_witness_invariant is violated." \
    "$temporary_root/tlc-manifest-$reconciliation.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-manifest-$reconciliation.log"
  "$model_root/validate_manifest_witnesses.py" \
    "$reconciliation" "$temporary_root/manifest-$reconciliation.json"
done

"$tlapm" --cache-dir "$temporary_root/tlapm-manifest-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/ManifestSafetyProof.tla" \
  >"$temporary_root/tlaps-manifest.log" 2>&1
grep -q 'All 12 obligations proved.' "$temporary_root/tlaps-manifest.log"

"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-checkpoint-states" \
  -config CheckpointPublication.cfg CheckpointPublication \
  >"$temporary_root/tlc-checkpoint.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-checkpoint.log"
! grep -q '^Warning:' "$temporary_root/tlc-checkpoint.log"
grep -q '819 distinct states found' "$temporary_root/tlc-checkpoint.log"
grep -q 'The depth of the complete state graph search is 19.' \
  "$temporary_root/tlc-checkpoint.log"
for action in ReserveFailedIdentity CommitPrefix \
  FamilyRunCapacityBackpressure DatabaseRunCapacityBackpressure \
  IdentityCapacityBackpressure BeginFlush StoreRun ConfirmRun StoreManifest \
  ConfirmManifest PublishFlush LoseAcceptedFlushResponse \
  LoseUnacceptedFlushResponse ObserveFlushSuccess ExternalCommitLater \
  RivalTransition ResolveCommitted ResolveRejected \
  ExternalAdvanceBeforeFlushPublication HideRun CorruptRunRead Crash Recover \
  RejectRecovery
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-checkpoint.log"
done

for checkpoint_probe in stale partial family ledger
do
  case "$checkpoint_probe" in
    stale)
      checkpoint_probe_module=CheckpointStalePublicationProbe
      checkpoint_probe_invariant=StaleFlushCannotPublish
      ;;
    partial)
      checkpoint_probe_module=CheckpointPartialRunProbe
      checkpoint_probe_invariant=HeadReferencesConfirmedManifestAndRuns
      ;;
    family)
      checkpoint_probe_module=CheckpointWrongFamilyProbe
      checkpoint_probe_invariant=FamilyPlacementIsExact
      ;;
    ledger)
      checkpoint_probe_module=CheckpointWrongLedgerProbe
      checkpoint_probe_invariant=CheckpointContentsAreExact
      ;;
  esac
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-checkpoint-$checkpoint_probe-states" \
    -config "$checkpoint_probe_module.cfg" "$checkpoint_probe_module" \
    >"$temporary_root/tlc-checkpoint-$checkpoint_probe.log" 2>&1
  checkpoint_probe_status=$?
  set -e
  test "$checkpoint_probe_status" -eq 12
  grep -q "Invariant $checkpoint_probe_invariant is violated" \
    "$temporary_root/tlc-checkpoint-$checkpoint_probe.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-checkpoint-$checkpoint_probe.log"
done

for checkpoint_witness in committed rejected recovery
do
  case "$checkpoint_witness" in
    committed)
      checkpoint_witness_module=CheckpointPublicationCommittedWitness
      ;;
    rejected)
      checkpoint_witness_module=CheckpointPublicationRejectedWitness
      ;;
    recovery)
      checkpoint_witness_module=CheckpointPublicationRecoveryWitness
      ;;
  esac
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-checkpoint-$checkpoint_witness-states" \
    -config "$checkpoint_witness_module.cfg" \
    -dumpTrace json "$temporary_root/checkpoint-$checkpoint_witness.json" \
    "$checkpoint_witness_module" \
    >"$temporary_root/tlc-checkpoint-$checkpoint_witness.log" 2>&1
  checkpoint_witness_status=$?
  set -e
  test "$checkpoint_witness_status" -eq 12
  grep -q 'Invariant WitnessPending is violated.' \
    "$temporary_root/tlc-checkpoint-$checkpoint_witness.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-checkpoint-$checkpoint_witness.log"
  "$model_root/validate_checkpoint_witnesses.py" \
    "$checkpoint_witness" \
    "$temporary_root/checkpoint-$checkpoint_witness.json"
done

"$tlapm" --cache-dir "$temporary_root/tlapm-checkpoint-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/CheckpointSafetyProof.tla" \
  >"$temporary_root/tlaps-checkpoint.log" 2>&1
grep -q 'All 43 obligations proved.' "$temporary_root/tlaps-checkpoint.log"

#  The two-versus-three manifest history choice is finite qualification
#  geometry that covers definite backpressure and a permitted replacement; it
#  is not a product default. The pinned graph detects accidental narrowing.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-successive-checkpoint-states" \
  -config SuccessiveCheckpointPublication.cfg SuccessiveCheckpointPublication \
  >"$temporary_root/tlc-successive-checkpoint.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-successive-checkpoint.log"
! grep -q '^Warning:' "$temporary_root/tlc-successive-checkpoint.log"
grep -q '37 distinct states found' "$temporary_root/tlc-successive-checkpoint.log"
grep -q 'The depth of the complete state graph search is 17.' \
  "$temporary_root/tlc-successive-checkpoint.log"
for action in CommitPrefix BeginFirst StoreFirstRun ConfirmFirstRun \
  StoreFirstManifest ConfirmFirstManifest PublishFirst CommitSuffix \
  RejectSecondHistoryCapacity BeginSecond StoreSecondRun ConfirmSecondRun \
  StoreSecondManifest ConfirmSecondManifest PublishSecondAs ResolveSecond \
  Crash Recover
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-successive-checkpoint.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-successive-checkpoint-probe-states" \
  -config SuccessiveCheckpointPartialProbe.cfg SuccessiveCheckpointPartialProbe \
  >"$temporary_root/tlc-successive-checkpoint-probe.log" 2>&1
successive_checkpoint_probe_status=$?
set -e
test "$successive_checkpoint_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-successive-checkpoint-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-successive-checkpoint-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-successive-checkpoint-witness-states" \
  -config SuccessiveCheckpointRecoveryWitness.cfg \
  -dumpTrace json "$temporary_root/successive-checkpoint-recovery.json" \
  SuccessiveCheckpointRecoveryWitness \
  >"$temporary_root/tlc-successive-checkpoint-witness.log" 2>&1
successive_checkpoint_witness_status=$?
set -e
test "$successive_checkpoint_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-successive-checkpoint-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-successive-checkpoint-witness.log"
"$model_root/validate_successive_checkpoint_witness.py" \
  "$temporary_root/successive-checkpoint-recovery.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-successive-checkpoint-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/SuccessiveCheckpointSafetyProof.tla" \
  >"$temporary_root/tlaps-successive-checkpoint.log" 2>&1
grep -q 'All 24 obligations proved.' "$temporary_root/tlaps-successive-checkpoint.log"

#  One-versus-two family/global run limits are finite qualification geometry
#  for persisted backpressure, not product defaults. The pinned graph detects
#  accidental narrowing of tombstone, append, or uncertainty coverage.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-l0-accumulation-states" \
  -config L0Accumulation.cfg L0Accumulation \
  >"$temporary_root/tlc-l0-accumulation.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-l0-accumulation.log"
! grep -q '^Warning:' "$temporary_root/tlc-l0-accumulation.log"
grep -q '49 distinct states found' "$temporary_root/tlc-l0-accumulation.log"
grep -q 'The depth of the complete state graph search is 17.' \
  "$temporary_root/tlc-l0-accumulation.log"
for action in CommitPrefix BeginFirst StoreFirstRun ConfirmFirstRun \
  StoreFirstManifest ConfirmFirstManifest PublishFirst CommitSuffix \
  RejectSecondRunCapacity BeginSecond StoreSecondRun ConfirmSecondRun \
  StoreSecondManifest ConfirmSecondManifest PublishSecondAs ResolveSecond \
  Crash Recover
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-l0-accumulation.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-l0-accumulation-probe-states" \
  -config L0AccumulationPartialProbe.cfg L0AccumulationPartialProbe \
  >"$temporary_root/tlc-l0-accumulation-probe.log" 2>&1
l0_accumulation_probe_status=$?
set -e
test "$l0_accumulation_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-l0-accumulation-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-l0-accumulation-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-l0-accumulation-witness-states" \
  -config L0AccumulationRecoveryWitness.cfg \
  -dumpTrace json "$temporary_root/l0-accumulation-recovery.json" \
  L0AccumulationRecoveryWitness \
  >"$temporary_root/tlc-l0-accumulation-witness.log" 2>&1
l0_accumulation_witness_status=$?
set -e
test "$l0_accumulation_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-l0-accumulation-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-l0-accumulation-witness.log"
"$model_root/validate_l0_accumulation_witness.py" \
  "$temporary_root/l0-accumulation-recovery.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-l0-accumulation-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/L0AccumulationSafetyProof.tla" \
  >"$temporary_root/tlaps-l0-accumulation.log" 2>&1
grep -q 'All 24 obligations proved.' "$temporary_root/tlaps-l0-accumulation.log"

#  Zero-versus-one compacted-output capacity is finite qualification geometry,
#  not a product default. Physical deletion is absent: superseded runs remain
#  stored history after the successor manifest depublicizes them.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-l0-compaction-states" \
  -config L0Compaction.cfg L0Compaction \
  >"$temporary_root/tlc-l0-compaction.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-l0-compaction.log"
! grep -q '^Warning:' "$temporary_root/tlc-l0-compaction.log"
grep -q '35 distinct states found' "$temporary_root/tlc-l0-compaction.log"
grep -q 'The depth of the complete state graph search is 10.' \
  "$temporary_root/tlc-l0-compaction.log"
for action in RejectOutputCapacity BeginCompaction StoreOutput ConfirmNoOutput \
  ConfirmOutput StoreManifest ConfirmManifest PublishAs ResolvePublication \
  Crash HideOutput RejectRecovery Recover
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-l0-compaction.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-l0-compaction-probe-states" \
  -config L0CompactionPartialProbe.cfg L0CompactionPartialProbe \
  >"$temporary_root/tlc-l0-compaction-probe.log" 2>&1
l0_compaction_probe_status=$?
set -e
test "$l0_compaction_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-l0-compaction-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-l0-compaction-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-l0-compaction-witness-states" \
  -config L0CompactionRecoveryWitness.cfg \
  -dumpTrace json "$temporary_root/l0-compaction-recovery.json" \
  L0CompactionRecoveryWitness \
  >"$temporary_root/tlc-l0-compaction-witness.log" 2>&1
l0_compaction_witness_status=$?
set -e
test "$l0_compaction_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-l0-compaction-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-l0-compaction-witness.log"
"$model_root/validate_l0_compaction_witness.py" \
  "$temporary_root/l0-compaction-recovery.json"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-l0-compaction-empty-witness-states" \
  -config L0CompactionEmptyRecoveryWitness.cfg \
  -dumpTrace json "$temporary_root/l0-compaction-empty-recovery.json" \
  L0CompactionEmptyRecoveryWitness \
  >"$temporary_root/tlc-l0-compaction-empty-witness.log" 2>&1
l0_compaction_empty_witness_status=$?
set -e
test "$l0_compaction_empty_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-l0-compaction-empty-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-l0-compaction-empty-witness.log"
"$model_root/validate_l0_compaction_empty_witness.py" \
  "$temporary_root/l0-compaction-empty-recovery.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-l0-compaction-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/L0CompactionSafetyProof.tla" \
  >"$temporary_root/tlaps-l0-compaction.log" 2>&1
grep -q 'All 26 obligations proved.' "$temporary_root/tlaps-l0-compaction.log"

#  Two keys, two values, and absent/no-mutation/tombstone sentinels are finite
#  qualification geometry. The replacement run emits no tombstones: it must
#  reproduce every captured read and remain equivalent after any later delta.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-lsm-equivalence-states" \
  -config LSMCompactionEquivalence.cfg LSMCompactionEquivalence \
  >"$temporary_root/tlc-lsm-equivalence.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-lsm-equivalence.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-equivalence.log"
grep -q '576 distinct states found' "$temporary_root/tlc-lsm-equivalence.log"
grep -q 'The depth of the complete state graph search is 4.' \
  "$temporary_root/tlc-lsm-equivalence.log"
for action in BuildCompactedRun RecoverCompactedRun ReplayLaterDelta
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-lsm-equivalence.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lsm-equivalence-probe-states" \
  -config LSMCompactionEquivalenceProbe.cfg LSMCompactionEquivalenceProbe \
  >"$temporary_root/tlc-lsm-equivalence-probe.log" 2>&1
lsm_equivalence_probe_status=$?
set -e
test "$lsm_equivalence_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-lsm-equivalence-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-equivalence-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lsm-equivalence-witness-states" \
  -config LSMCompactionEquivalenceWitness.cfg \
  -dumpTrace json "$temporary_root/lsm-compaction-equivalence.json" \
  LSMCompactionEquivalenceWitness \
  >"$temporary_root/tlc-lsm-equivalence-witness.log" 2>&1
lsm_equivalence_witness_status=$?
set -e
test "$lsm_equivalence_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-lsm-equivalence-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-equivalence-witness.log"
"$model_root/validate_lsm_compaction_equivalence_witness.py" \
  "$temporary_root/lsm-compaction-equivalence.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-lsm-equivalence-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/LSMCompactionEquivalenceSafetyProof.tla" \
  >"$temporary_root/tlaps-lsm-equivalence.log" 2>&1
grep -q 'All 6 obligations proved.' "$temporary_root/tlaps-lsm-equivalence.log"

#  Zero-versus-one cache capacity is finite qualification geometry, not a
#  product default. Exact immutable generations bind requests, cache entries,
#  coalesced fetches, and results; local cache/fetch state remains disposable.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-immutable-cache-states" \
  -config ImmutableCache.cfg ImmutableCache \
  >"$temporary_root/tlc-immutable-cache.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-immutable-cache.log"
! grep -q '^Warning:' "$temporary_root/tlc-immutable-cache.log"
grep -q '623 distinct states found' "$temporary_root/tlc-immutable-cache.log"
grep -q 'The depth of the complete state graph search is 12.' \
  "$temporary_root/tlc-immutable-cache.log"
for action in BeginRead CacheHit StartFetch JoinFetch CompleteFetch FinishRead \
  AdvanceAuthority CorruptCache RejectCorruptHit EvictCache LocalLoss
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-immutable-cache.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-immutable-cache-probe-states" \
  -config ImmutableCacheStaleProbe.cfg ImmutableCacheStaleProbe \
  >"$temporary_root/tlc-immutable-cache-probe.log" 2>&1
immutable_cache_probe_status=$?
set -e
test "$immutable_cache_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-immutable-cache-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-immutable-cache-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-immutable-cache-witness-states" \
  -config ImmutableCacheWitness.cfg \
  -dumpTrace json "$temporary_root/immutable-cache-witness.json" \
  ImmutableCacheWitness \
  >"$temporary_root/tlc-immutable-cache-witness.log" 2>&1
immutable_cache_witness_status=$?
set -e
test "$immutable_cache_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-immutable-cache-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-immutable-cache-witness.log"
"$model_root/validate_immutable_cache_witness.py" \
  "$temporary_root/immutable-cache-witness.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-immutable-cache-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/ImmutableCacheSafetyProof.tla" \
  >"$temporary_root/tlaps-immutable-cache.log" 2>&1
grep -q 'All 13 obligations proved.' "$temporary_root/tlaps-immutable-cache.log"

#  The exhaustive graph uses two symmetric identities and the exact witness
#  adds a third orphan identity. These are qualification geometry, not an age
#  threshold, retention horizon, delete batch size, or provider policy.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-object-retention-states" \
  -config ObjectRetention.cfg ObjectRetention \
  >"$temporary_root/tlc-object-retention.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-object-retention.log"
! grep -q '^Warning:' "$temporary_root/tlc-object-retention.log"
grep -q '75337 distinct states found' "$temporary_root/tlc-object-retention.log"
grep -q 'The depth of the complete state graph search is 16.' \
  "$temporary_root/tlc-object-retention.log"
for action in Store ListObject MarkOld AcquireSnapshot ReleaseSnapshot \
  PinReplica ReleaseReplica Advance ReleasePredecessor BeginUnknown \
  ResolveUnknown DeleteEligible DiscardDiscovery
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-object-retention.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-object-retention-probe-states" \
  -config ObjectRetentionListingProbe.cfg ObjectRetentionListingProbe \
  >"$temporary_root/tlc-object-retention-probe.log" 2>&1
object_retention_probe_status=$?
set -e
test "$object_retention_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-object-retention-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-object-retention-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-object-retention-witness-states" \
  -config ObjectRetentionWitness.cfg \
  -dumpTrace json "$temporary_root/object-retention-witness.json" \
  ObjectRetentionWitness \
  >"$temporary_root/tlc-object-retention-witness.log" 2>&1
object_retention_witness_status=$?
set -e
test "$object_retention_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-object-retention-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-object-retention-witness.log"
"$model_root/validate_object_retention_witness.py" \
  "$temporary_root/object-retention-witness.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-object-retention-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/ObjectRetentionSafetyProof.tla" \
  >"$temporary_root/tlaps-object-retention.log" 2>&1
grep -q 'All 15 obligations proved.' "$temporary_root/tlaps-object-retention.log"

"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-replica-refresh-states" \
  -config ReplicaRefresh.cfg ReplicaRefresh \
  >"$temporary_root/tlc-replica-refresh.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-replica-refresh.log"
! grep -q '^Warning:' "$temporary_root/tlc-replica-refresh.log"
grep -q '1460 distinct states found' "$temporary_root/tlc-replica-refresh.log"
grep -q 'The depth of the complete state graph search is 15.' \
  "$temporary_root/tlc-replica-refresh.log"
for action in ConfirmSuccessor BeginWriter FenceEpoch CancelWriter Publish \
  BeginRefresh CompleteLoad InstallRefresh DiscardRefresh
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-replica-refresh.log"
done

for probe in StaleWriter Rollback
do
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-replica-${probe}-probe-states" \
    -config "ReplicaRefresh${probe}Probe.cfg" "ReplicaRefresh${probe}Probe" \
    >"$temporary_root/tlc-replica-${probe}-probe.log" 2>&1
  replica_probe_status=$?
  set -e
  test "$replica_probe_status" -eq 12
  grep -q 'Invariant Safety is violated.' \
    "$temporary_root/tlc-replica-${probe}-probe.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-replica-${probe}-probe.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-replica-refresh-witness-states" \
  -config ReplicaRefreshWitness.cfg \
  -dumpTrace json "$temporary_root/replica-refresh-witness.json" \
  ReplicaRefreshWitness >"$temporary_root/tlc-replica-refresh-witness.log" 2>&1
replica_witness_status=$?
set -e
test "$replica_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-replica-refresh-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-replica-refresh-witness.log"
"$model_root/validate_replica_refresh_witness.py" \
  "$temporary_root/replica-refresh-witness.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-replica-refresh-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/ReplicaRefreshSafetyProof.tla" \
  >"$temporary_root/tlaps-replica-refresh.log" 2>&1
grep -q 'All 11 obligations proved.' "$temporary_root/tlaps-replica-refresh.log"

#  Qualification pins for the reviewed two-transaction/two-key model graph.
#  They detect accidental state-space narrowing; changing the model requires a
#  fresh graph review and an intentional update of these expected results.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-snapshot-isolation-states" \
  -config SnapshotIsolation.cfg SnapshotIsolation \
  >"$temporary_root/tlc-snapshot-isolation.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-snapshot-isolation.log"
! grep -q '^Warning:' "$temporary_root/tlc-snapshot-isolation.log"
grep -q '336 distinct states found' "$temporary_root/tlc-snapshot-isolation.log"
grep -q 'The depth of the complete state graph search is 10.' \
  "$temporary_root/tlc-snapshot-isolation.log"
for action in Begin BufferWrite Commit RejectConflict Checkpoint
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-snapshot-isolation.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-snapshot-isolation-probe-states" \
  -config SnapshotIsolationUnsafeCommitProbe.cfg SnapshotIsolationUnsafeCommitProbe \
  >"$temporary_root/tlc-snapshot-isolation-probe.log" 2>&1
snapshot_probe_status=$?
set -e
test "$snapshot_probe_status" -eq 12
grep -q 'Invariant NoInvalidCommit is violated.' \
  "$temporary_root/tlc-snapshot-isolation-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-snapshot-isolation-probe.log"

for snapshot_witness in conflict disjoint checkpoint
do
  case "$snapshot_witness" in
    conflict)
      snapshot_witness_module=SnapshotIsolationWitness
      ;;
    disjoint)
      snapshot_witness_module=SnapshotIsolationDisjointWitness
      ;;
    checkpoint)
      snapshot_witness_module=SnapshotIsolationCheckpointWitness
      ;;
  esac
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-snapshot-$snapshot_witness-states" \
    -config "$snapshot_witness_module.cfg" \
    -dumpTrace json "$temporary_root/snapshot-$snapshot_witness.json" \
    "$snapshot_witness_module" \
    >"$temporary_root/tlc-snapshot-$snapshot_witness.log" 2>&1
  snapshot_witness_status=$?
  set -e
  test "$snapshot_witness_status" -eq 12
  grep -q 'Invariant WitnessPending is violated.' \
    "$temporary_root/tlc-snapshot-$snapshot_witness.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-snapshot-$snapshot_witness.log"
  "$model_root/validate_snapshot_isolation_witnesses.py" \
    "$snapshot_witness" "$temporary_root/snapshot-$snapshot_witness.json"
done

"$tlapm" --cache-dir "$temporary_root/tlapm-snapshot-isolation-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/SnapshotIsolationSafetyProof.tla" \
  >"$temporary_root/tlaps-snapshot-isolation.log" 2>&1
grep -q 'All 6 obligations proved.' "$temporary_root/tlaps-snapshot-isolation.log"

#  The two transactions, two values, and two committed-version slots are
#  finite qualification geometry, not product retention or value limits. The
#  pinned graph prevents accidental narrowing without a reviewed model change.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-snapshot-reads-states" \
  -config SnapshotReads.cfg SnapshotReads \
  >"$temporary_root/tlc-snapshot-reads.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-snapshot-reads.log"
! grep -q '^Warning:' "$temporary_root/tlc-snapshot-reads.log"
grep -q '7530 distinct states found' "$temporary_root/tlc-snapshot-reads.log"
grep -q 'The depth of the complete state graph search is 14.' \
  "$temporary_root/tlc-snapshot-reads.log"
for action in Begin BufferPut BufferDelete Commit RecordRead Checkpoint
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-snapshot-reads.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-snapshot-reads-probe-states" \
  -config SnapshotReadsUnsafeProbe.cfg SnapshotReadsUnsafeProbe \
  >"$temporary_root/tlc-snapshot-reads-probe.log" 2>&1
snapshot_read_probe_status=$?
set -e
test "$snapshot_read_probe_status" -eq 12
grep -q 'Invariant NoBadRead is violated.' \
  "$temporary_root/tlc-snapshot-reads-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-snapshot-reads-probe.log"

for snapshot_read_witness in old own too-old
do
  case "$snapshot_read_witness" in
    old)
      snapshot_read_module=SnapshotReadsOldWitness
      ;;
    own)
      snapshot_read_module=SnapshotReadsOwnWitness
      ;;
    too-old)
      snapshot_read_module=SnapshotReadsTooOldWitness
      ;;
  esac
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-snapshot-read-$snapshot_read_witness-states" \
    -config "$snapshot_read_module.cfg" \
    -dumpTrace json "$temporary_root/snapshot-read-$snapshot_read_witness.json" \
    "$snapshot_read_module" \
    >"$temporary_root/tlc-snapshot-read-$snapshot_read_witness.log" 2>&1
  snapshot_read_witness_status=$?
  set -e
  test "$snapshot_read_witness_status" -eq 12
  grep -q 'Invariant WitnessPending is violated.' \
    "$temporary_root/tlc-snapshot-read-$snapshot_read_witness.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-snapshot-read-$snapshot_read_witness.log"
  "$model_root/validate_snapshot_read_witnesses.py" \
    "$snapshot_read_witness" "$temporary_root/snapshot-read-$snapshot_read_witness.json"
done

"$tlapm" --cache-dir "$temporary_root/tlapm-snapshot-reads-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/SnapshotReadsSafetyProof.tla" \
  >"$temporary_root/tlaps-snapshot-reads.log" 2>&1
grep -q 'All 7 obligations proved.' "$temporary_root/tlaps-snapshot-reads.log"

#  This reviewed finite-geometry fingerprint is qualification evidence, not a
#  product capacity. A changed count/depth requires inspection of the model graph.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-serializable-states" \
  -config SerializableValidation.cfg SerializableValidation \
  >"$temporary_root/tlc-serializable.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-serializable.log"
! grep -q '^Warning:' "$temporary_root/tlc-serializable.log"
grep -q '44244 distinct states found' "$temporary_root/tlc-serializable.log"
grep -q 'The depth of the complete state graph search is 13.' \
  "$temporary_root/tlc-serializable.log"
for action in Begin BufferWrite RecordPoint RejectPointCapacity RecordRange \
  RejectRangeCapacity Commit RejectConflict
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-serializable.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-serializable-probe-states" \
  -config SerializableUnsafeCommitProbe.cfg SerializableUnsafeCommitProbe \
  >"$temporary_root/tlc-serializable-probe.log" 2>&1
serializable_probe_status=$?
set -e
test "$serializable_probe_status" -eq 12
grep -q 'Invariant NoInvalidCommit is violated.' \
  "$temporary_root/tlc-serializable-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-serializable-probe.log"

for serializable_witness in point range snapshot own
do
  case "$serializable_witness" in
    point)
      serializable_module=SerializablePointWitness
      ;;
    range)
      serializable_module=SerializableRangeWitness
      ;;
    snapshot)
      serializable_module=SerializableSnapshotWitness
      ;;
    own)
      serializable_module=SerializableOwnWriteWitness
      ;;
  esac
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-serializable-$serializable_witness-states" \
    -config "$serializable_module.cfg" \
    -dumpTrace json "$temporary_root/serializable-$serializable_witness.json" \
    "$serializable_module" \
    >"$temporary_root/tlc-serializable-$serializable_witness.log" 2>&1
  serializable_witness_status=$?
  set -e
  test "$serializable_witness_status" -eq 12
  grep -q 'Invariant WitnessPending is violated.' \
    "$temporary_root/tlc-serializable-$serializable_witness.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-serializable-$serializable_witness.log"
  "$model_root/validate_serializable_witnesses.py" \
    "$serializable_witness" "$temporary_root/serializable-$serializable_witness.json"
done

"$tlapm" --cache-dir "$temporary_root/tlapm-serializable-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/SerializableValidationSafetyProof.tla" \
  >"$temporary_root/tlaps-serializable.log" 2>&1
#  One initialization, eight action, and one quiescence theorem establish the
#  reviewed 10-obligation total; this count changes only with the proof kernel.
grep -q 'All 10 obligations proved.' "$temporary_root/tlaps-serializable.log"

#  Two families and four key positions are finite qualification geometry. The
#  pinned graph covers disjoint ranges, endpoint contact, transitive bridges,
#  capacity rollback, allocation rollback, and cross-family separation.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-range-normalization-states" \
  -config RangeNormalization.cfg RangeNormalization \
  >"$temporary_root/tlc-range-normalization.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-range-normalization.log"
! grep -q '^Warning:' "$temporary_root/tlc-range-normalization.log"
grep -q '3419 distinct states found' "$temporary_root/tlc-range-normalization.log"
grep -q 'The depth of the complete state graph search is 4.' \
  "$temporary_root/tlc-range-normalization.log"
for action in RecordRange RejectCapacity RejectAllocation
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-range-normalization.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-range-normalization-probe-states" \
  -config RangeNormalizationProbe.cfg RangeNormalizationProbe \
  >"$temporary_root/tlc-range-normalization-probe.log" 2>&1
range_normalization_probe_status=$?
set -e
test "$range_normalization_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-range-normalization-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-range-normalization-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-range-normalization-witness-states" \
  -config RangeNormalizationWitness.cfg \
  -dumpTrace json "$temporary_root/range-normalization-witness.json" \
  RangeNormalizationWitness \
  >"$temporary_root/tlc-range-normalization-witness.log" 2>&1
range_normalization_witness_status=$?
set -e
test "$range_normalization_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-range-normalization-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-range-normalization-witness.log"
"$model_root/validate_range_normalization_witness.py" \
  "$temporary_root/range-normalization-witness.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-range-normalization-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/RangeNormalizationSafetyProof.tla" \
  >"$temporary_root/tlaps-range-normalization.log" 2>&1
#  The structured initialization, successful-action, rejection-action, and
#  quiescence proofs establish the reviewed 19-obligation total.
grep -q 'All 19 obligations proved.' "$temporary_root/tlaps-range-normalization.log"

printf '%s\n' "Flyology.DB TLA+ checks passed"
printf '%s\n' "  TLC   112031 distinct states, depth 14"
printf '%s\n' "  TLAPS 23/23 obligations"
printf '%s\n' "  Negative stale-publication probe detected"
printf '%s\n' "  Negative overlapping-transaction ownership probe detected"
printf '%s\n' "  Deep committed/failed reconciliation witnesses validated"
printf '%s\n' "  Witness pooled accepted-response loss, reconciliation, crash, recovery"
printf '%s\n' "  Manifest TLC 286 distinct states, depth 10"
printf '%s\n' "  Manifest TLAPS 12/12 obligations"
printf '%s\n' "  Manifest committed/failed reconciliation witnesses validated"
printf '%s\n' "  Negative manifest registry-mutation probe detected"
printf '%s\n' "  Checkpoint TLC 819 distinct states, depth 19"
printf '%s\n' "  Checkpoint TLAPS 43/43 obligations"
printf '%s\n' "  Checkpoint committed/rejected/recovery witnesses validated"
printf '%s\n' "  Negative checkpoint stale/partial/family/ledger probes detected"
printf '%s\n' "  Successive checkpoint TLC 37 distinct states, depth 17"
printf '%s\n' "  Successive checkpoint TLAPS 24/24 obligations"
printf '%s\n' "  Successive checkpoint lost-response recovery witness validated"
printf '%s\n' "  Negative successive-checkpoint early-HEAD probe detected"
printf '%s\n' "  Additive L0 TLC 49 distinct states, depth 17"
printf '%s\n' "  Additive L0 TLAPS 24/24 obligations"
printf '%s\n' "  Additive L0 tombstone/lost-response recovery witness validated"
printf '%s\n' "  Negative additive-L0 early-HEAD probe detected"
printf '%s\n' "  L0 compaction TLC 35 distinct states, depth 10"
printf '%s\n' "  L0 compaction TLAPS 26/26 obligations"
printf '%s\n' "  L0 compaction lost-response recovery witness validated"
printf '%s\n' "  L0 empty-output lost-response recovery witness validated"
printf '%s\n' "  Negative L0-compaction early-HEAD probe detected"
printf '%s\n' "  LSM read equivalence TLC 576 distinct states, depth 4"
printf '%s\n' "  LSM read equivalence TLAPS 6/6 obligations"
printf '%s\n' "  LSM replacement/delete/replay witness validated"
printf '%s\n' "  Negative omitted-live-key replacement probe detected"
printf '%s\n' "  Immutable cache TLC 623 distinct states, depth 12"
printf '%s\n' "  Immutable cache TLAPS 13/13 obligations"
printf '%s\n' "  Cache coalescing/loss/corruption witness validated"
printf '%s\n' "  Negative stale-generation cache probe detected"
printf '%s\n' "  Object retention TLC 75337 distinct states, depth 16"
printf '%s\n' "  Object retention TLAPS 15/15 obligations"
printf '%s\n' "  Snapshot/replica/predecessor/unknown retention witness validated"
printf '%s\n' "  Negative listing-only deletion probe detected"
printf '%s\n' "  Replica refresh TLC 1460 distinct states, depth 15"
printf '%s\n' "  Replica refresh TLAPS 11/11 obligations"
printf '%s\n' "  Fencing/lagging-refresh/catch-up witness validated"
printf '%s\n' "  Negative stale-writer and replica-rollback probes detected"
printf '%s\n' "  Snapshot isolation TLC 336 distinct states, depth 10"
printf '%s\n' "  Snapshot isolation TLAPS 6/6 obligations"
printf '%s\n' "  Snapshot conflict/disjoint/checkpoint witnesses validated"
printf '%s\n' "  Negative unsafe snapshot commit probe detected"
printf '%s\n' "  Snapshot reads TLC 7530 distinct states, depth 14"
printf '%s\n' "  Snapshot reads TLAPS 7/7 obligations"
printf '%s\n' "  Snapshot old/own/too-old witnesses validated"
printf '%s\n' "  Negative latest-value snapshot read probe detected"
printf '%s\n' "  Serializable validation TLC 44244 distinct states, depth 13"
printf '%s\n' "  Serializable validation TLAPS 10/10 obligations"
printf '%s\n' "  Serializable point/range/snapshot/own witnesses validated"
printf '%s\n' "  Negative unsafe serializable commit probe detected"
printf '%s\n' "  Range normalization TLC 3419 distinct states, depth 4"
printf '%s\n' "  Range normalization TLAPS 19/19 obligations"
printf '%s\n' "  Bridge/cross-family/capacity/allocation witness validated"
printf '%s\n' "  Negative incomplete-bridge normalization probe detected"
