#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr_command=$($project_root/scripts/find-alr.sh)
cli_root="$project_root/.deps/flyology-tla-cli"
toolchain_root="$project_root/.deps/flyology-tla-toolchain"
tla_cli="$cli_root/bin/flyology-tla"
source_marker="$cli_root/.flyology-tla-source-commit"
expected_harness_commit=faf06c48246931e30b7fe9c5c786660185925666

lock_has_harness() {
  lock_path=$1
  test -f "$lock_path" &&
    awk '
      $0 == "crate = \"flyology_tla\"" {
        found = 1
      }
      END {
        exit !found
      }
    ' "$lock_path"
}

lock_has_expected_harness() {
  lock_path=$1
  lock_has_harness "$lock_path" &&
    awk -v expected="$expected_harness_commit" '
      /^\[\[solution[.]state\]\]$/ {
        in_harness = 0
        in_origin = 0
      }
      $0 == "crate = \"flyology_tla\"" {
        in_harness = 1
      }
      in_harness && /^\[solution[.]state[.]release[.]origin\]$/ {
        in_origin = 1
      }
      in_harness && in_origin && /^commit = "/ {
        commit = $0
        sub(/^commit = "/, "", commit)
        sub(/"$/, "", commit)
        found = 1
      }
      END {
        exit !(found && commit == expected)
      }
    ' "$lock_path"
}

resolve_consumer() {
  consumer_root=$1
  cd "$consumer_root"
  if ! lock_has_harness "$consumer_root/alire/alire.lock"
  then
    "$alr_command" -n update
  elif ! lock_has_expected_harness "$consumer_root/alire/alire.lock" \
    || "$alr_command" show --solve 2>&1 | grep -q '^Dependencies (missing):'
  then
    "$alr_command" -n update flyology_tla
  fi
  consumer_resolution=$("$alr_command" show --solve 2>&1)
  ! printf '%s\n' "$consumer_resolution" | grep -q '^Dependencies (missing):'
  printf '%s\n' "$consumer_resolution" | grep -q 'flyology_tla=0[.]1[.]0-dev'
  lock_has_expected_harness "$consumer_root/alire/alire.lock"
}

cd "$project_root"
if ! "$alr_command" index | awk 'NR > 1 && $2 == "flyology" { found = 1 } END { exit !found }'
then
  "$alr_command" index --reset-community
  "$alr_command" index \
    --add=git+https://github.com/flyology-ada/alire-index.git \
    --name=flyology \
    --before=community
fi
"$alr_command" index --update-all
"$alr_command" show flyology_tla=0.1.0-dev --solve |
  grep -q "Origin: commit $expected_harness_commit "

resolve_consumer "$project_root"
resolve_consumer "$project_root/tests"
cd "$project_root"

if test ! -x "$tla_cli" \
  || test ! -f "$source_marker" \
  || test "$(cat "$source_marker")" != "$expected_harness_commit"
then
  "$alr_command" --force -n install flyology_tla=0.1.0-dev --prefix "$cli_root"
  printf '%s\n' "$expected_harness_commit" >"$source_marker"
fi

"$alr_command" -n install --info --prefix "$cli_root" |
  grep -q 'flyology_tla=0[.]1[.]0-dev'
"$tla_cli" --help | grep -q 'model identity MODULE[.]tla'

if test ! -d "$toolchain_root"
then
  "$tla_cli" toolchain install "$toolchain_root"
fi
"$tla_cli" toolchain verify "$toolchain_root"

printf '%s\n' "Flyology TLA+ harness is ready"
printf '%s\n' "  CLI       $tla_cli"
printf '%s\n' "  toolchain $toolchain_root"
