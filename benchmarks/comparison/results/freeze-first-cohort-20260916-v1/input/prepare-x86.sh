#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/freeze-first-cohort-20260916-v1-x86_64
reuse=/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64/candidate
input=$root/input
source=$root/source
benchmark=$source/benchmarks/comparison
expected_head=613ad2b054725e99b73117f03ae38e213fdfaef7
source_diff=8c7e040fb3c56fb415f2acf8b7bd1063dbe692cea893ca497697bae02ff66c9c
expected_diff=ef9171ee9b7869609c25039eb8c8c43e427c568cb92e9b05ca103e692879b132
expected_runtime=9dde0115dc8e49feb8d1305b078d09c00591eb39c5e0e08918fb89357b035b9a

test "$(id -u)" -eq 0
test -d "$input"
test -d "$reuse/.deps/flyology-object-storage"
test ! -e "$source"
test ! -e "$root/evidence"
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
mkdir -p "$root/evidence" "$root/scratch"
export TMPDIR=$root/scratch
export PATH="/home/ubuntu/.cargo/bin:/root/.cargo/bin:$PATH"

(cd "$input" && sha256sum -c inputs.sha256) >"$root/evidence/input-checks.log"
git clone --quiet "$input/source.bundle" "$source"
test "$(git -C "$source" rev-parse HEAD)" = "$expected_head"
git -C "$source" apply --check --binary "$input/source.patch"
git -C "$source" apply --binary "$input/source.patch"
tar -C "$source" -xzf "$input/untracked.tar.gz"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$source_diff"
cp "$input/raw-freeze-body.adb" "$source/src/flyology-db.adb"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
test "$(sha256sum "$source/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  "$expected_runtime"
python3 "$source/benchmarks/comparison/aws/package-source.py" "$source" \
  "$root/evidence/untracked-recheck.json" "$root/evidence/untracked-recheck.tar.gz" \
  --allow-manifest "$input/untracked.json"
cmp "$input/untracked.json" "$root/evidence/untracked-recheck.json"

cp -a "$reuse/config" "$source/config"
cp -a "$reuse/alire" "$source/alire"
cp -a "$reuse/.deps" "$source/.deps"
mkdir -p "$benchmark/alire" "$benchmark/.deps" \
  "$source/oracles/adapters/tidesdb"
cp -a "$reuse/benchmarks/comparison/alire/alire.lock" "$benchmark/alire/alire.lock"
cp -a "$reuse/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf" \
  "$benchmark/.deps/flyology_object_storage_0.1.0_5eaf79cf"
git clone --quiet "$input/source.bundle" \
  "$benchmark/.deps/flyology_db-fca74780"
git -C "$benchmark/.deps/flyology_db-fca74780" apply --binary "$input/source.patch"
tar -C "$benchmark/.deps/flyology_db-fca74780" -xzf "$input/untracked.tar.gz"
cp "$input/raw-freeze-body.adb" \
  "$benchmark/.deps/flyology_db-fca74780/src/flyology-db.adb"
cmp "$source/src/flyology-db.adb" \
  "$benchmark/.deps/flyology_db-fca74780/src/flyology-db.adb"
cp -a "$reuse/config" "$benchmark/.deps/flyology_db-fca74780/config"
cp -a "$reuse/alire" "$benchmark/.deps/flyology_db-fca74780/alire"
cmp "$reuse/config/flyology_db_config.ads" \
  "$source/config/flyology_db_config.ads"
cmp "$reuse/config/flyology_db_config.gpr" \
  "$source/config/flyology_db_config.gpr"
cmp "$reuse/config/flyology_db_config.h" \
  "$source/config/flyology_db_config.h"
cmp "$reuse/alire/alire.lock" "$source/alire/alire.lock"
python3 - "$benchmark/.deps/flyology_db-fca74780/alire.toml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
pin = "\n[[pins]]\nflyology_object_storage = { path='.deps/flyology-object-storage' }\n"
if not text.endswith(pin):
    raise SystemExit("unexpected pinned-DB Object Storage manifest suffix")
