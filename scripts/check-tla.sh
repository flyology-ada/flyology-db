#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
toolchain_root="$project_root/.deps/flyology-tla-toolchain"
tla_cli="$project_root/.deps/flyology-tla-cli/bin/flyology-tla"
model_root="$project_root/formal/tla"
trace_root="$model_root/traces"
trace_update_mode=${FLYOLOGY_DB_TLA_UPDATE_TRACES:-0}

test -x "$tla_cli"
"$tla_cli" toolchain verify "$toolchain_root"
set +e
toolchain_environment=$("$tla_cli" toolchain env "$toolchain_root")
toolchain_environment_status=$?
set -e
if test "$toolchain_environment_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA toolchain environment exited $toolchain_environment_status" >&2
  exit "$toolchain_environment_status"
fi
eval "$toolchain_environment"
java_command=$FLYOLOGY_TLA_JAVA
tlc_jar=$FLYOLOGY_TLA_TLC_JAR
tlapm=$FLYOLOGY_TLAPM
toolchain_identity=tla2tools-1.8.0+9787e65

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-tla.XXXXXX")
trace_update_staging=

cleanup() {
  if test -n "$trace_update_staging"
  then
    case "$trace_update_staging" in
      "$trace_root"/.flyology-db-trace.*)
        rm -f -- "$trace_update_staging"
        ;;
      *)
        printf '%s\n' "Flyology.DB TLA refused unsafe staging cleanup" >&2
        ;;
    esac
  fi
  rm -rf "$temporary_root"
}

trap cleanup EXIT HUP INT TERM

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1
  then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_trace_inventory() {
  trace_inventory_output=$1
  test -d "$trace_root"
  test ! -L "$trace_root"
  if find "$trace_root" -mindepth 1 \
    \( ! -type f -o ! -name '*.trace.json' \) -print | grep -q .
  then
    printf '%s\n' "Flyology.DB TLA trace inventory has an unexpected path" >&2
    exit 1
  fi
  if find "$trace_root" -name '.flyology-db-trace.*' -print | grep -q .
  then
    printf '%s\n' "Flyology.DB TLA trace inventory contains staging residue" >&2
    exit 1
  fi
  (
    cd "$trace_root"
    find . -type f -name '*.trace.json' -print | LC_ALL=C sort |
      while IFS= read -r trace_file
      do
        trace_relative=${trace_file#./}
        trace_hash=$(sha256_file "$trace_relative")
        printf '%s  %s\n' "$trace_hash" "$trace_relative"
      done
  ) >"$trace_inventory_output"
}

install_trace_no_clobber() {
  normalized_trace=$1
  canonical_trace=$2
  trace_module=$3
  trace_update_staging=$(mktemp "$trace_root/.flyology-db-trace.$trace_module.XXXXXX")
  case "$trace_update_staging" in
    "$trace_root"/.flyology-db-trace."$trace_module".*)
      ;;
    *)
      printf '%s\n' "Flyology.DB TLA created an unsafe staging path" >&2
      exit 1
      ;;
  esac
  test -f "$trace_update_staging"
  test ! -L "$trace_update_staging"
  cp -p "$normalized_trace" "$trace_update_staging"
  cmp "$normalized_trace" "$trace_update_staging"
  ln "$trace_update_staging" "$canonical_trace"
  rm -f -- "$trace_update_staging"
  trace_update_staging=
}

if test "$trace_update_mode" = 1
then
  trace_inventory_before="$temporary_root/trace-inventory.before"
  write_trace_inventory "$trace_inventory_before"
fi

check_trace() {
  raw_trace=$1
  module=$2
  normalized_trace="$temporary_root/$module.trace.json"
  "$tla_cli" trace normalize \
    "$raw_trace" "$normalized_trace" "$model_root/$module.tla" \
    --config "$model_root/$module.cfg" --toolchain "$toolchain_identity" 128 64
  "$tla_cli" trace validate "$normalized_trace" 128 64
  canonical_trace="$trace_root/$module.trace.json"
  if test -e "$canonical_trace" || test -L "$canonical_trace"
  then
    test -f "$canonical_trace"
    test ! -L "$canonical_trace"
    cmp "$normalized_trace" "$canonical_trace"
  elif test "$trace_update_mode" = 1
  then
    case "$module" in
      LiveSuffixRegistryRecoveryWitness|LiveSuffixRegistryCancellationWitness|\
      AggregateCommitCoalescingAuthorityReplay)
        ;;
      *)
        printf '%s\n' \
          "Flyology.DB TLA update rejected unexpected absent trace: $module" >&2
        exit 1
        ;;
    esac
  else
    cmp "$normalized_trace" "$canonical_trace"
  fi
}

trace_path() {
  module=$1
  if test "$trace_update_mode" = 1
  then
    printf '%s\n' "$temporary_root/$module.trace.json"
  else
    printf '%s\n' "$trace_root/$module.trace.json"
  fi
}

cd "$model_root"
set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-safety-states" \
  -config CommitPublication.cfg CommitPublication \
  >"$temporary_root/tlc-safety.log" 2>&1
commit_publication_tlc_status=$?
set -e
if test "$commit_publication_tlc_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA CommitPublication positive TLC exited $commit_publication_tlc_status" \
    >&2
  cat "$temporary_root/tlc-safety.log" >&2
  exit "$commit_publication_tlc_status"
fi
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-safety.log"
! grep -q '^Warning:' "$temporary_root/tlc-safety.log"
commit_publication_state_lines=$(grep -E \
  '^[1-9][0-9]* states generated, [1-9][0-9]* distinct states found, 0 states left on queue[.]$' \
  "$temporary_root/tlc-safety.log" || :)
test "$(printf '%s\n' "$commit_publication_state_lines" | wc -l | tr -d ' ')" -eq 1
commit_publication_generated=$(printf '%s\n' "$commit_publication_state_lines" | awk '{print $1}')
commit_publication_states=$(printf '%s\n' "$commit_publication_state_lines" | awk '{print $4}')
commit_publication_depth_lines=$(grep -E \
  '^The depth of the complete state graph search is [1-9][0-9]*[.]$' \
  "$temporary_root/tlc-safety.log" || :)
test "$(printf '%s\n' "$commit_publication_depth_lines" | wc -l | tr -d ' ')" -eq 1
commit_publication_depth=$(printf '%s\n' "$commit_publication_depth_lines" | \
  sed 's/^The depth of the complete state graph search is \([1-9][0-9]*\)[.]$/\1/')
if test "$commit_publication_generated/$commit_publication_states/$commit_publication_depth" \
  != '2988725/446309/19'
then
  printf '%s\n' \
    'Flyology.DB TLA CommitPublication state geometry changed:' \
    "$commit_publication_state_lines" \
    "$commit_publication_depth_lines" >&2
  exit 1
fi
commit_publication_final_coverage="$temporary_root/commit-publication-final-coverage.txt"
if ! awk '
  /^Model checking completed\. No error has been found\.$/ {
    completed++
    next
  }
  /^The coverage statistics at / {
    if (completed == 0) {
      next
    }
    if (completed != 1 || capture || reports != 0) {
      invalid = 1
      next
    }
    block = ""
    capture = 1
    reports++
  }
  capture {
    block = block $0 ORS
  }
  capture && /^End of statistics/ {
    final = block
    capture = 0
  }
  END {
    if (invalid || completed != 1 || reports != 1 || capture || final == "") {
      exit 1
    }
    printf "%s", final
  }
' "$temporary_root/tlc-safety.log" >"$commit_publication_final_coverage"
then
  printf '%s\n' \
    'Flyology.DB TLA CommitPublication final coverage report missing or incomplete' >&2
  exit 1
fi
commit_publication_action_report="$temporary_root/commit-publication-action-coverage.txt"
: >"$commit_publication_action_report"
for action in PrepareGroup PreparePooled StoreBatch PublishHead ObserveSuccess \
  LoseAcceptedResponse LoseUnacceptedResponse ObservePreconditionFailure \
  ResolveCommitted ResolvePreconditionFailure ExportAuthority ImportAuthority \
  RejectMalformedAuthority AcquireWriter Crash Recover
do
  commit_publication_action_lines=$(grep -E "^<$action " \
    "$commit_publication_final_coverage" || :)
  if test -z "$commit_publication_action_lines"
  then
    printf '%s\n' \
      "Flyology.DB TLA CommitPublication action $action failed: missing" >&2
    exit 1
  fi
  commit_publication_action_unique_lines=$(
    printf '%s\n' "$commit_publication_action_lines" |
      LC_ALL=C sort -u
  )
  if test "$(printf '%s\n' "$commit_publication_action_unique_lines" | \
    wc -l | tr -d ' ')" -ne 1
  then
    printf '%s\n' \
      "Flyology.DB TLA CommitPublication action $action failed: duplicate or ambiguous" \
      >&2
    printf '%s\n' "$commit_publication_action_lines" >&2
    exit 1
  fi
  if ! printf '%s\n' "$commit_publication_action_unique_lines" |
    grep -Eq "^<$action .*: [0-9][0-9]*(:[0-9]+)?$"
  then
    printf '%s\n' \
      "Flyology.DB TLA CommitPublication action $action failed: malformed or nonnumeric" \
      >&2
    printf '%s\n' "$commit_publication_action_lines" >&2
    exit 1
  fi
  commit_publication_action_counts=${commit_publication_action_unique_lines##*: }
  commit_publication_action_count=${commit_publication_action_counts%%:*}
  case "$commit_publication_action_count" in
    ''|*[!0-9]*)
      printf '%s\n' \
        "Flyology.DB TLA CommitPublication action $action failed: malformed or nonnumeric" \
        >&2
      printf '%s\n' "$commit_publication_action_lines" >&2
      exit 1
      ;;
    0*)
      printf '%s\n' \
        "Flyology.DB TLA CommitPublication action $action failed: zero coverage" >&2
      printf '%s\n' "$commit_publication_action_lines" >&2
      exit 1
      ;;
  esac
  printf '    %s %s\n' "$action" "$commit_publication_action_count" \
    >>"$commit_publication_action_report"
done
commit_publication_expected_action_report="$temporary_root/commit-publication-action-coverage.expected.txt"
cat >"$commit_publication_expected_action_report" <<'EOF'
    PrepareGroup 3510
    PreparePooled 10
    StoreBatch 7080
    PublishHead 6012
    ObserveSuccess 29112
    LoseAcceptedResponse 29112
    LoseUnacceptedResponse 16076
    ObservePreconditionFailure 10216
    ResolveCommitted 68488
    ResolvePreconditionFailure 25172
    ExportAuthority 43352
    ImportAuthority 21402
    RejectMalformedAuthority 41152
    AcquireWriter 50346
    Crash 19698
    Recover 75570
EOF
if ! cmp "$commit_publication_expected_action_report" \
  "$commit_publication_action_report"
then
  printf '%s\n' 'Flyology.DB TLA CommitPublication action coverage changed:' >&2
  cat "$commit_publication_action_report" >&2
  exit 1
fi

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

for resolution in accepted rejected
do
  if test "$resolution" = accepted
  then
    authority_witness_module=CommitResolutionAuthorityAcceptedWitness
    authority_witness_invariant=AcceptedImportPending
  else
    authority_witness_module=CommitResolutionAuthorityRejectedWitness
    authority_witness_invariant=RejectedImportPending
  fi
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-commit-authority-$resolution-states" \
    -config "$authority_witness_module.cfg" "$authority_witness_module" \
    >"$temporary_root/tlc-commit-authority-$resolution.log" 2>&1
  authority_witness_status=$?
  set -e
  test "$authority_witness_status" -eq 12
  grep -q "Invariant $authority_witness_invariant is violated." \
    "$temporary_root/tlc-commit-authority-$resolution.log"
  ! grep -q '^Warning:' "$temporary_root/tlc-commit-authority-$resolution.log"
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-commit-authority-swap-states" \
  -config CommitResolutionAuthoritySwapProbe.cfg \
  CommitResolutionAuthoritySwapProbe \
  >"$temporary_root/tlc-commit-authority-swap.log" 2>&1
authority_swap_status=$?
set -e
test "$authority_swap_status" -eq 12
grep -q 'Invariant MalformedImportIsNoOp is violated.' \
  "$temporary_root/tlc-commit-authority-swap.log"
! grep -q '^Warning:' "$temporary_root/tlc-commit-authority-swap.log"

set +e
"$tlapm" --cache-dir "$temporary_root/tlapm-commit-authority-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/CommitResolutionAuthoritySafetyProof.tla" \
  >"$temporary_root/tlaps-commit-authority.log" 2>&1
commit_authority_tlaps_status=$?
set -e
if test "$commit_authority_tlaps_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA durable commit authority TLAPS exited $commit_authority_tlaps_status" \
    >&2
  cat "$temporary_root/tlaps-commit-authority.log" >&2
  exit "$commit_authority_tlaps_status"
