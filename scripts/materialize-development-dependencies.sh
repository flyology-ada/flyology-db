#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
dependencies_root="$project_root/.deps"
dependency_path="$dependencies_root/flyology-object-storage"
dependency_origin="https://github.com/flyology-ada/flyology-object-storage.git"
dependency_commit="f65afbf28108bb9d81fac6dc15496857dc710796"
materialization_root=""

fail()
{
  printf '%s\n' "$*" >&2
  exit 1
}

validate_checkout()
{
  local checkout_path=$1

  [ ! -L "$checkout_path" ] || fail "dependency checkout must not be a symbolic link: $checkout_path"
  [ -d "$checkout_path" ] || fail "dependency checkout is not a directory: $checkout_path"
  [ "$(git -C "$checkout_path" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] ||
    fail "dependency target is not a Git checkout: $checkout_path"
  [ "$(git -C "$checkout_path" rev-parse --show-toplevel)" = "$checkout_path" ] ||
    fail "dependency checkout root does not match its target: $checkout_path"
  [ "$(git -C "$checkout_path" remote get-url origin)" = "$dependency_origin" ] ||
    fail "dependency checkout has an unexpected origin: $checkout_path"
  [ "$(git -C "$checkout_path" rev-parse HEAD)" = "$dependency_commit" ] ||
    fail "dependency checkout is not at the qualified commit: $checkout_path"
  [ -z "$(git -C "$checkout_path" status --porcelain --untracked-files=all)" ] ||
    fail "dependency checkout is not clean: $checkout_path"
}

cleanup_materialization_root()
{
  [ -n "$materialization_root" ] || return 0
  [ ! -L "$materialization_root" ] || fail "refusing to clean a symbolic-link temporary directory"
  [ -d "$materialization_root" ] || return 0
  [ "$(dirname -- "$materialization_root")" = "$dependencies_root" ] ||
    fail "refusing to clean a temporary directory outside .deps"
  case "$(basename -- "$materialization_root")" in
    .flyology-object-storage.materialize.*) ;;
    *) fail "refusing to clean an unexpected temporary directory" ;;
  esac
  rm -rf -- "$materialization_root"
}

trap cleanup_materialization_root EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ ! -L "$dependencies_root" ] || fail ".deps must not be a symbolic link"
if [ ! -e "$dependencies_root" ]; then
  mkdir -- "$dependencies_root"
fi
[ -d "$dependencies_root" ] || fail ".deps is not a directory"

if [ -e "$dependency_path" ] || [ -L "$dependency_path" ]; then
  validate_checkout "$dependency_path"
  printf '%s\n' "Flyology Object Storage dependency ready at $dependency_commit"
  exit 0
fi

materialization_root=$(mktemp -d "$dependencies_root/.flyology-object-storage.materialize.XXXXXX")
[ ! -L "$materialization_root" ] || fail "materialization temporary directory is a symbolic link"
[ -d "$materialization_root" ] || fail "materialization temporary directory was not created"
[ "$(dirname -- "$materialization_root")" = "$dependencies_root" ] ||
  fail "materialization temporary directory is outside .deps"

temporary_checkout="$materialization_root/checkout"
git clone --no-checkout -- "$dependency_origin" "$temporary_checkout"
git -C "$temporary_checkout" checkout --detach "$dependency_commit"
validate_checkout "$temporary_checkout"

[ ! -e "$dependency_path" ] && [ ! -L "$dependency_path" ] ||
  fail "dependency target appeared during materialization: $dependency_path"
mv -- "$temporary_checkout" "$dependency_path"
validate_checkout "$dependency_path"

printf '%s\n' "Flyology Object Storage dependency ready at $dependency_commit"
