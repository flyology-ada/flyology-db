#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
toolchain_root="$project_root/.deps/flyology-tla-toolchain"
tla_cli="$project_root/.deps/flyology-tla-cli/bin/flyology-tla"
model_root="$project_root/formal/tla"
trace_root="$model_root/traces"

test -x "$tla_cli"
"$tla_cli" toolchain verify "$toolchain_root"
eval "$("$tla_cli" toolchain env "$toolchain_root")"
java_command=$FLYOLOGY_TLA_JAVA
tlc_jar=$FLYOLOGY_TLA_TLC_JAR
tlapm=$FLYOLOGY_TLAPM
toolchain_identity=tla2tools-1.8.0+9787e65

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-tla.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1
  then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

check_trace() {
  raw_trace=$1
  module=$2
  normalized_trace="$temporary_root/$module.trace.json"
  "$tla_cli" trace normalize \
    "$raw_trace" "$normalized_trace" "$model_root/$module.tla" \
    --config "$model_root/$module.cfg" --toolchain "$toolchain_identity" 128 64
  "$tla_cli" trace validate "$normalized_trace" 128 64
  if test "${FLYOLOGY_DB_TLA_UPDATE_TRACES:-0}" != 1
  then
    cmp "$normalized_trace" "$trace_root/$module.trace.json"
  fi
}

trace_path() {
  module=$1
  if test "${FLYOLOGY_DB_TLA_UPDATE_TRACES:-0}" = 1
  then
    printf '%s\n' "$temporary_root/$module.trace.json"
  else
    printf '%s\n' "$trace_root/$module.trace.json"
  fi
}

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
  check_trace "$temporary_root/descendant-$reconciliation.json" "$witness_module"
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

check_trace "$temporary_root/witness.json" CommitPublicationWitness

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
  check_trace "$temporary_root/manifest-$reconciliation.json" "$manifest_witness_module"
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
  check_trace "$temporary_root/checkpoint-$checkpoint_witness.json" "$checkpoint_witness_module"
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
check_trace \
  "$temporary_root/successive-checkpoint-recovery.json" \
  SuccessiveCheckpointRecoveryWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-successive-checkpoint-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/SuccessiveCheckpointSafetyProof.tla" \
  >"$temporary_root/tlaps-successive-checkpoint.log" 2>&1
grep -q 'All 24 obligations proved.' "$temporary_root/tlaps-successive-checkpoint.log"

#  Two families and zero-to-two current runs are finite qualification geometry
#  for the persisted per-family and database-wide limit decision. They are not
#  product defaults. The model observes authority without reserving identity or
#  changing the checkpoint state.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-l0-selection-states" \
  -config L0CheckpointSelection.cfg L0CheckpointSelection \
  >"$temporary_root/tlc-l0-selection.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-l0-selection.log"
! grep -q '^Warning:' "$temporary_root/tlc-l0-selection.log"
grep -q '2240 distinct states found' "$temporary_root/tlc-l0-selection.log"
grep -q 'The depth of the complete state graph search is 2.' \
  "$temporary_root/tlc-l0-selection.log"
for action in ObserveNoWork ObserveAdditive ObserveComplete ObserveNoAdmissible
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-l0-selection.log"
done

for l0_selection_module in \
  L0CheckpointNoWorkWitness \
  L0CheckpointAdditiveWitness \
  L0CheckpointSelectionWitness \
  L0CheckpointNoAdmissibleWitness
do
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-$l0_selection_module-states" \
    -config "$l0_selection_module.cfg" \
    -dumpTrace json "$temporary_root/$l0_selection_module.json" \
    "$l0_selection_module" \
    >"$temporary_root/tlc-$l0_selection_module.log" 2>&1
  l0_selection_witness_status=$?
  set -e
  test "$l0_selection_witness_status" -eq 12
  grep -q 'Invariant WitnessPending is violated.' \
    "$temporary_root/tlc-$l0_selection_module.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-$l0_selection_module.log"
  check_trace "$temporary_root/$l0_selection_module.json" "$l0_selection_module"
done

conformance_runner="$project_root/tests/bin/flyology-db-tla-conformance"
test -x "$conformance_runner"
for l0_selection_module in \
  L0CheckpointNoWorkWitness \
  L0CheckpointAdditiveWitness \
  L0CheckpointSelectionWitness \
  L0CheckpointNoAdmissibleWitness
do
  result_path="$temporary_root/$l0_selection_module.result.json"
  replay_trace=$(trace_path "$l0_selection_module")
  "$conformance_runner" --format terse --result-json "$result_path" \
    "$replay_trace"
  grep -q '"format":"flyology.tla.result/1","verdict":"conformant"' \
    "$result_path"
  trace_sha256=$(sha256_file "$replay_trace")
  grep -q "\"trace_sha256\":\"$trace_sha256\"" "$result_path"
