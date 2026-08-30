#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
api_output="$project_root/docs/api"
theme_output="$project_root/docs/gnatdoc/html"
website_kit="$project_root/vendor/website-kit"

case "$api_output:$theme_output" in
   "$project_root/docs/api:$project_root/docs/gnatdoc/html") ;;
   *) printf '%s\n' "refusing unexpected documentation output" >&2; exit 1 ;;
esac

test -f "$website_kit/scripts/render-gnatdoc-theme.mjs" || {
   printf '%s\n' \
     "website-kit is missing; run: git submodule update --init --recursive" >&2
   exit 1
}

if ! command -v gnatdoc >/dev/null 2>&1; then
   installed_gnatdoc="${ALIRE_INSTALL_PREFIX:-"$HOME/.alire"}/bin/gnatdoc"
   if [ ! -x "$installed_gnatdoc" ]; then
      printf '%s\n' \
        "gnatdoc not found; install it with: $alr install gnatdoc_bin=26.0.0" >&2
      exit 1
   fi
   PATH=$(dirname "$installed_gnatdoc"):$PATH
   export PATH
fi

gnatdoc_version=$(gnatdoc --version 2>&1 | sed -n '1p')
case "$gnatdoc_version" in
   "GNATdoc 26.0.0 "*) ;;
   *)
      printf '%s\n' "GNATdoc 26.0.0 is required; found: $gnatdoc_version" >&2
      exit 1
      ;;
esac

cd "$project_root"
"$alr" build
rm -rf "$api_output" "$theme_output"
node "$website_kit/scripts/render-gnatdoc-theme.mjs" \
  "$project_root/docs/gnatdoc-theme.json" "$theme_output"

gnatdoc_log=$(mktemp -t flyology-db-gnatdoc.XXXXXX)
trap 'rm -f "$gnatdoc_log"' EXIT HUP INT TERM
if ! "$alr" exec -- gnatdoc \
  --backend=html \
  --generate=public \
  --warnings \
  --style=leading \
  -P flyology_db.gpr \
  -O docs/api >"$gnatdoc_log" 2>&1
then
   cat "$gnatdoc_log" >&2
   exit 1
fi
if grep -q 'raised GNATDOC\.' "$gnatdoc_log"; then
   printf '%s\n' "GNATdoc reported an internal omission:" >&2
   grep 'raised GNATDOC\.' "$gnatdoc_log" >&2
   exit 1
fi
warning_total=$(awk '/: warning:/ { total += 1 } END { print total + 0 }' "$gnatdoc_log")
public_warning_total=$(awk \
  '/^flyology-db(-object_storage)?\.ads:.*: warning:/ { total += 1 } \
   END { print total + 0 }' "$gnatdoc_log")
printf '%s\n' \
  "GNATdoc completed: $warning_total warnings across the project closure; "\
"$public_warning_total in the two published DB specifications."
rm -f "$gnatdoc_log"
trap - EXIT HUP INT TERM

node "$project_root/scripts/normalize-gnatdoc-html.mjs" "$api_output"
node "$project_root/scripts/retain-gnatdoc-public-units.mjs" \
  "$api_output" "$project_root/docs/gnatdoc-public-units.txt"
mkdir -p "$api_output/fonts"
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" "$api_output/fonts/"
cp "$project_root/website/assets/brand/flyology-mark-transparent.svg" \
  "$api_output/flyology-mark.svg"
cp "$website_kit/assets/scripts/ada-highlight.js" "$api_output/ada-highlight.js"
node "$website_kit/scripts/build-api-search-index.mjs" "$api_output"
if grep -q 'FlyologyApiSearch = \[\];' "$api_output/search-index.js"; then
   printf '%s\n' "website-kit generated an empty API search index" >&2
   exit 1
fi
node "$project_root/scripts/check-gnatdoc-public-units.mjs" \
  "$api_output" "$project_root/docs/gnatdoc-public-units.txt"

test -s "$api_output/index.html"
test -s "$api_output/search-index.js"
test -s "$api_output/flyology-mark.svg"
test -s "$api_output/ada-highlight.js"