path.write_text(text[: -len(pin)] + "\n", encoding="utf-8")
PY
mkdir -p "$source/.agents/skills/performance-testing/scripts"
cp -a "$input/check-power-profile.sh" \
  "$source/.agents/skills/performance-testing/scripts/check-power-profile.sh"

{
  printf 'architecture=%s\n' "$(uname -m)"
  printf 'kernel=%s\n' "$(uname -srvmo)"
  printf 'alire=%s\n' "$(alr --version)"
  printf 'rust=%s\n' "$(rustc --version)"
  printf 'gcc=%s\n' "$(gcc --version | sed -n '1p')"
  printf 'source_head=%s\n' "$expected_head"
  printf 'source_diff_sha256=%s\n' "$expected_diff"
} >"$root/evidence/host.env"
"$source/.agents/skills/performance-testing/scripts/check-power-profile.sh" \
  >"$root/evidence/power-before-build.env" || test "$?" -eq 2

cargo build --manifest-path "$benchmark/slatedb/Cargo.toml" --release --locked \
  >"$root/evidence/cargo-build.log" 2>&1
(
  cd "$source"
  FLYOLOGY_DB_FORCE_REBUILD=1 ./oracles/adapters/tidesdb/scripts/build.sh
) >"$root/evidence/tidesdb-build.log" 2>&1
(
  cd "$benchmark"
  alr build --release -- -f
) >"$root/evidence/ada-build.log" 2>&1
grep -F 'flyology-db.adb' "$root/evidence/ada-build.log" >/dev/null
grep -F 'flyology_db_benchmark_flyology.adb' "$root/evidence/ada-build.log" >/dev/null
grep -F 'flyology_db_benchmark_panel.adb' "$root/evidence/ada-build.log" >/dev/null
test -x "$benchmark/bin/flyology_db_benchmark_panel"
(
  cd "$benchmark"
  alr exec -- gprls -U -s -P flyology_db_benchmark.gpr
) >"$root/evidence/gpr-source-map.txt" 2>&1
if ! grep -F "$source/src/flyology-db.adb" \
  "$root/evidence/gpr-source-map.txt" >/dev/null
then
  grep -F "$benchmark/.deps/flyology_db-fca74780/src/flyology-db.adb" \
    "$root/evidence/gpr-source-map.txt" >/dev/null
fi
if grep -F "$reuse/src/flyology-db.adb" \
  "$root/evidence/gpr-source-map.txt" >/dev/null
then
  printf '%s\n' 'GPR selected an old benchmark runtime' >&2
  exit 1
fi
for marker in runtime_preparation_concurrency runtime_pipeline_depth
do
  strings "$benchmark/bin/flyology_db_benchmark_panel" | grep -F "$marker" >/dev/null
done
sha256sum "$benchmark/bin/flyology_db_benchmark_panel" \
  "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  >"$root/evidence/binaries.sha256"
export LD_LIBRARY_PATH="$benchmark/slatedb/target/release:\
$source/oracles/adapters/tidesdb/build:\
$source/oracles/adapters/tidesdb/build/upstream"
ldd "$benchmark/bin/flyology_db_benchmark_panel" \
  >"$root/evidence/panel-ldd.txt"
test "$(git -C "$source" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$expected_diff"
test "$(sha256sum "$source/src/flyology-db.adb" | cut -d ' ' -f 1)" = \
  "$expected_runtime"
cmp "$reuse/alire/alire.lock" "$source/alire/alire.lock"
cmp "$reuse/benchmarks/comparison/alire/alire.lock" \
  "$benchmark/alire/alire.lock"
cmp "$reuse/config/flyology_db_config.ads" \
  "$source/config/flyology_db_config.ads"
cmp "$reuse/config/flyology_db_config.gpr" \
  "$source/config/flyology_db_config.gpr"
cmp "$reuse/config/flyology_db_config.h" \
  "$source/config/flyology_db_config.h"
git -C "$source" status --short >"$root/evidence/source-status.txt"
printf '%s\n' 'Flyology.DB raw-freeze exact-source x86 build passed' \
  >"$root/evidence/build-sentinel.txt"
printf '%s\n' 'Flyology.DB raw-freeze exact-source x86 build passed'