done

divergence_trace=$(trace_path L0CheckpointSelectionWitness)
set +e
"$conformance_runner" --buggy --format terse \
  --result-json "$temporary_root/l0-selection-divergence.result.json" \
  "$divergence_trace" \
  >"$temporary_root/l0-selection-divergence.log" 2>&1
l0_selection_divergence_status=$?
set -e
test "$l0_selection_divergence_status" -ne 0
grep -q '"verdict":"diverged"' \
  "$temporary_root/l0-selection-divergence.result.json"
grep -q '"property":"tla-conformance"' \
  "$temporary_root/l0-selection-divergence.result.json"
grep -q '"fingerprint":"outcome:L0CheckpointSelectionWitness!ObserveComplete"' \
  "$temporary_root/l0-selection-divergence.result.json"

"$tlapm" --cache-dir "$temporary_root/tlapm-l0-selection-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/L0CheckpointSelectionSafetyProof.tla" \
  >"$temporary_root/tlaps-l0-selection.log" 2>&1
grep -q 'All 8 obligations proved.' "$temporary_root/tlaps-l0-selection.log"

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
check_trace "$temporary_root/l0-accumulation-recovery.json" L0AccumulationRecoveryWitness

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
check_trace "$temporary_root/l0-compaction-recovery.json" L0CompactionRecoveryWitness

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
check_trace \
  "$temporary_root/l0-compaction-empty-recovery.json" \
  L0CompactionEmptyRecoveryWitness

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
check_trace \
  "$temporary_root/lsm-compaction-equivalence.json" \
  LSMCompactionEquivalenceWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-lsm-equivalence-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/LSMCompactionEquivalenceSafetyProof.tla" \
  >"$temporary_root/tlaps-lsm-equivalence.log" 2>&1
grep -q 'All 6 obligations proved.' "$temporary_root/tlaps-lsm-equivalence.log"

#  Two selected consecutive runs sit between retained older and newer runs,
#  followed by one post-checkpoint log suffix. Two keys and two values are
#  finite qualification geometry, not product policy. Partial merge preserves
#  the newest selected mutation per key, including tombstones, and transfers
#  the suffix and its transaction-identity authority unchanged.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-lsm-partial-equivalence-states" \
  -config LSMPartialCompactionEquivalence.cfg LSMPartialCompactionEquivalence \
  >"$temporary_root/tlc-lsm-partial-equivalence.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-lsm-partial-equivalence.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-partial-equivalence.log"
grep -q '3145728 distinct states found' "$temporary_root/tlc-lsm-partial-equivalence.log"
grep -q 'The depth of the complete state graph search is 3.' \
  "$temporary_root/tlc-lsm-partial-equivalence.log"
for action in BuildPartialMerge RecoverMergedRuns
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-lsm-partial-equivalence.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lsm-partial-equivalence-probe-states" \
  -config LSMPartialCompactionEquivalenceProbe.cfg \
  LSMPartialCompactionEquivalenceProbe \
  >"$temporary_root/tlc-lsm-partial-equivalence-probe.log" 2>&1
lsm_partial_equivalence_probe_status=$?
set -e
test "$lsm_partial_equivalence_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-lsm-partial-equivalence-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-partial-equivalence-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lsm-partial-equivalence-witness-states" \
  -config LSMPartialCompactionEquivalenceWitness.cfg \
  -dumpTrace json "$temporary_root/lsm-partial-compaction-equivalence.json" \
  LSMPartialCompactionEquivalenceWitness \
  >"$temporary_root/tlc-lsm-partial-equivalence-witness.log" 2>&1
lsm_partial_equivalence_witness_status=$?
set -e
test "$lsm_partial_equivalence_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-lsm-partial-equivalence-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-partial-equivalence-witness.log"
check_trace \
  "$temporary_root/lsm-partial-compaction-equivalence.json" \
  LSMPartialCompactionEquivalenceWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-lsm-partial-equivalence-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/LSMPartialCompactionEquivalenceSafetyProof.tla" \
  >"$temporary_root/tlaps-lsm-partial-equivalence.log" 2>&1
grep -q 'All 5 obligations proved.' "$temporary_root/tlaps-lsm-partial-equivalence.log"

#  Exactly three caller-selected consecutive runs qualify composition beyond
#  the two-run kernel without choosing a product fanout, trigger, level, or
#  capacity. The middle tombstone case is explicit because a later selected
#  run may contain no mutation for the key.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-lsm-three-run-states" \
  -config LSMThreeRunCompactionEquivalence.cfg \
  LSMThreeRunCompactionEquivalence \
  >"$temporary_root/tlc-lsm-three-run.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-lsm-three-run.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-three-run.log"
