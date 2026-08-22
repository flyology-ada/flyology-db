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
grep -q '105663 distinct states found' "$temporary_root/tlc-safety.log"
grep -q 'The depth of the complete state graph search is 14.' \
  "$temporary_root/tlc-safety.log"
for action in Prepare StoreBatch PublishHead ObserveSuccess \
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

"$model_root/witness_to_workload.py" "$temporary_root/witness.json" \
  >"$temporary_root/workload.ndjson"
cmp "$temporary_root/workload.ndjson" "$expected_workload"
"$project_root/oracles/contract/validate_workload.py" \
  "$project_root/oracles/contract/workload.schema.json" \
  "$expected_workload"

"$tlapm" --cache-dir "$temporary_root/tlapm-cache" --cleanfp --nofp \
  --strict --method smt "$model_root/PublicationSafetyProof.tla" \
  >"$temporary_root/tlaps.log" 2>&1
grep -q 'All 20 obligations proved.' "$temporary_root/tlaps.log"

printf '%s\n' "Flyology.DB TLA+ checks passed"
printf '%s\n' "  TLC   105663 distinct states, depth 14"
printf '%s\n' "  TLAPS 20/20 obligations"
printf '%s\n' "  Negative stale-publication probe detected"
printf '%s\n' "  Witness accepted-response loss, reconciliation, crash, recovery"
