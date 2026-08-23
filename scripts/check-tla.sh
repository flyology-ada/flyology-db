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