grep -q '12288 distinct states found' "$temporary_root/tlc-lsm-three-run.log"
grep -q 'The depth of the complete state graph search is 3.' \
  "$temporary_root/tlc-lsm-three-run.log"
for action in BuildThreeRunMerge RecoverMergedRuns
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-lsm-three-run.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lsm-three-run-probe-states" \
  -config LSMThreeRunCompactionEquivalenceProbe.cfg \
  LSMThreeRunCompactionEquivalenceProbe \
  >"$temporary_root/tlc-lsm-three-run-probe.log" 2>&1
lsm_three_run_probe_status=$?
set -e
test "$lsm_three_run_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-lsm-three-run-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-three-run-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lsm-three-run-witness-states" \
  -config LSMThreeRunCompactionEquivalenceWitness.cfg \
  -dumpTrace json "$temporary_root/lsm-three-run-compaction-equivalence.json" \
  LSMThreeRunCompactionEquivalenceWitness \
  >"$temporary_root/tlc-lsm-three-run-witness.log" 2>&1
lsm_three_run_witness_status=$?
set -e
test "$lsm_three_run_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-lsm-three-run-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-lsm-three-run-witness.log"
check_trace \
  "$temporary_root/lsm-three-run-compaction-equivalence.json" \
  LSMThreeRunCompactionEquivalenceWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-lsm-three-run-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/LSMThreeRunCompactionEquivalenceSafetyProof.tla" \
  >"$temporary_root/tlaps-lsm-three-run.log" 2>&1
grep -q 'All 7 obligations proved.' "$temporary_root/tlaps-lsm-three-run.log"

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
check_trace "$temporary_root/immutable-cache-witness.json" ImmutableCacheWitness

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
check_trace "$temporary_root/object-retention-witness.json" ObjectRetentionWitness

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
check_trace "$temporary_root/replica-refresh-witness.json" ReplicaRefreshWitness

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
  check_trace "$temporary_root/snapshot-$snapshot_witness.json" "$snapshot_witness_module"
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
  check_trace "$temporary_root/snapshot-read-$snapshot_read_witness.json" "$snapshot_read_module"
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
  check_trace "$temporary_root/serializable-$serializable_witness.json" "$serializable_module"
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
check_trace "$temporary_root/range-normalization-witness.json" RangeNormalizationWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-range-normalization-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/RangeNormalizationSafetyProof.tla" \
  >"$temporary_root/tlaps-range-normalization.log" 2>&1
#  The structured initialization, successful-action, rejection-action, and
#  quiescence proofs establish the reviewed 19-obligation total.
grep -q 'All 19 obligations proved.' "$temporary_root/tlaps-range-normalization.log"

#  Four ordered one-byte keys, zero-to-two rows, and zero-to-five bytes are
#  finite qualification geometry for fixed-snapshot paging. They are not
#  database key/value limits or page defaults. The pinned graph also admits a
#  valid interval with no visible rows so successful empty completion is
#  nonvacuous without weakening endpoint validation.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-paged-scan-states" \
  -config PagedScan.cfg PagedScan \
  >"$temporary_root/tlc-paged-scan.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-paged-scan.log"
! grep -q '^Warning:' "$temporary_root/tlc-paged-scan.log"
grep -q '341 distinct states found' "$temporary_root/tlc-paged-scan.log"
grep -q 'The depth of the complete state graph search is 6.' \
  "$temporary_root/tlc-paged-scan.log"
for action in Begin ConcurrentAdvance ProducePage CompleteEmpty RejectCapacity \
  RejectAllocation
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-paged-scan.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-paged-scan-probe-states" \
  -config PagedScanProbe.cfg PagedScanProbe \
  >"$temporary_root/tlc-paged-scan-probe.log" 2>&1
paged_scan_probe_status=$?
set -e
test "$paged_scan_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-paged-scan-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-paged-scan-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-paged-scan-short-page-probe-states" \
  -config PagedScanShortPageProbe.cfg PagedScanShortPageProbe \
  >"$temporary_root/tlc-paged-scan-short-page-probe.log" 2>&1
paged_scan_short_page_probe_status=$?
set -e
test "$paged_scan_short_page_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-paged-scan-short-page-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-paged-scan-short-page-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-paged-scan-witness-states" \
  -config PagedScanWitness.cfg \
  -dumpTrace json "$temporary_root/paged-scan-witness.json" \
  PagedScanWitness \
  >"$temporary_root/tlc-paged-scan-witness.log" 2>&1
paged_scan_witness_status=$?
set -e
test "$paged_scan_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-paged-scan-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-paged-scan-witness.log"
check_trace "$temporary_root/paged-scan-witness.json" PagedScanWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-paged-scan-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/PagedScanSafetyProof.tla" \
  >"$temporary_root/tlaps-paged-scan.log" 2>&1