fi
commit_authority_tlaps_summary=$(grep -E \
  '^(\[INFO\]: )?All [0-9][0-9]* obligations proved[.]$' \
  "$temporary_root/tlaps-commit-authority.log" || :)
if test "$commit_authority_tlaps_summary" != 'All 10 obligations proved.' && \
  test "$commit_authority_tlaps_summary" != '[INFO]: All 10 obligations proved.'
then
  printf '%s\n' \
    'Flyology.DB TLA durable commit authority TLAPS summary missing or malformed' >&2
  cat "$temporary_root/tlaps-commit-authority.log" >&2
  exit 1
fi
if grep -q '^Warning:' "$temporary_root/tlaps-commit-authority.log"
then
  printf '%s\n' 'Flyology.DB TLA durable commit authority TLAPS warning emitted' >&2
  cat "$temporary_root/tlaps-commit-authority.log" >&2
  exit 1
fi

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

successive_checkpoint_fail_with_log() {
  successive_checkpoint_failure=$1
  printf '%s\n' \
    "Flyology.DB TLA successive-checkpoint TLAPS failed: $successive_checkpoint_failure" \
    >&2
  cat "$temporary_root/tlaps-successive-checkpoint.log" >&2
  exit 1
}

set +e
"$tlapm" --cache-dir "$temporary_root/tlapm-successive-checkpoint-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/SuccessiveCheckpointSafetyProof.tla" \
  >"$temporary_root/tlaps-successive-checkpoint.log" 2>&1
successive_checkpoint_tlaps_status=$?
set -e
if test "$successive_checkpoint_tlaps_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA successive-checkpoint TLAPS exited $successive_checkpoint_tlaps_status" \
    >&2
  cat "$temporary_root/tlaps-successive-checkpoint.log" >&2
  exit "$successive_checkpoint_tlaps_status"
fi
successive_checkpoint_obligation_lines=$(
  grep -E 'All [0-9][0-9]* obligations proved[.]' \
    "$temporary_root/tlaps-successive-checkpoint.log" || :
)
if test "$successive_checkpoint_obligation_lines" != \
  'All 24 obligations proved.' && \
  test "$successive_checkpoint_obligation_lines" != \
    '[INFO]: All 24 obligations proved.'
then
  successive_checkpoint_fail_with_log "obligation summary missing or malformed"
fi
if grep -q '^Warning:' "$temporary_root/tlaps-successive-checkpoint.log"
then
  successive_checkpoint_fail_with_log "warning emitted"
fi

#  One checkpoint identity and one two-member suffix are finite qualification
#  geometry. This lane checks that a registry successor carries their exact
#  disjoint partition, fences on conclusive HEAD, and recovers by the same
#  receipt without replaying a provider mutation.
live_suffix_fail_with_log() {
  live_suffix_failure=$1
  printf '%s\n' \
    "Flyology.DB TLA live-suffix positive lane failed: $live_suffix_failure" \
    >&2
  cat "$temporary_root/tlc-live-suffix-registry.log" >&2
  exit 1
}

live_suffix_fail_field() {
  live_suffix_field=$1
  live_suffix_failure=$2
  live_suffix_source_lines=${3-}
  printf '%s\n' \
    "Flyology.DB TLA live-suffix $live_suffix_field failed: $live_suffix_failure" \
    >&2
  if test -n "$live_suffix_source_lines"
  then
    printf '%s\n' "$live_suffix_source_lines" >&2
  fi
  exit 1
}

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 \
  -metadir "$temporary_root/tlc-live-suffix-registry-states" \
  -config LiveSuffixRegistryPublication.cfg LiveSuffixRegistryPublication \
  >"$temporary_root/tlc-live-suffix-registry.log" 2>&1
live_suffix_tlc_status=$?
set -e
if test "$live_suffix_tlc_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA live-suffix positive TLC exited $live_suffix_tlc_status" \
    >&2
  cat "$temporary_root/tlc-live-suffix-registry.log" >&2
  exit "$live_suffix_tlc_status"
fi
if ! grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-live-suffix-registry.log"
then
  live_suffix_fail_with_log "completion sentinel missing"
fi
if grep -q '^Warning:' "$temporary_root/tlc-live-suffix-registry.log"
then
  live_suffix_fail_with_log "warning emitted"
fi

live_suffix_state_source_lines=$(
  grep 'distinct states found' \
    "$temporary_root/tlc-live-suffix-registry.log" || :
)
if test -z "$live_suffix_state_source_lines"
then
  live_suffix_fail_field "state count" "missing"
fi
live_suffix_state_lines=$(
  printf '%s\n' "$live_suffix_state_source_lines" |
    grep -E \
      '^[0-9][0-9]* states generated, [0-9][0-9]* distinct states found, 0 states left on queue[.]$' || :
)
if test -z "$live_suffix_state_lines"
then
  live_suffix_fail_field \
    "state count" "malformed final summary" "$live_suffix_state_source_lines"
fi
if test "$(printf '%s\n' "$live_suffix_state_lines" | wc -l | tr -d ' ')" \
  -ne 1
then
  live_suffix_fail_field \
    "state count" "duplicate or ambiguous" "$live_suffix_state_lines"
fi
live_suffix_registry_generated=$(
  printf '%s\n' "$live_suffix_state_lines" | awk '{print $1}'
)
live_suffix_registry_states=$(
  printf '%s\n' "$live_suffix_state_lines" | awk '{print $4}'
)
case "$live_suffix_registry_generated" in
  ''|*[!0-9]*)
    live_suffix_fail_field \
      "generated state count" "malformed or nonnumeric" "$live_suffix_state_lines"
    ;;
esac
case "$live_suffix_registry_states" in
  ''|*[!0-9]*)
    live_suffix_fail_field \
      "state count" "malformed or nonnumeric" "$live_suffix_state_lines"
    ;;
esac
if test "$live_suffix_registry_generated" -ne 26
then
  live_suffix_fail_field \
    "generated state count" \
    "expected 26, observed $live_suffix_registry_generated" \
    "$live_suffix_state_lines"
fi
if test "$live_suffix_registry_states" -ne 18
then
  live_suffix_fail_field \
    "distinct state count" \
    "expected 18, observed $live_suffix_registry_states" \
    "$live_suffix_state_lines"
fi

live_suffix_depth_source_lines=$(
  grep 'depth of the complete state graph search is' \
    "$temporary_root/tlc-live-suffix-registry.log" || :
)
if test -z "$live_suffix_depth_source_lines"
then
  live_suffix_fail_field "state depth" "missing"
fi
live_suffix_depth_lines=$(
  printf '%s\n' "$live_suffix_depth_source_lines" |
    grep -E \
      '^The depth of the complete state graph search is [0-9][0-9]*[.]$' || :
)
if test -z "$live_suffix_depth_lines"
then
  live_suffix_fail_field \
    "state depth" "malformed" "$live_suffix_depth_source_lines"
fi
if test "$(printf '%s\n' "$live_suffix_depth_lines" | wc -l | tr -d ' ')" \
  -ne 1
then
  live_suffix_fail_field \
    "state depth" "duplicate or ambiguous" "$live_suffix_depth_lines"
fi
live_suffix_registry_depth=$(
  printf '%s\n' "$live_suffix_depth_lines" |
    sed -n \
      's/^The depth of the complete state graph search is \([0-9][0-9]*\)[.]$/\1/p'
)
case "$live_suffix_registry_depth" in
  ''|*[!0-9]*)
    live_suffix_fail_field \
      "state depth" "malformed or nonnumeric" "$live_suffix_depth_lines"
    ;;
esac
if test "$live_suffix_registry_depth" -ne 9
then
  live_suffix_fail_field \
    "state depth" \
    "expected 9, observed $live_suffix_registry_depth" \
    "$live_suffix_depth_lines"
fi

live_suffix_action_report="$temporary_root/live-suffix-action-coverage.txt"
: >"$live_suffix_action_report"
for action in CommitSuffixGroup SnapshotPartition BeginFamilyAppend \
  StoreAppendManifest ConfirmAppendManifest PublishAppendHead \
  LoseAcceptedManifestResponse ResolveManifestByRead \
  LoseAcceptedHeadResponse ObserveHeadPreconditionFailure \
  ExternalPublishRival ResolveCommitted \
  ResolveRejected CancelAfterHead FailLocalActivation RecoverActivation
do
  live_suffix_action_lines=$(
    grep -E "^<$action " \
      "$temporary_root/tlc-live-suffix-registry.log" || :
  )
  if test -z "$live_suffix_action_lines"
  then
    live_suffix_fail_field "action $action" "missing"
  fi
  if test "$(printf '%s\n' "$live_suffix_action_lines" | wc -l | tr -d ' ')" \
    -ne 1
  then
    live_suffix_fail_field \
      "action $action" "duplicate or ambiguous" "$live_suffix_action_lines"
  fi
  if ! printf '%s\n' "$live_suffix_action_lines" |
    grep -Eq "^<$action .*: [0-9][0-9]*(:[0-9]+)?$"
  then
    live_suffix_fail_field \
      "action $action" "malformed or nonnumeric" "$live_suffix_action_lines"
  fi
  live_suffix_action_counts=${live_suffix_action_lines##*: }
  live_suffix_action_count=${live_suffix_action_counts%%:*}
  case "$live_suffix_action_count" in
    ''|*[!0-9]*)
      live_suffix_fail_field \
        "action $action" "malformed or nonnumeric" "$live_suffix_action_lines"
      ;;
    0)
      live_suffix_fail_field \
        "action $action" "zero coverage" "$live_suffix_action_lines"
      ;;
  esac
  printf '    %s %s\n' "$action" "$live_suffix_action_count" \
    >>"$live_suffix_action_report"
done
live_suffix_expected_action_report="$temporary_root/live-suffix-action-coverage.expected.txt"
{
  printf '%s\n' \
    '    CommitSuffixGroup 1' \
    '    SnapshotPartition 1' \
    '    BeginFamilyAppend 1' \
    '    StoreAppendManifest 1' \
    '    ConfirmAppendManifest 1' \
    '    PublishAppendHead 1' \
    '    LoseAcceptedManifestResponse 1' \
    '    ResolveManifestByRead 1' \
    '    LoseAcceptedHeadResponse 1' \
    '    ObserveHeadPreconditionFailure 1' \
    '    ExternalPublishRival 1' \
    '    ResolveCommitted 1' \
    '    ResolveRejected 1' \
    '    CancelAfterHead 1' \
    '    FailLocalActivation 1' \
    '    RecoverActivation 2'
} >"$live_suffix_expected_action_report"
if ! cmp -s \
  "$live_suffix_expected_action_report" "$live_suffix_action_report"
then
  printf '%s\n' \
    'Flyology.DB TLA live-suffix action coverage differs from the retained geometry' >&2
  printf '%s\n' 'Expected action coverage:' >&2
  cat "$live_suffix_expected_action_report" >&2
  printf '%s\n' 'Observed action coverage:' >&2
  cat "$live_suffix_action_report" >&2
  exit 1
fi

for live_suffix_probe in partition confirmed-head manifest-replay replay rival
do
  case "$live_suffix_probe" in
    partition)
      live_suffix_probe_module=LiveSuffixRegistryPartitionProbe
      live_suffix_probe_invariant=CapturedPartitionIsExact
      ;;
    confirmed-head)
      live_suffix_probe_module=LiveSuffixRegistryConfirmedHeadProbe
      live_suffix_probe_invariant=ConfirmedHeadImpliesFenced
      ;;
    manifest-replay)
      live_suffix_probe_module=LiveSuffixRegistryManifestReplayProbe
      live_suffix_probe_invariant=ManifestResolutionDoesNotReplay
      ;;
    replay)
      live_suffix_probe_module=LiveSuffixRegistryReplayProbe
      live_suffix_probe_invariant=ResolutionDoesNotReplay
      ;;
    rival)
      live_suffix_probe_module=LiveSuffixRegistryRivalProbe
      live_suffix_probe_invariant=RivalCannotResolveCommitted
      ;;
  esac
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-live-suffix-$live_suffix_probe-states" \
    -config "$live_suffix_probe_module.cfg" "$live_suffix_probe_module" \
    >"$temporary_root/tlc-live-suffix-$live_suffix_probe.log" 2>&1
  live_suffix_probe_status=$?
  set -e
  test "$live_suffix_probe_status" -eq 12
  grep -q "Invariant $live_suffix_probe_invariant is violated" \
    "$temporary_root/tlc-live-suffix-$live_suffix_probe.log"
  ! grep -q '^Warning:' \
    "$temporary_root/tlc-live-suffix-$live_suffix_probe.log"
done

