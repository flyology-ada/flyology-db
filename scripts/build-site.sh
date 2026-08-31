#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
site="$project_root/build/site"
kit="$project_root/vendor/website-kit"

case "$site" in
   "$project_root/build/site") ;;
   *) printf '%s\n' "refusing unexpected site output: $site" >&2; exit 1 ;;
esac

test -f "$kit/scripts/install-assets.mjs" || {
   printf '%s\n' "website-kit is missing; initialize vendor/website-kit" >&2
   exit 1
}

"$project_root/scripts/docs.sh"
rm -rf "$site"
mkdir -p "$project_root/build"
cp -R "$project_root/website" "$site"
rm -f "$site/AGENTS.md"
node "$kit/scripts/install-assets.mjs" "$site"
node "$project_root/scripts/build-benchmark-site-data.mjs" "$site"
mkdir -p "$site/api"
cp -R "$project_root/docs/api/." "$site/api/"
node "$project_root/scripts/resolve-api-links.mjs" "$site"
node "$project_root/scripts/cache-bust-site-assets.mjs" "$site"
touch "$site/.nojekyll"
node "$kit/scripts/check-site.mjs" "$site"
node "$project_root/scripts/verify-site-content.mjs" "$site"

test -s "$site/index.html"
test -s "$site/guide/index.html"
test -s "$site/guide/getting-started/index.html"
test -s "$site/guide/checkpoint-and-reopen/index.html"
test -s "$site/guide/families-and-maintenance/index.html"
test -s "$site/guide/certainty-and-authority/index.html"
test -s "$site/guide/storage-limits-and-ownership/index.html"
test -s "$site/architecture/index.html"
test -s "$site/support/index.html"
test -s "$site/benchmarks/index.html"
test -s "$site/api/index.html"
test "$(cat "$site/CNAME")" = "db.flyology.org"

printf '%s\n' "Flyology.DB site built at $site"