#  Initialization, four action families, and quiescence establish the reviewed
#  24-obligation total; this count changes only with the proof kernel.
grep -q 'All 24 obligations proved.' "$temporary_root/tlaps-paged-scan.log"

#  Three ordered keys and four already-sorted sources are finite qualification
#  geometry for an owned physical merge cursor. They are not run-count,
#  history, key/value, or page-size policy.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-physical-scan-merge-states" \
  -config PhysicalScanMerge.cfg PhysicalScanMerge \
  >"$temporary_root/tlc-physical-scan-merge.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-physical-scan-merge.log"
! grep -q '^Warning:' "$temporary_root/tlc-physical-scan-merge.log"
grep -q '21 distinct states found' \
  "$temporary_root/tlc-physical-scan-merge.log"
grep -q 'The depth of the complete state graph search is 6.' \
  "$temporary_root/tlc-physical-scan-merge.log"
for action in Begin ConcurrentChange AdvanceVisible AdvanceTombstone \
  RejectAllocation
do
  grep -Eq "^<$action .*: [1-9]" \
    "$temporary_root/tlc-physical-scan-merge.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-physical-scan-merge-probe-states" \
  -config PhysicalScanMergeProbe.cfg PhysicalScanMergeProbe \
  >"$temporary_root/tlc-physical-scan-merge-probe.log" 2>&1
physical_scan_merge_probe_status=$?
set -e
test "$physical_scan_merge_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-physical-scan-merge-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-physical-scan-merge-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-physical-scan-merge-winner-probe-states" \
  -config PhysicalScanMergeWinnerProbe.cfg PhysicalScanMergeWinnerProbe \
  >"$temporary_root/tlc-physical-scan-merge-winner-probe.log" 2>&1
physical_scan_merge_winner_probe_status=$?
set -e
test "$physical_scan_merge_winner_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-physical-scan-merge-winner-probe.log"
! grep -q '^Warning:' \
  "$temporary_root/tlc-physical-scan-merge-winner-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-physical-scan-merge-witness-states" \
  -config PhysicalScanMergeWitness.cfg \
  -dumpTrace json "$temporary_root/physical-scan-merge-witness.json" \
  PhysicalScanMergeWitness \
  >"$temporary_root/tlc-physical-scan-merge-witness.log" 2>&1
physical_scan_merge_witness_status=$?
set -e
test "$physical_scan_merge_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-physical-scan-merge-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-physical-scan-merge-witness.log"
check_trace "$temporary_root/physical-scan-merge-witness.json" PhysicalScanMergeWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-physical-scan-merge-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/PhysicalScanMergeSafetyProof.tla" \
  >"$temporary_root/tlaps-physical-scan-merge.log" 2>&1
#  Initialization, merge advance, allocation rejection, and quiescence prove
#  the reviewed 18-obligation abstract position/output kernel.
grep -q 'All 18 obligations proved.' \
  "$temporary_root/tlaps-physical-scan-merge.log"

#  Two keys, two generations, and four exact values are finite qualification
#  geometry for one generation-bound lazy SST entry read. They are not
#  key/value limits, format extents, cache capacities, or provider policy.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-lazy-sst-read-states" \
  -config LazySSTRead.cfg LazySSTRead \
  >"$temporary_root/tlc-lazy-sst-read.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-lazy-sst-read.log"
! grep -q '^Warning:' "$temporary_root/tlc-lazy-sst-read.log"
grep -q '16 distinct states found' "$temporary_root/tlc-lazy-sst-read.log"
grep -q 'The depth of the complete state graph search is 6.' \
  "$temporary_root/tlc-lazy-sst-read.log"
for action in Begin ReplaceObject ReadIndex ReadFrame PublishSuccess \
  RejectAllocation RejectStaleIndex RejectStaleFrame RejectCorruptIndex \
  RejectCorruptFrame
do
  grep -Eq "^<$action .*: [1-9]" "$temporary_root/tlc-lazy-sst-read.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lazy-sst-read-stale-probe-states" \
  -config LazySSTReadStaleProbe.cfg LazySSTReadStaleProbe \
  >"$temporary_root/tlc-lazy-sst-read-stale-probe.log" 2>&1
lazy_sst_read_stale_probe_status=$?
set -e
test "$lazy_sst_read_stale_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-lazy-sst-read-stale-probe.log"
! grep -q '^Warning:' "$temporary_root/tlc-lazy-sst-read-stale-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lazy-sst-read-frame-swap-probe-states" \
  -config LazySSTReadFrameSwapProbe.cfg LazySSTReadFrameSwapProbe \
  >"$temporary_root/tlc-lazy-sst-read-frame-swap-probe.log" 2>&1