for live_suffix_witness in recovery cancellation
do
  case "$live_suffix_witness" in
    recovery)
      live_suffix_witness_module=LiveSuffixRegistryRecoveryWitness
      ;;
    cancellation)
      live_suffix_witness_module=LiveSuffixRegistryCancellationWitness
      ;;
  esac
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-live-suffix-$live_suffix_witness-states" \
    -config "$live_suffix_witness_module.cfg" \
    -dumpTrace json \
    "$temporary_root/live-suffix-$live_suffix_witness.json" \
    "$live_suffix_witness_module" \
    >"$temporary_root/tlc-live-suffix-$live_suffix_witness.log" 2>&1
  live_suffix_witness_status=$?
  set -e
  test "$live_suffix_witness_status" -eq 12
  grep -q 'Invariant WitnessPending is violated.' \
    "$temporary_root/tlc-live-suffix-$live_suffix_witness.log"
  ! grep -q '^Warning:' \
    "$temporary_root/tlc-live-suffix-$live_suffix_witness.log"
  check_trace \
    "$temporary_root/live-suffix-$live_suffix_witness.json" \
    "$live_suffix_witness_module"
done

live_suffix_tlaps_fail_with_log() {
  live_suffix_tlaps_failure=$1
  printf '%s\n' \
    "Flyology.DB TLA live-suffix TLAPS failed: $live_suffix_tlaps_failure" >&2
  cat "$temporary_root/tlaps-live-suffix-registry.log" >&2
  exit 1
}

set +e
"$tlapm" --cache-dir "$temporary_root/tlapm-live-suffix-registry-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/LiveSuffixRegistryPublicationSafetyProof.tla" \
  >"$temporary_root/tlaps-live-suffix-registry.log" 2>&1
live_suffix_tlaps_status=$?
set -e
if test "$live_suffix_tlaps_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA live-suffix TLAPS exited $live_suffix_tlaps_status" >&2
  cat "$temporary_root/tlaps-live-suffix-registry.log" >&2
  exit "$live_suffix_tlaps_status"
fi
live_suffix_tlaps_lines=$(
  grep -E '^(\[INFO\]: )?All [1-9][0-9]* obligations proved[.]$' \
    "$temporary_root/tlaps-live-suffix-registry.log" || :
)
if test "$(printf '%s\n' "$live_suffix_tlaps_lines" | wc -l | tr -d ' ')" \
  -ne 1
then
  live_suffix_tlaps_fail_with_log "obligation summary missing or malformed"
fi
live_suffix_tlaps_obligations=$(
  printf '%s\n' "$live_suffix_tlaps_lines" |
    sed -n -e 's/^All \([1-9][0-9]*\) obligations proved[.]$/\1/p' \
      -e 's/^\[INFO\]: All \([1-9][0-9]*\) obligations proved[.]$/\1/p'
)
case "$live_suffix_tlaps_obligations" in
  ''|0|*[!0-9]*)
    live_suffix_tlaps_fail_with_log "obligation total malformed or zero"
    ;;
esac
if grep -q '^Warning:' "$temporary_root/tlaps-live-suffix-registry.log"
then
  live_suffix_tlaps_fail_with_log "warning emitted"
fi
if test "$live_suffix_tlaps_obligations" -ne 25
then
  live_suffix_tlaps_fail_with_log \
    "expected 25 obligations, observed $live_suffix_tlaps_obligations"
fi

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

#  Four independent transactions, including one finite-deadline singleton,
#  are bounded model geometry for an opt-in private coalescing prototype. They
#  are not a public cohort size, wait window, deadline policy, or scheduler.
set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 \
  -metadir "$temporary_root/tlc-independent-coalescing-states" \
  -config IndependentCommitCoalescing.cfg IndependentCommitCoalescing \
  >"$temporary_root/tlc-independent-coalescing.log" 2>&1
independent_coalescing_tlc_status=$?
set -e
if test "$independent_coalescing_tlc_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA independent coalescing positive TLC exited $independent_coalescing_tlc_status" \
    >&2
  cat "$temporary_root/tlc-independent-coalescing.log" >&2
  exit "$independent_coalescing_tlc_status"
fi
if ! grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-independent-coalescing.log"
then
  printf '%s\n' \
    'Flyology.DB TLA independent coalescing completion sentinel missing' >&2
  cat "$temporary_root/tlc-independent-coalescing.log" >&2
  exit 1
fi
if grep -q '^Warning:' "$temporary_root/tlc-independent-coalescing.log"
then
  printf '%s\n' 'Flyology.DB TLA independent coalescing positive TLC warned' >&2
  cat "$temporary_root/tlc-independent-coalescing.log" >&2
  exit 1
fi
independent_coalescing_state_lines=$(grep -E \
  '^[1-9][0-9]* states generated, [1-9][0-9]* distinct states found, 0 states left on queue[.]$' \
  "$temporary_root/tlc-independent-coalescing.log" || :)
if test -z "$independent_coalescing_state_lines" || \
  test "$(printf '%s\n' "$independent_coalescing_state_lines" | wc -l | tr -d ' ')" -ne 1
then
  printf '%s\n' \
    'Flyology.DB TLA independent coalescing state geometry missing or ambiguous' >&2
  grep 'states generated' "$temporary_root/tlc-independent-coalescing.log" >&2 || :
  exit 1
fi
independent_coalescing_generated=$(printf '%s\n' "$independent_coalescing_state_lines" | awk '{print $1}')
independent_coalescing_states=$(printf '%s\n' "$independent_coalescing_state_lines" | awk '{print $4}')
independent_coalescing_depth_lines=$(grep -E \
  '^The depth of the complete state graph search is [1-9][0-9]*[.]$' \
  "$temporary_root/tlc-independent-coalescing.log" || :)
if test -z "$independent_coalescing_depth_lines" || \
  test "$(printf '%s\n' "$independent_coalescing_depth_lines" | wc -l | tr -d ' ')" -ne 1
then
  printf '%s\n' \
    'Flyology.DB TLA independent coalescing depth missing or ambiguous' >&2
  grep 'depth of the complete state graph search' \
    "$temporary_root/tlc-independent-coalescing.log" >&2 || :
  exit 1
fi
independent_coalescing_depth=$(printf '%s\n' "$independent_coalescing_depth_lines" | \
  sed 's/^The depth of the complete state graph search is \([1-9][0-9]*\)[.]$/\1/')
for geometry_value in "$independent_coalescing_generated" \
  "$independent_coalescing_states" "$independent_coalescing_depth"
do
  case "$geometry_value" in
    ''|0|*[!0-9]*)
      printf '%s\n' \
        'Flyology.DB TLA independent coalescing geometry is not positive numeric' >&2
      printf '%s\n' "$independent_coalescing_state_lines" \
        "$independent_coalescing_depth_lines" >&2
      exit 1
      ;;
  esac
done
if test "$independent_coalescing_generated" -ne 1959420 || \
  test "$independent_coalescing_states" -ne 168545 || \
  test "$independent_coalescing_depth" -ne 30
then
  printf '%s\n' \
    'Flyology.DB TLA independent coalescing state geometry changed:' \
    "$independent_coalescing_state_lines" \
    "$independent_coalescing_depth_lines" >&2
  exit 1
fi

independent_coalescing_final_coverage="$temporary_root/independent-coalescing-final-coverage.txt"
if ! awk '
  /^Model checking completed\. No error has been found\.$/ {
    completed++
    next
  }
  /^The coverage statistics at / {
    if (completed == 0) {
      next
    }
    if (completed != 1 || capture || reports != 0) {
      invalid = 1
      next
    }
    block = ""
    capture = 1
    reports++
  }
  capture {
    block = block $0 ORS
  }
  capture && /^End of statistics/ {
    final = block
    capture = 0
  }
  END {
    if (invalid || completed != 1 || reports != 1 || capture || final == "") {
      exit 1
    }
    printf "%s", final
  }
' "$temporary_root/tlc-independent-coalescing.log" \
  >"$independent_coalescing_final_coverage"
then
  printf '%s\n' \
    'Flyology.DB TLA independent coalescing final coverage report missing or incomplete' >&2
  exit 1
fi
independent_coalescing_action_report="$temporary_root/independent-coalescing-action-coverage.txt"
: >"$independent_coalescing_action_report"
for action in AdmitSingleton RejectConflict CancelBeforeAdmission \
  RejectFiniteDeadline FreezeCohort PublishMemberBatch \
  ConfirmAmbiguousBatch FailFrozenCohort \
  PublishCohortHead LoseHeadResponse ObserveSuccess \
  ObserveHeadPreconditionFailure RetainUnknownAtPredecessor \
  ObserveConclusiveSuccessor ResolveMember ExportMemberAuthority \
  CrashLoseVolatileReceipts ImportMemberAuthority RejectMalformedAuthority \
  RejectSwappedAuthority RecoverCohortChain RejectMalformedRecovery \
  CompleteCohort
do
  independent_coalescing_action_lines=$(grep -E "^<$action " \
    "$independent_coalescing_final_coverage" || :)
  if test -z "$independent_coalescing_action_lines"
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing action $action failed: missing" >&2
    exit 1
  fi
  independent_coalescing_action_unique_lines=$(
    printf '%s\n' "$independent_coalescing_action_lines" |
      LC_ALL=C sort -u
  )
  if test "$(printf '%s\n' "$independent_coalescing_action_unique_lines" | \
    wc -l | tr -d ' ')" -ne 1
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing action $action failed: conflicting coverage" \
      >&2
    printf '%s\n' "$independent_coalescing_action_lines" >&2
    exit 1
  fi
  if ! printf '%s\n' "$independent_coalescing_action_unique_lines" |
    grep -Eq "^<$action .*: [0-9][0-9]*(:[0-9]+)?$"
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing action $action failed: malformed or nonnumeric" \
      >&2
    printf '%s\n' "$independent_coalescing_action_lines" >&2
    exit 1
  fi
  independent_coalescing_action_counts=${independent_coalescing_action_unique_lines##*: }
  independent_coalescing_action_count=${independent_coalescing_action_counts%%:*}
  case "$independent_coalescing_action_count" in
    ''|*[!0-9]*)
      printf '%s\n' \
        "Flyology.DB TLA independent coalescing action $action failed: malformed or nonnumeric" \
        >&2
      printf '%s\n' "$independent_coalescing_action_lines" >&2
      exit 1
      ;;
    0*)
      printf '%s\n' \
        "Flyology.DB TLA independent coalescing action $action failed: zero coverage" >&2
      printf '%s\n' "$independent_coalescing_action_lines" >&2
      exit 1
      ;;
  esac
  printf '    %s %s\n' "$action" "$independent_coalescing_action_count" \
    >>"$independent_coalescing_action_report"
done
independent_expected_action_report="$temporary_root/independent-coalescing-action-coverage.expected.txt"
cat >"$independent_expected_action_report" <<'EOF'
    AdmitSingleton 842
    RejectConflict 3734
    CancelBeforeAdmission 3734
    RejectFiniteDeadline 21616
    FreezeCohort 842
    PublishMemberBatch 4872
    ConfirmAmbiguousBatch 2436
    FailFrozenCohort 1160
    PublishCohortHead 1166
    LoseHeadResponse 2332
    ObserveSuccess 1490
    ObserveHeadPreconditionFailure 1166
    RetainUnknownAtPredecessor 9178
    ObserveConclusiveSuccessor 3980
    ResolveMember 9498
    ExportMemberAuthority 6574
    CrashLoseVolatileReceipts 5324
    ImportMemberAuthority 17546
    RejectMalformedAuthority 10196
    RejectSwappedAuthority 10196
    RecoverCohortChain 13430
    RejectMalformedRecovery 35742
    CompleteCohort 1490
EOF
if ! cmp "$independent_expected_action_report" \
  "$independent_coalescing_action_report"
then
  printf '%s\n' \
    'Flyology.DB TLA independent coalescing action coverage changed:' >&2
  cat "$independent_coalescing_action_report" >&2
  exit 1
fi

for probe in \
  IndependentCommitCoalescingPartialVisibilityProbe:WholeCohortVisibility \
  IndependentCommitCoalescingReplayProbe:ResolutionDoesNotReplay \
  IndependentCommitCoalescingStaleAdmissionProbe:FencingStopsAdmission \
  IndependentCommitCoalescingAuthorityProbe:ImportedAuthorityIsValid \
  IndependentCommitCoalescingResolvedAuthorityProbe:ResolvedImportedAuthorityIsExact \
  IndependentCommitCoalescingRecoveryProbe:RecoveryIsExact \
  IndependentCommitCoalescingFiniteDeadlineProbe:FiniteDeadlinesRejectBeforeAdmission \
  IndependentCommitCoalescingCohortFailureProbe:WholeFrozenCohortFailure