lazy_sst_read_frame_swap_probe_status=$?
set -e
test "$lazy_sst_read_frame_swap_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-lazy-sst-read-frame-swap-probe.log"
! grep -q '^Warning:' \
  "$temporary_root/tlc-lazy-sst-read-frame-swap-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lazy-sst-read-witness-states" \
  -config LazySSTReadWitness.cfg \
  -dumpTrace json "$temporary_root/lazy-sst-read-witness.json" \
  LazySSTReadWitness \
  >"$temporary_root/tlc-lazy-sst-read-witness.log" 2>&1
lazy_sst_read_witness_status=$?
set -e
test "$lazy_sst_read_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-lazy-sst-read-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-lazy-sst-read-witness.log"
check_trace "$temporary_root/lazy-sst-read-witness.json" LazySSTReadWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-lazy-sst-read-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/LazySSTReadSafetyProof.tla" \
  >"$temporary_root/tlaps-lazy-sst-read.log" 2>&1
#  Initialization, five action families, and quiescence establish the
#  reviewed 41-obligation generation/binding/output kernel.
grep -q 'All 41 obligations proved.' \
  "$temporary_root/tlaps-lazy-sst-read.log"

#  Three canonical entries, two arbitrary-byte key ranks, two snapshots, and
#  the finite normalized bound modes are model geometry only. They are not
#  persisted limits, frame sizes, request budgets, or scan defaults.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 \
  -metadir "$temporary_root/tlc-lazy-sst-next-entry-states" \
  -config LazySSTNextEntry.cfg LazySSTNextEntry \
  >"$temporary_root/tlc-lazy-sst-next-entry.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-lazy-sst-next-entry.log"
! grep -q '^Warning:' "$temporary_root/tlc-lazy-sst-next-entry.log"
grep -q '75 states generated, 75 distinct states found, 0 states left on queue.' \
  "$temporary_root/tlc-lazy-sst-next-entry.log"
grep -q 'The depth of the complete state graph search is 5.' \
  "$temporary_root/tlc-lazy-sst-next-entry.log"
for action in BeginRequest SelectEntry ReadFrame PublishValue PublishTombstone \
  PublishAbsent RejectSelection RejectFrame
do
  grep -Eq "^<$action .*: [1-9]" \
    "$temporary_root/tlc-lazy-sst-next-entry.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lazy-sst-next-entry-skip-probe-states" \
  -config LazySSTNextEntrySkipProbe.cfg LazySSTNextEntrySkipProbe \
  >"$temporary_root/tlc-lazy-sst-next-entry-skip-probe.log" 2>&1
lazy_sst_next_entry_skip_probe_status=$?
set -e
test "$lazy_sst_next_entry_skip_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-lazy-sst-next-entry-skip-probe.log"
! grep -q '^Warning:' \
  "$temporary_root/tlc-lazy-sst-next-entry-skip-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-lazy-sst-next-entry-witness-states" \
  -config LazySSTNextEntryWitness.cfg \
  -dumpTrace json "$temporary_root/lazy-sst-next-entry-witness.json" \
  LazySSTNextEntryWitness \
  >"$temporary_root/tlc-lazy-sst-next-entry-witness.log" 2>&1
lazy_sst_next_entry_witness_status=$?
set -e
test "$lazy_sst_next_entry_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-lazy-sst-next-entry-witness.log"
! grep -q '^Warning:' "$temporary_root/tlc-lazy-sst-next-entry-witness.log"
check_trace \
  "$temporary_root/lazy-sst-next-entry-witness.json" \
  LazySSTNextEntryWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-lazy-sst-next-entry-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/LazySSTNextEntrySafetyProof.tla" \
  >"$temporary_root/tlaps-lazy-sst-next-entry.log" 2>&1
grep -q 'All 17 obligations proved.' \
  "$temporary_root/tlaps-lazy-sst-next-entry.log"

#  Three ordered runs, three keys, and three values are finite qualification
#  geometry for exact multi-run next-entry accumulation. They are not a run,
#  key, value, page, request, retry, or allocation limit.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 \
  -metadir "$temporary_root/tlc-authenticated-scan-initialization-states" \
  -config AuthenticatedScanInitialization.cfg AuthenticatedScanInitialization \
  >"$temporary_root/tlc-authenticated-scan-initialization.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
! grep -q '^Warning:' "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -q '25 states generated, 24 distinct states found, 0 states left on queue.' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -q 'The depth of the complete state graph search is 10.' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -Eq '^<Begin .*: 1:1$' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -Eq '^<ReadEntry .*: 4:4$' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -Eq '^<ReadAbsent .*: 2:2$' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -Eq '^<SkipFuture .*: 1:1$' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -Eq '^<PublishCursor .*: 1:1$' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -Eq '^<RejectRead .*: 7:7$' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"
grep -Eq '^<RejectAllocation .*: 7:8$' \
  "$temporary_root/tlc-authenticated-scan-initialization.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-authenticated-scan-initialization-skip-probe-states" \
  -config AuthenticatedScanInitializationSkipProbe.cfg \
  AuthenticatedScanInitializationSkipProbe \
  >"$temporary_root/tlc-authenticated-scan-initialization-skip-probe.log" 2>&1
authenticated_scan_initialization_skip_probe_status=$?
set -e
test "$authenticated_scan_initialization_skip_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-authenticated-scan-initialization-skip-probe.log"
! grep -q '^Warning:' \
  "$temporary_root/tlc-authenticated-scan-initialization-skip-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-authenticated-scan-initialization-witness-states" \
  -config AuthenticatedScanInitializationWitness.cfg \
  -dumpTrace json "$temporary_root/authenticated-scan-initialization-witness.json" \
  AuthenticatedScanInitializationWitness \
  >"$temporary_root/tlc-authenticated-scan-initialization-witness.log" 2>&1
authenticated_scan_initialization_witness_status=$?
set -e
test "$authenticated_scan_initialization_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-authenticated-scan-initialization-witness.log"
! grep -q '^Warning:' \
  "$temporary_root/tlc-authenticated-scan-initialization-witness.log"
check_trace \
  "$temporary_root/authenticated-scan-initialization-witness.json" \
  AuthenticatedScanInitializationWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-authenticated-scan-initialization-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/AuthenticatedScanInitializationSafetyProof.tla" \
  >"$temporary_root/tlaps-authenticated-scan-initialization.log" 2>&1
grep -q 'All 13 obligations proved.' \
  "$temporary_root/tlaps-authenticated-scan-initialization.log"

#  Three ordered runs, four keys, three live values, and page budgets zero
#  through two are finite qualification geometry. They are not run, key,
#  value, page, request, retry, cache, prefetch, or allocation limits.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 \
  -metadir "$temporary_root/tlc-storage-backed-paged-scan-states" \
  -config StorageBackedPagedScan.cfg StorageBackedPagedScan \
  >"$temporary_root/tlc-storage-backed-paged-scan.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
! grep -q '^Warning:' "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -q \
  '3341 states generated, 1111 distinct states found, 0 states left on queue.' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -q 'The depth of the complete state graph search is 20.' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<BeginPage .*: 63:2220$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<FetchHead .*: 189:250$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<SelectValue .*: 31:31$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<SelectTombstone .*: 44:44$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<PublishPage .*: 92:104$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<CompleteEmpty .*: 24:24$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<RejectCapacity .*: 13:13$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<RejectRead .*: 327:327$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"
grep -Eq '^<RejectAllocation .*: 327:327$' \
  "$temporary_root/tlc-storage-backed-paged-scan.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-storage-backed-paged-scan-skip-probe-states" \
  -config StorageBackedPagedScanSkipProbe.cfg StorageBackedPagedScanSkipProbe \
  >"$temporary_root/tlc-storage-backed-paged-scan-skip-probe.log" 2>&1
storage_backed_paged_scan_skip_probe_status=$?
set -e
test "$storage_backed_paged_scan_skip_probe_status" -eq 12
grep -q 'Invariant Safety is violated.' \
  "$temporary_root/tlc-storage-backed-paged-scan-skip-probe.log"
! grep -q '^Warning:' \
  "$temporary_root/tlc-storage-backed-paged-scan-skip-probe.log"

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-storage-backed-paged-scan-witness-states" \
  -config StorageBackedPagedScanWitness.cfg \
  -dumpTrace json "$temporary_root/storage-backed-paged-scan-witness.json" \
  StorageBackedPagedScanWitness \
  >"$temporary_root/tlc-storage-backed-paged-scan-witness.log" 2>&1
storage_backed_paged_scan_witness_status=$?
set -e
test "$storage_backed_paged_scan_witness_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' \
  "$temporary_root/tlc-storage-backed-paged-scan-witness.log"
! grep -q '^Warning:' \
  "$temporary_root/tlc-storage-backed-paged-scan-witness.log"
check_trace \
  "$temporary_root/storage-backed-paged-scan-witness.json" \
  StorageBackedPagedScanWitness

"$tlapm" --cache-dir "$temporary_root/tlapm-storage-backed-paged-scan-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/StorageBackedPagedScanSafetyProof.tla" \
  >"$temporary_root/tlaps-storage-backed-paged-scan.log" 2>&1
grep -q 'All 8 obligations proved.' \
  "$temporary_root/tlaps-storage-backed-paged-scan.log"