do
  probe_module=${probe%%:*}
  probe_invariant=${probe#*:}
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-$probe_module-states" \
    -config "$probe_module.cfg" "$probe_module" \
    >"$temporary_root/tlc-$probe_module.log" 2>&1
  probe_status=$?
  set -e
  if test "$probe_status" -ne 12
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing probe $probe_module exited $probe_status" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    if test "$probe_status" -eq 0
    then
      exit 1
    fi
    exit "$probe_status"
  fi
  if ! grep -q "Invariant $probe_invariant is violated." \
    "$temporary_root/tlc-$probe_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing probe $probe_module missed $probe_invariant" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    exit 1
  fi
  if grep -q '^Warning:' "$temporary_root/tlc-$probe_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing probe $probe_module warned" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    exit 1
  fi
done

for witness in \
  IndependentCommitCoalescingCohortFailureWitness:CohortFailurePending \
  IndependentCommitCoalescingFiniteDeadlineWitness:FiniteDeadlinePending \
  IndependentCommitCoalescingAuthorityWitness:AuthorityRecoveryPending \
  IndependentCommitCoalescingSiblingAuthorityWitness:SiblingAuthorityPending \
  IndependentCommitCoalescingEmptyRecoveryWitness:EmptyRecoveryPending \
  IndependentCommitCoalescingPreconditionWitness:PreconditionPending \
  IndependentCommitCoalescingSuccessorWitness:SuccessorPending
do
  witness_module=${witness%%:*}
  witness_invariant=${witness#*:}
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-$witness_module-states" \
    -config "$witness_module.cfg" "$witness_module" \
    >"$temporary_root/tlc-$witness_module.log" 2>&1
  witness_status=$?
  set -e
  if test "$witness_status" -ne 12
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing witness $witness_module exited $witness_status" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    if test "$witness_status" -eq 0
    then
      exit 1
    fi
    exit "$witness_status"
  fi
  if ! grep -q "Invariant $witness_invariant is violated." \
    "$temporary_root/tlc-$witness_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing witness $witness_module missed $witness_invariant" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    exit 1
  fi
  if grep -q '^Warning:' "$temporary_root/tlc-$witness_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA independent coalescing witness $witness_module warned" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    exit 1
  fi
done

set +e
"$tlapm" --cache-dir "$temporary_root/tlapm-independent-coalescing-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/IndependentCommitCoalescingSafetyProof.tla" \
  >"$temporary_root/tlaps-independent-coalescing.log" 2>&1
independent_coalescing_tlaps_status=$?
set -e
if test "$independent_coalescing_tlaps_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA independent coalescing TLAPS exited $independent_coalescing_tlaps_status" \
    >&2
  cat "$temporary_root/tlaps-independent-coalescing.log" >&2
  exit "$independent_coalescing_tlaps_status"
fi
if grep -q '^Warning:' "$temporary_root/tlaps-independent-coalescing.log"
then
  printf '%s\n' 'Flyology.DB TLA independent coalescing TLAPS warned' >&2
  cat "$temporary_root/tlaps-independent-coalescing.log" >&2
  exit 1
fi
independent_coalescing_tlaps_lines=$(grep -E \
  '^(\[INFO\]: )?All [1-9][0-9]* obligations proved[.]$' \
  "$temporary_root/tlaps-independent-coalescing.log" || :)
if test -z "$independent_coalescing_tlaps_lines" || \
  test "$(printf '%s\n' "$independent_coalescing_tlaps_lines" | wc -l | tr -d ' ')" -ne 1
then
  printf '%s\n' \
    'Flyology.DB TLA independent coalescing TLAPS summary missing or ambiguous' >&2
  cat "$temporary_root/tlaps-independent-coalescing.log" >&2
  exit 1
fi
independent_coalescing_obligations=$(printf '%s\n' \
  "$independent_coalescing_tlaps_lines" | \
  sed -E 's/^(\[INFO\]: )?All ([1-9][0-9]*) obligations proved[.]$/\2/')
case "$independent_coalescing_obligations" in
  ''|0|*[!0-9]*)
    printf '%s\n' \
      'Flyology.DB TLA independent coalescing TLAPS total is not positive numeric' >&2
    cat "$temporary_root/tlaps-independent-coalescing.log" >&2
    exit 1
    ;;
esac
if test "$independent_coalescing_obligations" -ne 16
then
  printf '%s\n' \
    'Flyology.DB TLA independent coalescing obligation total changed:' >&2
  cat "$temporary_root/tlaps-independent-coalescing.log" >&2
  exit 1
fi

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 \
  -metadir "$temporary_root/tlc-aggregate-coalescing-states" \
  -config AggregateCommitCoalescing.cfg AggregateCommitCoalescing \
  >"$temporary_root/tlc-aggregate-coalescing.log" 2>&1
aggregate_coalescing_tlc_status=$?
set -e
if test "$aggregate_coalescing_tlc_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA aggregate coalescing positive TLC exited $aggregate_coalescing_tlc_status" \
    >&2
  cat "$temporary_root/tlc-aggregate-coalescing.log" >&2
  exit "$aggregate_coalescing_tlc_status"
fi
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-aggregate-coalescing.log"
if grep -q '^Warning:' "$temporary_root/tlc-aggregate-coalescing.log"
then
  printf '%s\n' 'Flyology.DB TLA aggregate coalescing TLC warned' >&2
  cat "$temporary_root/tlc-aggregate-coalescing.log" >&2
  exit 1
fi
aggregate_coalescing_state_lines=$(grep -E \
  '^[1-9][0-9]* states generated, [1-9][0-9]* distinct states found, 0 states left on queue[.]$' \
  "$temporary_root/tlc-aggregate-coalescing.log" || :)
test "$(printf '%s\n' "$aggregate_coalescing_state_lines" | wc -l | tr -d ' ')" -eq 1
aggregate_coalescing_generated=$(printf '%s\n' "$aggregate_coalescing_state_lines" | awk '{print $1}')
aggregate_coalescing_states=$(printf '%s\n' "$aggregate_coalescing_state_lines" | awk '{print $4}')
aggregate_coalescing_depth_lines=$(grep -E \
  '^The depth of the complete state graph search is [1-9][0-9]*[.]$' \
  "$temporary_root/tlc-aggregate-coalescing.log" || :)
test "$(printf '%s\n' "$aggregate_coalescing_depth_lines" | wc -l | tr -d ' ')" -eq 1
aggregate_coalescing_depth=$(printf '%s\n' "$aggregate_coalescing_depth_lines" | \
  sed 's/^The depth of the complete state graph search is \([1-9][0-9]*\)[.]$/\1/')
if test "$aggregate_coalescing_generated" -ne 16895425 || \
  test "$aggregate_coalescing_states" -ne 2739226 || \
  test "$aggregate_coalescing_depth" -ne 33
then
  printf '%s\n' \
    'Flyology.DB TLA aggregate coalescing state geometry changed:' \
    "$aggregate_coalescing_state_lines" \
    "$aggregate_coalescing_depth_lines" >&2
  exit 1
fi

aggregate_coalescing_final_coverage="$temporary_root/aggregate-coalescing-final-coverage.txt"
if ! awk '
  /^Model checking completed\. No error has been found\.$/ {
    completed++
    next
  }
  /^The coverage statistics at / {
    if (completed == 0) {
      next
    }
    if (completed != 1 || capture || reports != 0) {
      invalid = 1
      next
    }
    block = ""
    capture = 1
    reports++
  }
  capture {
    block = block $0 ORS
  }
  capture && /^End of statistics/ {
    final = block
    capture = 0
  }
  END {
    if (invalid || completed != 1 || reports != 1 || capture || final == "") {
      exit 1
    }
    printf "%s", final
  }
' "$temporary_root/tlc-aggregate-coalescing.log" \
  >"$aggregate_coalescing_final_coverage"
then
  printf '%s\n' \
    'Flyology.DB TLA aggregate coalescing final coverage report missing or incomplete' >&2
  exit 1
fi
aggregate_coalescing_action_report="$temporary_root/aggregate-coalescing-action-coverage.txt"
: >"$aggregate_coalescing_action_report"
for action in SupplyAggregateID AdmitSingleton RejectBeforeAdmission \
  RequestAdmittedCancellation RejectQueuedConflict FreezeCohort PublishAggregate ConfirmAggregate \
  FailFrozenCohort RivalHead PublishHead ObserveSuccess RejectHead \
  ResolveMember ResolveRejected RetainUnknown ExportAuthority \
  ImportAuthority RejectMalformedAuthority RejectInexactResolution Crash \
  ReopenFromHead Close ProbeConfirmedOrphanCollision ObserveMissingIdentityBoundary
do
  aggregate_coalescing_action_lines=$(grep -E "^<$action " \
    "$aggregate_coalescing_final_coverage" || :)
  if test -z "$aggregate_coalescing_action_lines"
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate coalescing action $action failed: missing" >&2
    exit 1
  fi
  aggregate_coalescing_action_unique_lines=$(
    printf '%s\n' "$aggregate_coalescing_action_lines" |
      LC_ALL=C sort -u
  )
  if test "$(printf '%s\n' "$aggregate_coalescing_action_unique_lines" | \
    wc -l | tr -d ' ')" -ne 1
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate coalescing action $action failed: conflicting coverage" \
      >&2
    printf '%s\n' "$aggregate_coalescing_action_lines" >&2
    exit 1
  fi
  if ! printf '%s\n' "$aggregate_coalescing_action_unique_lines" |
    grep -Eq "^<$action .*: [0-9][0-9]*(:[0-9]+)?$"
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate coalescing action $action failed: malformed or nonnumeric" \
      >&2
    printf '%s\n' "$aggregate_coalescing_action_lines" >&2
    exit 1
  fi
  aggregate_coalescing_action_counts=${aggregate_coalescing_action_unique_lines##*: }
  aggregate_coalescing_action_count=${aggregate_coalescing_action_counts%%:*}
  case "$aggregate_coalescing_action_count" in
    ''|*[!0-9]*)
      printf '%s\n' \
        "Flyology.DB TLA aggregate coalescing action $action failed: malformed or nonnumeric" \
        >&2
      printf '%s\n' "$aggregate_coalescing_action_lines" >&2
      exit 1
      ;;
    0*)
      printf '%s\n' \
        "Flyology.DB TLA aggregate coalescing action $action failed: zero coverage" >&2
      printf '%s\n' "$aggregate_coalescing_action_lines" >&2
      exit 1
      ;;
  esac
  printf '    %s %s\n' "$action" "$aggregate_coalescing_action_count" \
    >>"$aggregate_coalescing_action_report"
done
aggregate_expected_action_report="$temporary_root/aggregate-coalescing-action-coverage.expected.txt"
cat >"$aggregate_expected_action_report" <<'EOF'
    SupplyAggregateID 56288
    AdmitSingleton 27082
    RejectBeforeAdmission 88894
    RequestAdmittedCancellation 58343
    RejectQueuedConflict 26522
    FreezeCohort 1786
    PublishAggregate 7372
    ConfirmAggregate 3686
    FailFrozenCohort 6654
    RivalHead 5655
    PublishHead 5529
    ObserveSuccess 1843
    RejectHead 1074
    ResolveMember 138668
    ResolveRejected 64336
    RetainUnknown 30370
    ExportAuthority 32103
    ImportAuthority 697688
    RejectMalformedAuthority 142256
    RejectInexactResolution 372576
    Crash 1661
    ReopenFromHead 1661
    Close 710786
    ProbeConfirmedOrphanCollision 247881
    ObserveMissingIdentityBoundary 8511
EOF
if ! cmp "$aggregate_expected_action_report" \
  "$aggregate_coalescing_action_report"
then
  printf '%s\n' \
    'Flyology.DB TLA aggregate coalescing action coverage changed:' >&2
  cat "$aggregate_coalescing_action_report" >&2
  exit 1
fi

for probe in \
  AggregateCommitCoalescingVisibilityProbe:WholeCohortVisibility \
  AggregateCommitCoalescingReplayProbe:ResolutionDoesNotReplay \
  AggregateCommitCoalescingAuthorityProbe:ResolvedAuthorityIsExact \
  AggregateCommitCoalescingCancellationProbe:AdmittedCancellationDoesNotClassify \
  AggregateCommitCoalescingIdentityProbe:CallerIdentityContract \
  AggregateCommitCoalescingOrphanProbe:ConfirmedOrphanBarrier