#  Three ordered runs, two keys, and four values are finite qualification
#  geometry for newest-visible fixed-snapshot selection. They are not a run
#  ceiling, key/value limit, request count, retry policy, or public default.
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 \
  -metadir "$temporary_root/tlc-lazy-checkpoint-read-states" \
  -config LazyCheckpointRead.cfg LazyCheckpointRead \
  >"$temporary_root/tlc-lazy-checkpoint-read.log" 2>&1
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-lazy-checkpoint-read.log"
! grep -q '^Warning:' "$temporary_root/tlc-lazy-checkpoint-read.log"
grep -q '37 distinct states found' \
  "$temporary_root/tlc-lazy-checkpoint-read.log"
grep -q 'The depth of the complete state graph search is 6.' \
  "$temporary_root/tlc-lazy-checkpoint-read.log"
for action in Begin SkipFuture ReadAbsent PublishValue PublishTombstone \
  PublishAbsent RejectRead
do
  grep -Eq "^<$action .*: [1-9]" \
    "$temporary_root/tlc-lazy-checkpoint-read.log"
done

"$tlapm" --cache-dir "$temporary_root/tlapm-lazy-checkpoint-read-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/LazyCheckpointReadSafetyProof.tla" \
  >"$temporary_root/tlaps-lazy-checkpoint-read.log" 2>&1
#  Initialization, exact-run advance, terminal publication/rejection, and
#  quiescence establish the reviewed 13-obligation arbitrary-domain kernel.
grep -q 'All 13 obligations proved.' \
  "$temporary_root/tlaps-lazy-checkpoint-read.log"

if test "${FLYOLOGY_DB_TLA_UPDATE_TRACES:-0}" = 1
then
  for normalized_trace in "$temporary_root"/*.trace.json
  do
    cp "$normalized_trace" "$trace_root/$(basename "$normalized_trace")"
  done
fi

printf '%s\n' "Flyology.DB TLA+ checks passed"
printf '%s\n' "  TLC   112031 distinct states, depth 14"
printf '%s\n' "  TLAPS 23/23 obligations"
printf '%s\n' "  Negative stale-publication probe detected"
printf '%s\n' "  Negative overlapping-transaction ownership probe detected"
printf '%s\n' "  Deep committed/failed reconciliation traces canonical"
printf '%s\n' "  Canonical pooled accepted-response loss, reconciliation, crash, recovery trace"
printf '%s\n' "  Manifest TLC 286 distinct states, depth 10"
printf '%s\n' "  Manifest TLAPS 12/12 obligations"
printf '%s\n' "  Manifest committed/failed reconciliation traces canonical"
printf '%s\n' "  Negative manifest registry-mutation probe detected"
printf '%s\n' "  Checkpoint TLC 819 distinct states, depth 19"
printf '%s\n' "  Checkpoint TLAPS 43/43 obligations"
printf '%s\n' "  Checkpoint committed/rejected/recovery traces canonical"
printf '%s\n' "  Negative checkpoint stale/partial/family/ledger probes detected"
printf '%s\n' "  Successive checkpoint TLC 37 distinct states, depth 17"
printf '%s\n' "  Successive checkpoint TLAPS 24/24 obligations"
printf '%s\n' "  Successive checkpoint lost-response recovery trace canonical"
printf '%s\n' "  Negative successive-checkpoint early-HEAD probe detected"
printf '%s\n' "  L0 checkpoint selection TLC 2240 distinct states, depth 2"
printf '%s\n' "  L0 checkpoint selection TLAPS 8/8 obligations"
printf '%s\n' "  L0 checkpoint four-outcome traces replayed against Ada policy"
printf '%s\n' "  L0 checkpoint intentional implementation divergence detected"
printf '%s\n' "  Additive L0 TLC 49 distinct states, depth 17"
printf '%s\n' "  Additive L0 TLAPS 24/24 obligations"
printf '%s\n' "  Additive L0 tombstone/lost-response recovery trace canonical"
printf '%s\n' "  Negative additive-L0 early-HEAD probe detected"
printf '%s\n' "  L0 compaction TLC 35 distinct states, depth 10"
printf '%s\n' "  L0 compaction TLAPS 26/26 obligations"
printf '%s\n' "  L0 compaction lost-response recovery trace canonical"
printf '%s\n' "  L0 empty-output lost-response recovery trace canonical"
printf '%s\n' "  Negative L0-compaction early-HEAD probe detected"
printf '%s\n' "  LSM read equivalence TLC 576 distinct states, depth 4"
printf '%s\n' "  LSM read equivalence TLAPS 6/6 obligations"
printf '%s\n' "  LSM replacement/delete/replay trace canonical"
printf '%s\n' "  Negative omitted-live-key replacement probe detected"
printf '%s\n' "  Partial LSM merge TLC 3145728 distinct states, depth 3"
printf '%s\n' "  Partial LSM merge TLAPS 5/5 obligations"
printf '%s\n' "  Partial LSM older/selected/newer/suffix merge trace canonical"
printf '%s\n' "  Negative dropped-tombstone partial-merge probe detected"
printf '%s\n' "  Three-run LSM merge TLC 12288 distinct states, depth 3"
printf '%s\n' "  Three-run LSM merge TLAPS 7/7 obligations"
printf '%s\n' "  Three-run middle-tombstone/suffix trace canonical"
printf '%s\n' "  Negative dropped-middle-tombstone probe detected"
printf '%s\n' "  Immutable cache TLC 623 distinct states, depth 12"
printf '%s\n' "  Immutable cache TLAPS 13/13 obligations"
printf '%s\n' "  Cache coalescing/loss/corruption trace canonical"
printf '%s\n' "  Negative stale-generation cache probe detected"
printf '%s\n' "  Object retention TLC 75337 distinct states, depth 16"
printf '%s\n' "  Object retention TLAPS 15/15 obligations"
printf '%s\n' "  Snapshot/replica/predecessor/unknown retention trace canonical"
printf '%s\n' "  Negative listing-only deletion probe detected"
printf '%s\n' "  Replica refresh TLC 1460 distinct states, depth 15"
printf '%s\n' "  Replica refresh TLAPS 11/11 obligations"
printf '%s\n' "  Fencing/lagging-refresh/catch-up trace canonical"
printf '%s\n' "  Negative stale-writer and replica-rollback probes detected"
printf '%s\n' "  Snapshot isolation TLC 336 distinct states, depth 10"
printf '%s\n' "  Snapshot isolation TLAPS 6/6 obligations"
printf '%s\n' "  Snapshot conflict/disjoint/checkpoint traces canonical"
printf '%s\n' "  Negative unsafe snapshot commit probe detected"
printf '%s\n' "  Snapshot reads TLC 7530 distinct states, depth 14"
printf '%s\n' "  Snapshot reads TLAPS 7/7 obligations"
printf '%s\n' "  Snapshot old/own/too-old traces canonical"
printf '%s\n' "  Negative latest-value snapshot read probe detected"
printf '%s\n' "  Serializable validation TLC 44244 distinct states, depth 13"
printf '%s\n' "  Serializable validation TLAPS 10/10 obligations"
printf '%s\n' "  Serializable point/range/snapshot/own traces canonical"
printf '%s\n' "  Negative unsafe serializable commit probe detected"
printf '%s\n' "  Range normalization TLC 3419 distinct states, depth 4"
printf '%s\n' "  Range normalization TLAPS 19/19 obligations"
printf '%s\n' "  Bridge/cross-family/capacity/allocation trace canonical"
printf '%s\n' "  Negative incomplete-bridge normalization probe detected"
printf '%s\n' "  Paged scan TLC 341 distinct states, depth 6"
printf '%s\n' "  Paged scan TLAPS 24/24 obligations"
printf '%s\n' "  Frozen-page/capacity/allocation/concurrent trace canonical"
printf '%s\n' "  Negative skipped-key page probe detected"
printf '%s\n' "  Negative nonmaximal page probe detected"
printf '%s\n' "  Physical scan merge TLC 21 distinct states, depth 6"
printf '%s\n' "  Physical scan merge TLAPS 18/18 obligations"
printf '%s\n' "  Owned merge/tombstone/concurrent trace canonical"
printf '%s\n' "  Negative partial-advance and stale-winner probes detected"
printf '%s\n' "  Lazy SST read TLC 16 distinct states, depth 6"
printf '%s\n' "  Lazy SST read TLAPS 41/41 obligations"
printf '%s\n' "  Lazy SST next-entry TLC 75 distinct states, depth 5"
printf '%s\n' "  Lazy SST next-entry TLAPS 17/17 obligations"
printf '%s\n' "  Historical tombstone selection trace canonical"
printf '%s\n' "  Negative skipped-first-visible-entry probe detected"
printf '%s\n' "  Authenticated scan initialization TLC 24 distinct states, depth 10"
printf '%s\n' "  Authenticated scan initialization TLAPS 13/13 obligations"
printf '%s\n' "  Exact accumulated-source publication trace canonical"
printf '%s\n' "  Negative skipped-entry initialization probe detected"
printf '%s\n' "  Storage-backed paged scan TLC 1111 distinct states, depth 20"
printf '%s\n' "  Storage-backed paged scan TLAPS 8/8 obligations"
printf '%s\n' "  One-head-per-run page continuation trace canonical"
printf '%s\n' "  Negative skipped-visible-row probe detected"
printf '%s\n' "  Lazy checkpoint selector TLC 37 distinct states, depth 6"
printf '%s\n' "  Lazy checkpoint selector TLAPS 13/13 obligations"
printf '%s\n' "  Generation-bound allocation/replacement trace canonical"
printf '%s\n' "  Negative stale-generation and frame-swap probes detected"