do
  probe_module=${probe%%:*}
  probe_invariant=${probe#*:}
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-$probe_module-states" \
    -config "$probe_module.cfg" AggregateCommitCoalescingProbes \
    >"$temporary_root/tlc-$probe_module.log" 2>&1
  probe_status=$?
  set -e
  if test "$probe_status" -ne 12
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate coalescing probe $probe_module exited $probe_status" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    if test "$probe_status" -eq 0
    then
      exit 1
    fi
    exit "$probe_status"
  fi
  grep -q "Invariant $probe_invariant is violated." \
    "$temporary_root/tlc-$probe_module.log"
  if grep -q '^Warning:' "$temporary_root/tlc-$probe_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate coalescing probe $probe_module warned" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    exit 1
  fi
done

for witness in \
  AggregateCommitCoalescingAuthorityWitness:AuthorityRecoveryPending \
  AggregateCommitCoalescingCancellationWitness:WitnessPending \
  AggregateCommitCoalescingOrphanWitness:ConfirmedOrphanPending \
  AggregateCommitCoalescingMissingIdentityWitness:MissingIdentityPending
do
  witness_module=${witness%%:*}
  witness_invariant=${witness#*:}
  aggregate_witness_source=AggregateCommitCoalescingWitnesses
  if test "$witness_module" = AggregateCommitCoalescingCancellationWitness
  then
    aggregate_witness_source=$witness_module
  fi
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-$witness_module-states" \
    -config "$witness_module.cfg" "$aggregate_witness_source" \
    >"$temporary_root/tlc-$witness_module.log" 2>&1
  witness_status=$?
  set -e
  if test "$witness_status" -ne 12
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate coalescing witness $witness_module exited $witness_status" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    if test "$witness_status" -eq 0
    then
      exit 1
    fi
    exit "$witness_status"
  fi
  grep -q "Invariant $witness_invariant is violated." \
    "$temporary_root/tlc-$witness_module.log"
  if grep -q '^Warning:' "$temporary_root/tlc-$witness_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate coalescing witness $witness_module warned" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    exit 1
  fi
done

set +e
"$tlapm" --cache-dir "$temporary_root/tlapm-aggregate-coalescing-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/AggregateCommitCoalescingSafetyProof.tla" \
  >"$temporary_root/tlaps-aggregate-coalescing.log" 2>&1
aggregate_coalescing_tlaps_status=$?
set -e
if test "$aggregate_coalescing_tlaps_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA aggregate coalescing TLAPS exited $aggregate_coalescing_tlaps_status" \
    >&2
  cat "$temporary_root/tlaps-aggregate-coalescing.log" >&2
  exit "$aggregate_coalescing_tlaps_status"
fi
if grep -q '^Warning:' "$temporary_root/tlaps-aggregate-coalescing.log"
then
  printf '%s\n' 'Flyology.DB TLA aggregate coalescing TLAPS warned' >&2
  cat "$temporary_root/tlaps-aggregate-coalescing.log" >&2
  exit 1
fi
aggregate_coalescing_tlaps_lines=$(grep -E \
  '^(\[INFO\]: )?All [1-9][0-9]* obligations proved[.]$' \
  "$temporary_root/tlaps-aggregate-coalescing.log" || :)
test -n "$aggregate_coalescing_tlaps_lines"
test "$(printf '%s\n' "$aggregate_coalescing_tlaps_lines" | wc -l | tr -d ' ')" -eq 1
aggregate_coalescing_obligations=$(printf '%s\n' \
  "$aggregate_coalescing_tlaps_lines" | \
  sed -E 's/^(\[INFO\]: )?All ([1-9][0-9]*) obligations proved[.]$/\2/')
case "$aggregate_coalescing_obligations" in
  ''|0|*[!0-9]*)
    printf '%s\n' \
      'Flyology.DB TLA aggregate coalescing TLAPS total is not positive numeric' >&2
    exit 1
    ;;
esac
if test "$aggregate_coalescing_obligations" -ne 127
then
  printf '%s\n' \
    'Flyology.DB TLA aggregate coalescing obligation total changed:' >&2
  cat "$temporary_root/tlaps-aggregate-coalescing.log" >&2
  exit 1
fi

adaptive_extract_geometry() {
  adaptive_geometry_log=$1
  adaptive_geometry_label=$2
  adaptive_state_lines=$(grep -E \
    '^[1-9][0-9]* states generated, [1-9][0-9]* distinct states found, 0 states left on queue[.]$' \
    "$adaptive_geometry_log" || :)
  adaptive_depth_lines=$(grep -E \
    '^The depth of the complete state graph search is [1-9][0-9]*[.]$' \
    "$adaptive_geometry_log" || :)
  if test -z "$adaptive_state_lines" || \
    test "$(printf '%s\n' "$adaptive_state_lines" | wc -l | tr -d ' ')" -ne 1 || \
    test -z "$adaptive_depth_lines" || \
    test "$(printf '%s\n' "$adaptive_depth_lines" | wc -l | tr -d ' ')" -ne 1
  then
    printf '%s\n' \
      "Flyology.DB TLA adaptive coalescing $adaptive_geometry_label geometry missing or ambiguous" \
      >&2
    grep -E 'states generated|depth of the complete state graph' \
      "$adaptive_geometry_log" >&2 || :
    exit 1
  fi
  adaptive_generated=$(printf '%s\n' "$adaptive_state_lines" | awk '{print $1}')
  adaptive_distinct=$(printf '%s\n' "$adaptive_state_lines" | awk '{print $4}')
  adaptive_depth=$(printf '%s\n' "$adaptive_depth_lines" | \
    sed 's/^The depth of the complete state graph search is \([1-9][0-9]*\)[.]$/\1/')
}

adaptive_write_action_report() {
  adaptive_action_log=$1
  adaptive_action_report=$2
  shift 2
  adaptive_final_coverage="$adaptive_action_report.final"
  if ! awk '
    /^Model checking completed\. No error has been found\.$/ {
      completed++
      next
    }
    /^The coverage statistics at / {
      if (completed == 0) {
        next
      }
      if (completed != 1 || capture || reports != 0) {
        invalid = 1
        next
      }
      block = ""
      capture = 1
      reports++
    }
    capture {
      block = block $0 ORS
    }
    capture && /^End of statistics/ {
      final = block
      capture = 0
    }
    END {
      if (invalid || completed != 1 || reports != 1 || capture || final == "") {
        exit 1
      }
      printf "%s", final
    }
  ' "$adaptive_action_log" >"$adaptive_final_coverage"
  then
    printf '%s\n' \
      'Flyology.DB TLA adaptive coalescing final coverage report missing or incomplete' >&2
    exit 1
  fi
  : >"$adaptive_action_report"
  for adaptive_action
  do
    adaptive_action_lines=$(grep -E "^<$adaptive_action " \
      "$adaptive_final_coverage" || :)
    if test -z "$adaptive_action_lines"
    then
      printf '%s\n' \
        "Flyology.DB TLA adaptive coalescing action $adaptive_action failed: missing" >&2
      exit 1
    fi
    adaptive_action_unique_lines=$(printf '%s\n' "$adaptive_action_lines" | \
      LC_ALL=C sort -u)
    if test "$(printf '%s\n' "$adaptive_action_unique_lines" | wc -l | tr -d ' ')" -ne 1
    then
      printf '%s\n' \
        "Flyology.DB TLA adaptive coalescing action $adaptive_action failed: conflicting coverage" \
        >&2
      printf '%s\n' "$adaptive_action_lines" >&2
      exit 1
    fi
    if ! printf '%s\n' "$adaptive_action_unique_lines" | \
      grep -Eq "^<$adaptive_action .*: [0-9][0-9]*(:[0-9]+)?$"
    then
      printf '%s\n' \
        "Flyology.DB TLA adaptive coalescing action $adaptive_action failed: malformed" >&2
      printf '%s\n' "$adaptive_action_lines" >&2
      exit 1
    fi
    adaptive_action_counts=${adaptive_action_unique_lines##*: }
    case "$adaptive_action_counts" in
      *:*)
        adaptive_action_invocations=${adaptive_action_counts##*:}
        ;;
      *)
        adaptive_action_invocations=$adaptive_action_counts
        ;;
    esac
    case "$adaptive_action_invocations" in
      ''|*[!0-9]*|0*)
        printf '%s\n' \
          "Flyology.DB TLA adaptive coalescing action $adaptive_action failed: no invocations" >&2
        exit 1
        ;;
    esac
    printf '    %s %s\n' "$adaptive_action" "$adaptive_action_counts" \
      >>"$adaptive_action_report"
  done
}

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-adaptive-coalescing-core-states" \
  -config AdaptiveAggregateCommitCoalescing.cfg AdaptiveAggregateCommitCoalescing \
  >"$temporary_root/tlc-adaptive-coalescing-core.log" 2>&1
adaptive_core_status=$?
set -e
if test "$adaptive_core_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA adaptive coalescing core TLC exited $adaptive_core_status" >&2
  cat "$temporary_root/tlc-adaptive-coalescing-core.log" >&2
  exit "$adaptive_core_status"
fi
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-adaptive-coalescing-core.log"
if grep -q '^Warning:' "$temporary_root/tlc-adaptive-coalescing-core.log"
then
  printf '%s\n' 'Flyology.DB TLA adaptive coalescing core TLC warned' >&2
  cat "$temporary_root/tlc-adaptive-coalescing-core.log" >&2
  exit 1
fi
adaptive_extract_geometry "$temporary_root/tlc-adaptive-coalescing-core.log" core
adaptive_core_generated=$adaptive_generated
adaptive_core_distinct=$adaptive_distinct
adaptive_core_depth=$adaptive_depth
adaptive_core_action_report="$temporary_root/adaptive-core-action-coverage.txt"
adaptive_write_action_report \
  "$temporary_root/tlc-adaptive-coalescing-core.log" "$adaptive_core_action_report" \
  Admit CancelBeforeAdmission RequestCancellation ReachDeadline ExpireQueued Tick \
  RejectQueuedConflict BeginClose FreezeCohort PublishAggregate ConfirmAggregate \
  ObserveBatchFailure BeginHeadAttempt RivalHead HeadAccepted ClassifyHeadUnknown \
  HeadPreconditionRejected ObserveSuccess ObserveLocalInstallFailure ResolveMember \
  ResolveRejected RetainUnknown ExportAuthority ImportAuthority \
  RejectMalformedAuthority Crash ReopenFromHead CloseWithUnknown Close
if test "$adaptive_core_generated" -ne 18644105 || \
  test "$adaptive_core_distinct" -ne 4090177 || \
  test "$adaptive_core_depth" -ne 37
then
  printf '%s\n' \
    'Flyology.DB TLA adaptive coalescing core geometry changed' >&2
  exit 1
fi
adaptive_core_expected_action_report="$temporary_root/adaptive-core-action-coverage.expected.txt"
cat >"$adaptive_core_expected_action_report" <<'EOF'
    Admit 1745:1114449
    CancelBeforeAdmission 0:3179682
    RequestCancellation 1757:727920
    ReachDeadline 3514:727920
    ExpireQueued 4984:37704
    Tick 13792:50272
    RejectQueuedConflict 10208:75408
    BeginClose 508339:1379051
    FreezeCohort 32608:57176
    PublishAggregate 132736:178816
    ConfirmAggregate 0:89408
    ObserveBatchFailure 30272:44704
    BeginHeadAttempt 33184:77120
    RivalHead 50240:131968
    HeadAccepted 33184:44704
    ClassifyHeadUnknown 91488:121824
    HeadPreconditionRejected 22304:32416
    ObserveSuccess 30368:44704
    ObserveLocalInstallFailure 29600:44704
    ResolveMember 267312:816352
    ResolveRejected 330048:601568
    RetainUnknown 0:339104
    ExportAuthority 120480:532320
    ImportAuthority 628880:2070016
    RejectMalformedAuthority 322448:3250176
    Crash 304002:475732
    ReopenFromHead 472338:918347
    CloseWithUnknown 97104:183600
    Close 517241:1296939
EOF
if ! cmp "$adaptive_core_expected_action_report" "$adaptive_core_action_report"
then
  printf '%s\n' \
    'Flyology.DB TLA adaptive coalescing core action coverage changed:' >&2
  cat "$adaptive_core_action_report" >&2
  exit 1
fi

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -metadir "$temporary_root/tlc-adaptive-coalescing-scheduler-states" \
  -config AdaptiveAggregateCommitCoalescingScheduler.cfg \
  AdaptiveAggregateCommitCoalescing \
  >"$temporary_root/tlc-adaptive-coalescing-scheduler.log" 2>&1
adaptive_scheduler_status=$?
set -e
if test "$adaptive_scheduler_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA adaptive coalescing scheduler TLC exited $adaptive_scheduler_status" >&2
  cat "$temporary_root/tlc-adaptive-coalescing-scheduler.log" >&2
  exit "$adaptive_scheduler_status"
fi
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-adaptive-coalescing-scheduler.log"
if grep -q '^Warning:' "$temporary_root/tlc-adaptive-coalescing-scheduler.log"
then
  printf '%s\n' 'Flyology.DB TLA adaptive coalescing scheduler TLC warned' >&2
  cat "$temporary_root/tlc-adaptive-coalescing-scheduler.log" >&2
  exit 1
fi
adaptive_extract_geometry "$temporary_root/tlc-adaptive-coalescing-scheduler.log" scheduler
adaptive_scheduler_generated=$adaptive_generated
adaptive_scheduler_distinct=$adaptive_distinct
adaptive_scheduler_depth=$adaptive_depth
if test "$adaptive_scheduler_generated" -ne 10444240 || \
  test "$adaptive_scheduler_distinct" -ne 2478645 || \
  test "$adaptive_scheduler_depth" -ne 33
then
  printf '%s\n' \
    'Flyology.DB TLA adaptive coalescing scheduler geometry changed' >&2
  exit 1
fi

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 -metadir "$temporary_root/tlc-adaptive-coalescing-progress-states" \
  -config AdaptiveAggregateCommitCoalescingProgress.cfg \
  AdaptiveAggregateCommitCoalescingProgress \
  >"$temporary_root/tlc-adaptive-coalescing-progress.log" 2>&1
adaptive_progress_status=$?
set -e
if test "$adaptive_progress_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA adaptive coalescing progress TLC exited $adaptive_progress_status" >&2
  cat "$temporary_root/tlc-adaptive-coalescing-progress.log" >&2
  exit "$adaptive_progress_status"
fi
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-adaptive-coalescing-progress.log"
if grep -q '^Warning:' "$temporary_root/tlc-adaptive-coalescing-progress.log"
then
  printf '%s\n' 'Flyology.DB TLA adaptive coalescing progress TLC warned' >&2
  cat "$temporary_root/tlc-adaptive-coalescing-progress.log" >&2
  exit 1
fi
adaptive_extract_geometry "$temporary_root/tlc-adaptive-coalescing-progress.log" progress
adaptive_progress_generated=$adaptive_generated
adaptive_progress_distinct=$adaptive_distinct
adaptive_progress_depth=$adaptive_depth
adaptive_progress_action_report="$temporary_root/adaptive-progress-action-coverage.txt"
adaptive_write_action_report \
  "$temporary_root/tlc-adaptive-coalescing-progress.log" \
  "$adaptive_progress_action_report" Admit RequestCancellation Tick FreezeCohort \
  PublishAggregate BeginHeadAttempt HeadAccepted ObserveSuccess
if test "$adaptive_progress_generated" -ne 96058 || \
  test "$adaptive_progress_distinct" -ne 23983 || \
  test "$adaptive_progress_depth" -ne 28
then
  printf '%s\n' \
    'Flyology.DB TLA adaptive coalescing progress geometry changed' >&2
  exit 1
fi
adaptive_progress_expected_action_report="$temporary_root/adaptive-progress-action-coverage.expected.txt"
cat >"$adaptive_progress_expected_action_report" <<'EOF'
    Admit 1443:2613
    RequestCancellation 8001:57807
    Tick 4596:16962
    FreezeCohort 1278:6111
    PublishAggregate 2166:4323
    BeginHeadAttempt 2166:5211
    HeadAccepted 2166:5211
    ObserveSuccess 2166:5211
EOF
if ! cmp "$adaptive_progress_expected_action_report" \
    "$adaptive_progress_action_report"
then
  printf '%s\n' \
    'Flyology.DB TLA adaptive coalescing progress action coverage changed:' >&2
  cat "$adaptive_progress_action_report" >&2
  exit 1
fi

for probe in \
  AdaptiveAggregateCommitCoalescingVisibilityProbe:WholeCohortVisibility \
  AdaptiveAggregateCommitCoalescingReplayProbe:PublicationGeometry \
  AdaptiveAggregateCommitCoalescingCancellationProbe:CancellationAndDeadlineCut \
  AdaptiveAggregateCommitCoalescingSplitOutcomeProbe:NoSplitAfterHeadAttempt \
  AdaptiveAggregateCommitCoalescingAliasProbe:LeaderAliasIsExact \
  AdaptiveAggregateCommitCoalescingAuthorityProbe:AuthorityIsComplete \
  AdaptiveAggregateCommitCoalescingUnknownAuthorityProbe:AuthorityIsComplete \
  AdaptiveAggregateCommitCoalescingCancelledIdentityProbe:PreAdmissionCancellationKeepsIdentity \
  AdaptiveAggregateCommitCoalescingSequenceProbe:LeaderAliasIsExact \
  AdaptiveAggregateCommitCoalescingDeadlineProbe:CancellationAndDeadlineCut
do
  probe_module=${probe%%:*}
  probe_invariant=${probe#*:}
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE -metadir "$temporary_root/tlc-$probe_module-states" \
    -config "$probe_module.cfg" AdaptiveAggregateCommitCoalescingProbes \
    >"$temporary_root/tlc-$probe_module.log" 2>&1
  probe_status=$?
  set -e
  if test "$probe_status" -ne 12
  then
    printf '%s\n' \
      "Flyology.DB TLA adaptive coalescing probe $probe_module exited $probe_status" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    if test "$probe_status" -eq 0
    then
      exit 1
    fi
    exit "$probe_status"
  fi
  grep -q "Invariant $probe_invariant is violated." \
    "$temporary_root/tlc-$probe_module.log"
  if grep -q '^Warning:' "$temporary_root/tlc-$probe_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA adaptive coalescing probe $probe_module warned" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    exit 1
  fi
done

for witness in \
  AdaptiveAggregateCommitCoalescingTailWitness:TailSuccessPending \
  AdaptiveAggregateCommitCoalescingByteWitness:ByteBoundFreezePending \
  AdaptiveAggregateCommitCoalescingExactByteWitness:ExactByteTargetPending \
  AdaptiveAggregateCommitCoalescingOversizedWitness:OversizedSingletonPending \
  AdaptiveAggregateCommitCoalescingExpiryWitness:QueuedExpiryPending \
  AdaptiveAggregateCommitCoalescingCancellationWitness:CancellationResolutionPending \
  AdaptiveAggregateCommitCoalescingRejectionWitness:PreconditionRejectionPending \
  AdaptiveAggregateCommitCoalescingRejectedResolutionWitness:RejectedMemberResolutionPending \
  AdaptiveAggregateCommitCoalescingAuthorityWitness:AuthorityRecoveryPending \
  AdaptiveAggregateCommitCoalescingPreAdmissionWitness:PreAdmissionCancellationPending \
  AdaptiveAggregateCommitCoalescingCrashBeforeHeadWitness:CrashBeforeHeadEntryRecoveryPending \
  AdaptiveAggregateCommitCoalescingCrashAfterHeadWitness:CrashAfterHeadEntryRecoveryPending \
  AdaptiveAggregateCommitCoalescingLocalFailureWitness:LocalInstallFailurePending \
  AdaptiveAggregateCommitCoalescingUnknownCloseWitness:UnknownCloseRecoveryPending \
  AdaptiveAggregateCommitCoalescingReopenAdmissionWitness:ReopenAdmissionPending
do
  witness_module=${witness%%:*}
  witness_invariant=${witness#*:}
  witness_source=AdaptiveAggregateCommitCoalescingWitnesses
  case "$witness_module" in
    AdaptiveAggregateCommitCoalescingAuthorityWitness | \
      AdaptiveAggregateCommitCoalescingCrashBeforeHeadWitness | \
      AdaptiveAggregateCommitCoalescingCrashAfterHeadWitness)
      witness_source=AdaptiveAggregateCommitCoalescingRecoveryWitnesses
      ;;
  esac
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE -metadir "$temporary_root/tlc-$witness_module-states" \
    -config "$witness_module.cfg" "$witness_source" \
    >"$temporary_root/tlc-$witness_module.log" 2>&1
  witness_status=$?
  set -e
  if test "$witness_status" -ne 12
  then
    printf '%s\n' \
      "Flyology.DB TLA adaptive coalescing witness $witness_module exited $witness_status" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    if test "$witness_status" -eq 0
    then
      exit 1
    fi
    exit "$witness_status"
  fi
  grep -q "Invariant $witness_invariant is violated." \
    "$temporary_root/tlc-$witness_module.log"
  if grep -q '^Warning:' "$temporary_root/tlc-$witness_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA adaptive coalescing witness $witness_module warned" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    exit 1
  fi
done

set +e
"$tlapm" --cache-dir "$temporary_root/tlapm-adaptive-coalescing-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/AdaptiveAggregateCommitCoalescingSafetyProof.tla" \
  >"$temporary_root/tlaps-adaptive-coalescing.log" 2>&1
adaptive_tlaps_status=$?
set -e
if test "$adaptive_tlaps_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA adaptive coalescing TLAPS exited $adaptive_tlaps_status" >&2
  cat "$temporary_root/tlaps-adaptive-coalescing.log" >&2
  exit "$adaptive_tlaps_status"
fi
if grep -q '^Warning:' "$temporary_root/tlaps-adaptive-coalescing.log"
then
  printf '%s\n' 'Flyology.DB TLA adaptive coalescing TLAPS warned' >&2
  cat "$temporary_root/tlaps-adaptive-coalescing.log" >&2
  exit 1
fi
adaptive_tlaps_lines=$(grep -E \
  '^(\[INFO\]: )?All [1-9][0-9]* obligations proved[.]$' \
  "$temporary_root/tlaps-adaptive-coalescing.log" || :)
if test -z "$adaptive_tlaps_lines" || \
  test "$(printf '%s\n' "$adaptive_tlaps_lines" | wc -l | tr -d ' ')" -ne 1
then
  printf '%s\n' \
    'Flyology.DB TLA adaptive coalescing TLAPS summary missing or ambiguous' >&2
  cat "$temporary_root/tlaps-adaptive-coalescing.log" >&2
  exit 1
fi
adaptive_tlaps_obligations=$(printf '%s\n' "$adaptive_tlaps_lines" | \
  sed -E 's/^(\[INFO\]: )?All ([1-9][0-9]*) obligations proved[.]$/\2/')
case "$adaptive_tlaps_obligations" in
  ''|0|*[!0-9]*)
    printf '%s\n' \
      'Flyology.DB TLA adaptive coalescing TLAPS total is not positive numeric' >&2
    exit 1
    ;;
esac
if test "$adaptive_tlaps_obligations" -ne 56
then
  printf '%s\n' \
    'Flyology.DB TLA adaptive coalescing obligation total changed:' >&2
  cat "$temporary_root/tlaps-adaptive-coalescing.log" >&2
  exit 1
fi

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -coverage 1 \
  -metadir "$temporary_root/tlc-pipelined-adaptive-coalescing-states" \
  -config PipelinedAdaptiveAggregateCommitCoalescing.cfg \
  PipelinedAdaptiveAggregateCommitCoalescing \
  >"$temporary_root/tlc-pipelined-adaptive-coalescing.log" 2>&1
pipelined_adaptive_status=$?
set -e
if test "$pipelined_adaptive_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA pipelined adaptive coalescing TLC exited $pipelined_adaptive_status" >&2
  cat "$temporary_root/tlc-pipelined-adaptive-coalescing.log" >&2
  exit "$pipelined_adaptive_status"
fi
grep -q 'Model checking completed. No error has been found.' \
  "$temporary_root/tlc-pipelined-adaptive-coalescing.log"
if grep -q '^Warning:' "$temporary_root/tlc-pipelined-adaptive-coalescing.log"
then
  printf '%s\n' 'Flyology.DB TLA pipelined adaptive coalescing TLC warned' >&2
  cat "$temporary_root/tlc-pipelined-adaptive-coalescing.log" >&2
  exit 1
fi
adaptive_extract_geometry \
  "$temporary_root/tlc-pipelined-adaptive-coalescing.log" pipeline
pipelined_adaptive_generated=$adaptive_generated
pipelined_adaptive_distinct=$adaptive_distinct
pipelined_adaptive_depth=$adaptive_depth
pipelined_adaptive_action_report="$temporary_root/pipelined-adaptive-action-coverage.txt"
adaptive_write_action_report \
  "$temporary_root/tlc-pipelined-adaptive-coalescing.log" \
  "$pipelined_adaptive_action_report" Freeze RequestCancellation StartBatch \
  StoreBatch CompleteBatch JoinBatch IgnoreStaleCompletion ObserveBatch StartHead \
  ApplyHead RivalHead CompleteHead JoinHead RetireSuccess AbandonSuffix BeginClose \
  DrainAbandoned ObserveFrontResolution FinishFrontResolution ResolveDetachedMember \
  ResolveRejected DetachUnknown CollectImage Close CrashAfterReturn Reopen
if test "$pipelined_adaptive_generated" -ne 1742242 || \
  test "$pipelined_adaptive_distinct" -ne 445238 || \
  test "$pipelined_adaptive_depth" -ne 51
then
  printf '%s\n' \
    'Flyology.DB TLA pipelined adaptive coalescing geometry changed' >&2
  exit 1
fi
pipelined_adaptive_expected_action_report="$temporary_root/pipelined-adaptive-action-coverage.expected.txt"
cat >"$pipelined_adaptive_expected_action_report" <<'EOF'
    Freeze 98:596
    RequestCancellation 0:113284
    StartBatch 202:956
    StoreBatch 526:3820
    CompleteBatch 2382:15280
    JoinBatch 2382:15280
    IgnoreStaleCompletion 0:45060
    ObserveBatch 220:1426
    StartHead 170:724
    ApplyHead 249:706
    RivalHead 14307:57793
    CompleteHead 3862:5790
    JoinHead 3774:5790
    RetireSuccess 2104:3248
    AbandonSuffix 4292:41094
    BeginClose 1952:71581
    DrainAbandoned 6016:10224
    ObserveFrontResolution 4236:7484
    FinishFrontResolution 6354:14120
    ResolveDetachedMember 16780:66028
    ResolveRejected 5430:9920
    DetachUnknown 2056:2616
    CollectImage 298612:505914
    Close 22669:132223
    CrashAfterReturn 25819:394660
    Reopen 20745:216624
EOF
if ! cmp "$pipelined_adaptive_expected_action_report" \
    "$pipelined_adaptive_action_report"
then
  printf '%s\n' \
    'Flyology.DB TLA pipelined adaptive coalescing action coverage changed:' >&2
  cat "$pipelined_adaptive_action_report" >&2
  exit 1
fi

for probe in \
  PipelinedAdaptiveAggregateCommitCoalescingHeadOrderProbe:OrderedHead \
  PipelinedAdaptiveAggregateCommitCoalescingVisibilityProbe:NoPrematureSuccess \
  PipelinedAdaptiveAggregateCommitCoalescingUnknownBarrierProbe:UnknownBarrier \
  PipelinedAdaptiveAggregateCommitCoalescingReplayProbe:NoReplay \
  PipelinedAdaptiveAggregateCommitCoalescingRebaseProbe:FrozenIdentity \
  PipelinedAdaptiveAggregateCommitCoalescingOwnershipProbe:Ownership \
  PipelinedAdaptiveAggregateCommitCoalescingStaleCompletionProbe:Ownership \
  PipelinedAdaptiveAggregateCommitCoalescingValidationProbe:ValidationPrefix \
  PipelinedAdaptiveAggregateCommitCoalescingResolutionTokenProbe:ResolutionBinding \
  PipelinedAdaptiveAggregateCommitCoalescingResolutionOrderProbe:\
NoPrematureResolutionSuccess \
  PipelinedAdaptiveAggregateCommitCoalescingDetachedResolutionProbe:ResolutionInstalled \
  PipelinedAdaptiveAggregateCommitCoalescingResolutionOwnershipProbe:ResolutionOwnership
do
  probe_module=${probe%%:*}
  probe_invariant=${probe#*:}
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-$probe_module-states" \
    -config "$probe_module.cfg" PipelinedAdaptiveAggregateCommitCoalescingProbes \
    >"$temporary_root/tlc-$probe_module.log" 2>&1
  probe_status=$?
  set -e
  if test "$probe_status" -ne 12
  then
    printf '%s\n' \
      "Flyology.DB TLA pipelined adaptive probe $probe_module exited $probe_status" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    if test "$probe_status" -eq 0
    then
      exit 1
    fi
    exit "$probe_status"
  fi
  grep -q "Invariant $probe_invariant is violated." \
    "$temporary_root/tlc-$probe_module.log"
  if grep -q '^Warning:' "$temporary_root/tlc-$probe_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA pipelined adaptive probe $probe_module warned" >&2
    cat "$temporary_root/tlc-$probe_module.log" >&2
    exit 1
  fi
done

for witness in \
  PipelinedAdaptiveAggregateCommitCoalescingOrderedSuccessWitness:OrderedSuccessPending \
  PipelinedAdaptiveAggregateCommitCoalescingPredecessorFailureWitness:\
PredecessorFailureOrphanPending \
  PipelinedAdaptiveAggregateCommitCoalescingUnknownCloseRecoveryWitness:\
UnknownCloseRecoveryPending \
  PipelinedAdaptiveAggregateCommitCoalescingCancellationLocalFailureWitness:\
CancellationLocalFailurePending \
  PipelinedAdaptiveAggregateCommitCoalescingActiveUnknownResolutionWitness:\
ActiveUnknownResolutionPending
do
  witness_module=${witness%%:*}
  witness_invariant=${witness#*:}
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -noGenerateSpecTE \
    -metadir "$temporary_root/tlc-$witness_module-states" \
    -config "$witness_module.cfg" PipelinedAdaptiveAggregateCommitCoalescingWitnesses \
    >"$temporary_root/tlc-$witness_module.log" 2>&1
  witness_status=$?
  set -e
  if test "$witness_status" -ne 12
  then
    printf '%s\n' \
      "Flyology.DB TLA pipelined adaptive witness $witness_module exited $witness_status" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    if test "$witness_status" -eq 0
    then
      exit 1
    fi
    exit "$witness_status"
  fi
  grep -q "Invariant $witness_invariant is violated." \
    "$temporary_root/tlc-$witness_module.log"
  if grep -q '^Warning:' "$temporary_root/tlc-$witness_module.log"
  then
    printf '%s\n' \
      "Flyology.DB TLA pipelined adaptive witness $witness_module warned" >&2
    cat "$temporary_root/tlc-$witness_module.log" >&2
    exit 1
  fi
done

set +e
"$tlapm" --cache-dir "$temporary_root/tlapm-pipelined-adaptive-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/PipelinedAdaptiveAggregateCommitCoalescingSafetyProof.tla" \
  >"$temporary_root/tlaps-pipelined-adaptive.log" 2>&1
pipelined_adaptive_tlaps_status=$?
set -e
if test "$pipelined_adaptive_tlaps_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA pipelined adaptive TLAPS exited $pipelined_adaptive_tlaps_status" >&2
  cat "$temporary_root/tlaps-pipelined-adaptive.log" >&2
  exit "$pipelined_adaptive_tlaps_status"
fi
if grep -q '^Warning:' "$temporary_root/tlaps-pipelined-adaptive.log"
then
  printf '%s\n' 'Flyology.DB TLA pipelined adaptive TLAPS warned' >&2
  cat "$temporary_root/tlaps-pipelined-adaptive.log" >&2
  exit 1
fi
pipelined_adaptive_tlaps_lines=$(grep -E \
  '^(\[INFO\]: )?All [0-9][0-9]* obligations proved[.]$' \
  "$temporary_root/tlaps-pipelined-adaptive.log" || :)
if test -z "$pipelined_adaptive_tlaps_lines" || \
  test "$(printf '%s\n' "$pipelined_adaptive_tlaps_lines" | wc -l | tr -d ' ')" -ne 1
then
  printf '%s\n' \
    'Flyology.DB TLA pipelined adaptive TLAPS summary missing or ambiguous' >&2
  cat "$temporary_root/tlaps-pipelined-adaptive.log" >&2
  exit 1
fi
if ! printf '%s\n' "$pipelined_adaptive_tlaps_lines" | \
  grep -Eq '^(\[INFO\]: )?All 118 obligations proved[.]$'
then
  printf '%s\n' 'Flyology.DB TLA pipelined adaptive TLAPS total changed' >&2
  cat "$temporary_root/tlaps-pipelined-adaptive.log" >&2
  exit 1
fi

aggregate_identity_report="$temporary_root/aggregate-identity-coverage.txt"
: >"$aggregate_identity_report"
for identity_case in normal collision
do
  case "$identity_case" in
    normal)
      identity_config=AggregateCommitIdentityReservationNormal.cfg
      identity_actions="Admit Freeze PublishBatch PublishHead"
      identity_expected_generated=8
      identity_expected_states=7
      identity_expected_depth=6
      ;;
    collision)
      identity_config=AggregateCommitIdentityReservationCollision.cfg
      identity_actions="Admit RejectCollision"
      identity_expected_generated=6
      identity_expected_states=5
      identity_expected_depth=4
      ;;
  esac
  identity_log="$temporary_root/tlc-aggregate-identity-$identity_case.log"
  set +e
  "$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
    -workers 1 -coverage 1 \
    -metadir "$temporary_root/tlc-aggregate-identity-$identity_case-states" \
    -config "$identity_config" AggregateCommitIdentityReservation \
    >"$identity_log" 2>&1
  identity_status=$?
  set -e
  if test "$identity_status" -ne 0
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate identity $identity_case TLC exited $identity_status" >&2
    cat "$identity_log" >&2
    exit "$identity_status"
  fi
  grep -q 'Model checking completed. No error has been found.' "$identity_log"
  if grep -q '^Warning:' "$identity_log"
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate identity $identity_case TLC warned" >&2
    cat "$identity_log" >&2
    exit 1
  fi
  identity_state_lines=$(grep -E \
    '^[1-9][0-9]* states generated, [1-9][0-9]* distinct states found, 0 states left on queue[.]$' \
    "$identity_log" || :)
  test -n "$identity_state_lines"
  test "$(printf '%s\n' "$identity_state_lines" | wc -l | tr -d ' ')" -eq 1
  identity_generated=$(printf '%s\n' "$identity_state_lines" | awk '{print $1}')
  identity_states=$(printf '%s\n' "$identity_state_lines" | awk '{print $4}')
  identity_depth_lines=$(grep -E \
    '^The depth of the complete state graph search is [1-9][0-9]*[.]$' \
    "$identity_log" || :)
  test -n "$identity_depth_lines"
  test "$(printf '%s\n' "$identity_depth_lines" | wc -l | tr -d ' ')" -eq 1
  identity_depth=$(printf '%s\n' "$identity_depth_lines" | \
    sed 's/^The depth of the complete state graph search is \([1-9][0-9]*\)[.]$/\1/')
  if test "$identity_generated" -ne "$identity_expected_generated" || \
    test "$identity_states" -ne "$identity_expected_states" || \
    test "$identity_depth" -ne "$identity_expected_depth"
  then
    printf '%s\n' \
      "Flyology.DB TLA aggregate identity $identity_case geometry changed" >&2
    cat "$identity_log" >&2
    exit 1
  fi
  printf '    %s %s generated, %s distinct, depth %s\n' \
    "$identity_case" "$identity_generated" "$identity_states" "$identity_depth" \
    >>"$aggregate_identity_report"
  for action in $identity_actions
  do
    identity_action_lines=$(grep -E "^<$action .*: [1-9][0-9]*(:[0-9]+)?$" \
      "$identity_log" || :)
    if test -z "$identity_action_lines"
    then
      printf '%s\n' \
        "Flyology.DB TLA aggregate identity $identity_case action $action missing" >&2
      exit 1
    fi
    printf '      %s reached\n' "$action" >>"$aggregate_identity_report"
  done
done

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-aggregate-identity-probe-states" \
  -config AggregateCommitIdentityReservationProbe.cfg \
  AggregateCommitIdentityReservationProbes \
  >"$temporary_root/tlc-aggregate-identity-probe.log" 2>&1
aggregate_identity_probe_status=$?
set -e
if test "$aggregate_identity_probe_status" -ne 12
then
  printf '%s\n' \
    "Flyology.DB TLA aggregate identity probe exited $aggregate_identity_probe_status" >&2
  cat "$temporary_root/tlc-aggregate-identity-probe.log" >&2
  if test "$aggregate_identity_probe_status" -eq 0
  then
    exit 1
  fi
  exit "$aggregate_identity_probe_status"
fi
grep -q 'Invariant NoAliasedFreeze is violated.' \
  "$temporary_root/tlc-aggregate-identity-probe.log"
if grep -q '^Warning:' "$temporary_root/tlc-aggregate-identity-probe.log"
then
  printf '%s\n' 'Flyology.DB TLA aggregate identity probe warned' >&2
  cat "$temporary_root/tlc-aggregate-identity-probe.log" >&2
  exit 1
fi

set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-aggregate-identity-witness-states" \
  -config AggregateCommitIdentityReservationWitness.cfg \
  AggregateCommitIdentityReservationWitness \
  >"$temporary_root/tlc-aggregate-identity-witness.log" 2>&1
aggregate_identity_witness_status=$?
set -e
if test "$aggregate_identity_witness_status" -ne 12
then
  printf '%s\n' \
    "Flyology.DB TLA aggregate identity witness exited $aggregate_identity_witness_status" >&2
  cat "$temporary_root/tlc-aggregate-identity-witness.log" >&2
  if test "$aggregate_identity_witness_status" -eq 0
  then
    exit 1
  fi
  exit "$aggregate_identity_witness_status"
fi
grep -q 'Invariant CollisionPending is violated.' \
  "$temporary_root/tlc-aggregate-identity-witness.log"
if grep -q '^Warning:' "$temporary_root/tlc-aggregate-identity-witness.log"
then
  printf '%s\n' 'Flyology.DB TLA aggregate identity witness warned' >&2
  cat "$temporary_root/tlc-aggregate-identity-witness.log" >&2
  exit 1
fi

set +e
"$tlapm" --cache-dir "$temporary_root/tlapm-aggregate-identity-cache" \
  --cleanfp --nofp --strict --method smt \
  "$model_root/AggregateCommitIdentityReservationSafetyProof.tla" \
  >"$temporary_root/tlaps-aggregate-identity.log" 2>&1
aggregate_identity_tlaps_status=$?
set -e
if test "$aggregate_identity_tlaps_status" -ne 0
then
  printf '%s\n' \
    "Flyology.DB TLA aggregate identity TLAPS exited $aggregate_identity_tlaps_status" >&2
  cat "$temporary_root/tlaps-aggregate-identity.log" >&2
  exit "$aggregate_identity_tlaps_status"
fi
if grep -q '^Warning:' "$temporary_root/tlaps-aggregate-identity.log"
then
  printf '%s\n' 'Flyology.DB TLA aggregate identity TLAPS warned' >&2
  cat "$temporary_root/tlaps-aggregate-identity.log" >&2
  exit 1
fi
aggregate_identity_tlaps_lines=$(grep -E \
  '^(\[INFO\]: )?All [1-9][0-9]* obligations proved[.]$' \
  "$temporary_root/tlaps-aggregate-identity.log" || :)
if test -z "$aggregate_identity_tlaps_lines" || \
  test "$(printf '%s\n' "$aggregate_identity_tlaps_lines" | wc -l | tr -d ' ')" -ne 1
then
  printf '%s\n' \
    'Flyology.DB TLA aggregate identity TLAPS summary missing or ambiguous' >&2
  cat "$temporary_root/tlaps-aggregate-identity.log" >&2
  exit 1
fi
aggregate_identity_obligations=$(printf '%s\n' "$aggregate_identity_tlaps_lines" | \
  sed -E 's/^(\[INFO\]: )?All ([1-9][0-9]*) obligations proved[.]$/\2/')
if test "$aggregate_identity_obligations" -ne 12
then
  printf '%s\n' \
    'Flyology.DB TLA aggregate identity obligation total changed:' >&2
  cat "$temporary_root/tlaps-aggregate-identity.log" >&2
  exit 1
fi

#  Replay the real two-member aggregate API boundary after complete quiescent
#  context/database/receipt loss. This adds one adapter trace; the four policy
#  replays above retain their existing arguments, behavior, and divergence.
aggregate_replay_module=AggregateCommitCoalescingAuthorityReplay
set +e
"$java_command" -Xmx2g -XX:+UseParallelGC -cp "$tlc_jar" tlc2.TLC \
  -workers 1 -noGenerateSpecTE \
  -metadir "$temporary_root/tlc-aggregate-authority-replay-states" \
  -config "$aggregate_replay_module.cfg" \
  -dumpTrace json "$temporary_root/aggregate-authority-replay.json" \
  "$aggregate_replay_module" \
  >"$temporary_root/tlc-aggregate-authority-replay.log" 2>&1
aggregate_replay_status=$?
set -e
if test "$aggregate_replay_status" -ne 12
then
  printf '%s\n' "Flyology.DB TLA aggregate authority witness exited $aggregate_replay_status" >&2
  cat "$temporary_root/tlc-aggregate-authority-replay.log" >&2
  exit 1
fi
grep -q 'Invariant WitnessPending is violated.' "$temporary_root/tlc-aggregate-authority-replay.log"
if grep -q '^Warning:' "$temporary_root/tlc-aggregate-authority-replay.log"
then
  printf '%s\n' 'Flyology.DB TLA aggregate authority replay warned' >&2
  cat "$temporary_root/tlc-aggregate-authority-replay.log" >&2
  exit 1
fi
check_trace "$temporary_root/aggregate-authority-replay.json" "$aggregate_replay_module"
aggregate_replay_trace=$(trace_path "$aggregate_replay_module")
aggregate_replay_result="$temporary_root/aggregate-authority-replay.result.json"
"$conformance_runner" --aggregate-authority --max-steps 8 \
  --format terse --result-json "$aggregate_replay_result" "$aggregate_replay_trace"
grep -q '"format":"flyology.tla.result/1","verdict":"conformant"' "$aggregate_replay_result"
grep -q '"compared_steps":8' "$aggregate_replay_result"
aggregate_replay_hash=$(sha256_file "$aggregate_replay_trace")
grep -q "\"trace_sha256\":\"$aggregate_replay_hash\"" "$aggregate_replay_result"

set +e
"$conformance_runner" --aggregate-authority --buggy --max-steps 8 \
  --format terse --result-json "$temporary_root/aggregate-authority-divergence.result.json" \
  "$aggregate_replay_trace" >"$temporary_root/aggregate-authority-divergence.log" 2>&1
aggregate_divergence_status=$?
set -e
test "$aggregate_divergence_status" -ne 0
grep -q '"verdict":"diverged"' "$temporary_root/aggregate-authority-divergence.result.json"
grep -q '"property":"tla-conformance"' "$temporary_root/aggregate-authority-divergence.result.json"
grep -q '"fingerprint":"state:AggregateCommitCoalescingAuthorityReplay!ResolveMember"' \
  "$temporary_root/aggregate-authority-divergence.result.json"

if test "${FLYOLOGY_DB_TLA_UPDATE_TRACES:-0}" = 1
then
  trace_inventory_before_copy="$temporary_root/trace-inventory.before-copy"
  write_trace_inventory "$trace_inventory_before_copy"
  cmp "$trace_inventory_before" "$trace_inventory_before_copy"
  for trace_module in LiveSuffixRegistryRecoveryWitness \
    LiveSuffixRegistryCancellationWitness AggregateCommitCoalescingAuthorityReplay
  do
    normalized_trace="$temporary_root/$trace_module.trace.json"
    canonical_trace="$trace_root/$trace_module.trace.json"
    test -f "$normalized_trace"
    test ! -L "$normalized_trace"
    if test -e "$canonical_trace" || test -L "$canonical_trace"
    then
      test -f "$canonical_trace"
      test ! -L "$canonical_trace"
      cmp "$normalized_trace" "$canonical_trace"
    fi
  done
  trace_inventory_expected="$temporary_root/trace-inventory.expected"
  cp "$trace_inventory_before" "$trace_inventory_expected.unsorted"
  for trace_module in LiveSuffixRegistryRecoveryWitness \
    LiveSuffixRegistryCancellationWitness AggregateCommitCoalescingAuthorityReplay
  do
    normalized_trace="$temporary_root/$trace_module.trace.json"
    canonical_trace="$trace_root/$trace_module.trace.json"
    if test ! -e "$canonical_trace" && test ! -L "$canonical_trace"
    then
      trace_hash=$(sha256_file "$normalized_trace")
      printf '%s  %s\n' "$trace_hash" "$trace_module.trace.json" \
        >>"$trace_inventory_expected.unsorted"
    fi
  done
  LC_ALL=C sort -k2,2 \
    "$trace_inventory_expected.unsorted" >"$trace_inventory_expected"
  for trace_module in LiveSuffixRegistryRecoveryWitness \
    LiveSuffixRegistryCancellationWitness AggregateCommitCoalescingAuthorityReplay
  do
    normalized_trace="$temporary_root/$trace_module.trace.json"
    canonical_trace="$trace_root/$trace_module.trace.json"
    if test ! -e "$canonical_trace" && test ! -L "$canonical_trace"
    then
      install_trace_no_clobber \
        "$normalized_trace" "$canonical_trace" "$trace_module"
    fi
  done
  trace_inventory_after="$temporary_root/trace-inventory.after"
  write_trace_inventory "$trace_inventory_after"
  cmp "$trace_inventory_expected" "$trace_inventory_after"
fi

printf '%s\n' "Flyology.DB TLA+ checks passed"
printf '%s\n' \
  "  TLC   $commit_publication_generated generated," \
  "        $commit_publication_states distinct, depth $commit_publication_depth"
printf '%s\n' "  CommitPublication action coverage"
cat "$commit_publication_action_report"
printf '%s\n' "  Durable commit authority accepted/rejected crash-import witnesses reached"
printf '%s\n' "  Durable commit authority malformed-swap probe detected"
printf '%s\n' "  Durable commit authority TLAPS 10/10 obligations"
printf '%s\n' "  TLAPS 23/23 obligations"
printf '%s\n' \
  "  Independent coalescing TLC $independent_coalescing_generated generated," \
  "        $independent_coalescing_states distinct, depth $independent_coalescing_depth"
printf '%s\n' "  Independent coalescing action coverage"
cat "$independent_coalescing_action_report"
printf '%s\n' \
  "  Independent coalescing TLAPS $independent_coalescing_obligations/16 obligations"
printf '%s\n' \
  "  Independent coalescing failure/deadline/authority/empty-recovery/fence witnesses reached"
printf '%s\n' \
  "  Negative independent-coalescing visibility/replay/fence/authority/"\
"recovery/deadline/failure probes detected"
printf '%s\n' \
  "  Aggregate coalescing TLC $aggregate_coalescing_generated generated," \
  "        $aggregate_coalescing_states distinct, depth $aggregate_coalescing_depth"
printf '%s\n' "  Aggregate coalescing action coverage"
cat "$aggregate_coalescing_action_report"
printf '%s\n' \
  "  Aggregate coalescing TLAPS $aggregate_coalescing_obligations obligations proved"
printf '%s\n' \
  "  Aggregate coalescing authority/cancellation/orphan/absent-identity witnesses reached"
printf '%s\n' \
  "  Negative aggregate visibility/replay/authority/cancellation/identity/orphan probes detected"
printf '%s\n' \
  "  Adaptive coalescing core TLC $adaptive_core_generated generated," \
  "        $adaptive_core_distinct distinct, depth $adaptive_core_depth" \
  "  Adaptive coalescing scheduler TLC $adaptive_scheduler_generated generated," \
  "        $adaptive_scheduler_distinct distinct, depth $adaptive_scheduler_depth" \
  "  Adaptive coalescing progress TLC $adaptive_progress_generated generated," \
  "        $adaptive_progress_distinct distinct, depth $adaptive_progress_depth"
printf '%s\n' "  Adaptive coalescing core action coverage"
cat "$adaptive_core_action_report"
printf '%s\n' "  Adaptive coalescing progress action coverage"
cat "$adaptive_progress_action_report"
printf '%s\n' \
  "  Adaptive coalescing TLAPS $adaptive_tlaps_obligations obligations proved" \
  "  Adaptive coalescing pre-admission/safety/progress/failure/recovery witnesses reached" \
  "  Negative adaptive visibility/replay/cancellation/split/alias/authority/identity probes detected"
printf '%s\n' \
  "  Pipelined adaptive coalescing TLC $pipelined_adaptive_generated generated," \
  "        $pipelined_adaptive_distinct distinct, depth $pipelined_adaptive_depth"
printf '%s\n' "  Pipelined adaptive coalescing action coverage"
cat "$pipelined_adaptive_action_report"
printf '%s\n' \
  "  Pipelined adaptive coalescing TLAPS 118/118 obligations" \
  "  Pipelined adaptive ordered/failure/unknown-close/cancellation/recovery witnesses reached" \
  "  Positive pipeline TLC excludes authority export/import/drop lifecycle actions" \
  "  Export/import recovery is witnessed; TLAPS abstracts lifecycle safety" \
  "  Negative pipelined head-order/visibility/unknown/replay/rebase/ownership/"\
"stale/validation/resolution-token/install/receipt-ownership probes detected"
printf '%s\n' "  Aggregate encoded-identity reservation TLC"
cat "$aggregate_identity_report"
printf '%s\n' \
  "  Aggregate encoded-identity TLAPS $aggregate_identity_obligations obligations proved"
printf '%s\n' \
  "  Aggregate encoded-identity collision witness/probe detected before publication"
printf '%s\n' "  Aggregate authority eight-step Ada recovery replay and sibling divergence passed"
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
printf '%s\n' \
  "  Live suffix registry TLC 26 generated, 18 distinct states, depth 9"
printf '%s\n' "  Live suffix registry action coverage"
cat "$live_suffix_action_report"
printf '%s\n' \
  "  Live suffix registry TLAPS 25/25 obligations"
printf '%s\n' "  Live suffix registry recovery/cancellation traces canonical"
printf '%s\n' \
  "  Negative live-suffix partition/fence/manifest-replay/HEAD-replay/rival probes detected"
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
