#!/usr/bin/env bash
set -euo pipefail

architecture=$1
reuse_source=$2
experiment_root=$3
input_root=$experiment_root/input
source_root=$experiment_root/source
evidence_root=$experiment_root/evidence
scratch_root=$experiment_root/scratch

case "$architecture" in
  x86_64 | arm64) ;;
  *) printf 'unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac
case "$experiment_root/" in
  /mnt/flyology-bench/experiments/pipelined-adaptive-natural-20260914-v5-*/ ) ;;
  *) printf 'invalid experiment root: %s\n' "$experiment_root" >&2; exit 1 ;;
esac
test -d "$input_root"
test -d "$reuse_source"
test ! -e "$source_root"
test ! -e "$evidence_root"
test ! -e "$scratch_root"

exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9 || { printf '%s\n' 'another benchmark campaign owns this host' >&2; exit 1; }

if test -d /home/ubuntu/.cargo/bin
then
  export PATH="/home/ubuntu/.cargo/bin:$PATH"
fi
if test -d /root/.cargo/bin
then
  export PATH="/root/.cargo/bin:$PATH"
fi
command -v alr >/dev/null
command -v cargo >/dev/null
command -v rustc >/dev/null
command -v gcc >/dev/null

# shellcheck disable=SC1091
. "$input_root/source.env"
(cd "$input_root" && sha256sum -c inputs.sha256)

git clone "$input_root/source.bundle" "$source_root"
test "$(git -C "$source_root" rev-parse HEAD)" = "$SOURCE_HEAD"
git -C "$source_root" apply --check --binary "$input_root/source.patch"
git -C "$source_root" apply --binary "$input_root/source.patch"
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$SOURCE_DIFF_SHA256"

copy_release_config()
{
  config_source=$1
  config_target=$2
  case "$architecture" in
    x86_64)
      expected_ads=ea6c67dcc3e3f806febe2b5f47f0fd911fd2923359c75a54e44605f2b3aea6f5
      expected_gpr=33d78e4ad164038483e1f239431514ded66c5f88ac00edc7569154df7df72ee9
      expected_h=f4dbd85d12ed6c7d675a83a8d8f75509a933f31587c2251b0211080eead968cd
      expected_benchmark_lock=440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc
      ;;
    arm64)
      expected_ads=314d5c322aa216fecc7571570b8019dec1bfbcca06ae292a83516728351c8c0a
      expected_gpr=d161527093e33dd5366c8d604c318a16e6c63dae2865731b5658845ca7d4a601
      expected_h=6ea517c182da2bd7b9baa8f03404b17f492debd08a915e38f5643943e0e4d505
      expected_benchmark_lock=d7b7a12db435e5d2e441ef5e9fa80332a85ef502e819d712072c402aeb3c797d
      ;;
  esac
  test "$(find "$config_source" -maxdepth 1 -type f | wc -l)" -eq 3
  test ! -e "$config_target"
  cp -a "$config_source" "$config_target"
  test "$(sha256sum "$config_target/flyology_db_config.ads" | cut -d ' ' -f 1)" = \
    "$expected_ads"
  test "$(sha256sum "$config_target/flyology_db_config.gpr" | cut -d ' ' -f 1)" = \
    "$expected_gpr"
  test "$(sha256sum "$config_target/flyology_db_config.h" | cut -d ' ' -f 1)" = \
    "$expected_h"
  grep -F 'Build_Profile : Build_Profile_Kind := "release";' \
    "$config_target/flyology_db_config.gpr" >/dev/null
}

copy_release_config "$reuse_source/config" "$source_root/config"
mkdir -p "$source_root/alire"
install -m 0644 "$input_root/root-alire.lock" "$source_root/alire/alire.lock"
test "$(sha256sum "$source_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  "$ROOT_ALIRE_LOCK_SHA256"

power_detector=$source_root/.agents/skills/performance-testing/scripts/check-power-profile.sh
mkdir -p "$(dirname -- "$power_detector")" "$source_root/.deps" "$evidence_root" "$scratch_root"
install -m 0755 "$input_root/check-power-profile.sh" "$power_detector"

clone_exact()
{
  origin=$1
  expected_commit=$2
  expected_tree=$3
  target=$4
  git clone --no-local --no-checkout "$origin" "$target"
  git -C "$target" checkout --detach "$expected_commit"
  test "$(git -C "$target" rev-parse HEAD)" = "$expected_commit"
  test "$(git -C "$target" rev-parse 'HEAD^{tree}')" = "$expected_tree"
  test -z "$(git -C "$target" status --porcelain --untracked-files=all)"
}

clone_exact "$reuse_source/.deps/flyology-object-storage" \
  f65afbf28108bb9d81fac6dc15496857dc710796 \
  5b68b2b4d7fd11ecfd85b8256823776577ce1612 \
  "$source_root/.deps/flyology-object-storage"
git -C "$source_root/.deps/flyology-object-storage" remote set-url origin \
  https://github.com/flyology-ada/flyology-object-storage.git
clone_exact "$reuse_source/.deps/slatedb" \
  e0161973d8d7ffdede7c44725729838811674e99 \
  317d112e1706b04f07fb229e27658fb0ee46c038 \
  "$source_root/.deps/slatedb"
git -C "$source_root/.deps/slatedb" remote set-url origin \
  https://github.com/slatedb/slatedb.git
clone_exact "$reuse_source/.deps/tidesdb" \
  23a67a6531bc6c0b537d3696758c7879586dcfce \
  8988e80b36a9ef7277e3396f88e46fd315fe9bab \
  "$source_root/.deps/tidesdb"
git -C "$source_root/.deps/tidesdb" remote set-url origin \
  https://github.com/tidesdb/tidesdb.git

benchmark=$source_root/benchmarks/comparison
mkdir -p "$benchmark/.deps" "$benchmark/alire"
install -m 0644 "$reuse_source/benchmarks/comparison/alire/alire.lock" \
  "$benchmark/alire/alire.lock"
test "$(sha256sum "$benchmark/alire/alire.lock" | cut -d ' ' -f 1)" = \
  "$expected_benchmark_lock"
benchmark_db=$benchmark/.deps/flyology_db-fca74780
git clone "$input_root/source.bundle" "$benchmark_db"
git -C "$benchmark_db" apply --binary "$input_root/source.patch"
copy_release_config "$reuse_source/config" "$benchmark_db/config"
mkdir -p "$benchmark_db/alire"
install -m 0644 "$input_root/root-alire.lock" "$benchmark_db/alire/alire.lock"
python3 - "$benchmark_db/alire.toml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
pin = "\n[[pins]]\nflyology_object_storage = { path='.deps/flyology-object-storage' }\n"
if not text.endswith(pin):
    raise SystemExit("unexpected root Object Storage pin")
path.write_text(text[: -len(pin)] + "\n", encoding="utf-8")
PY

indexed_source=$reuse_source/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf
indexed_target=$benchmark/.deps/flyology_object_storage_0.1.0_5eaf79cf
test -d "$indexed_source"
test ! -L "$indexed_source"
cp -a "$indexed_source" "$indexed_target"
test "$(sha256sum "$indexed_target/alire.toml" | cut -d ' ' -f 1)" = \
  c4f8e27e76bf4a2f584df7844cfbdcf6d6010586c91e25d7c49c0ebda3a5abd4
test "$(python3 "$source_root/benchmarks/comparison/aws/source-tree-digest.py" \
  "$indexed_target")" = \
  97e048bb7fa42eee3aeca832548859c8b39e64a1a8c7a2326c435398a866a172

{
  printf 'architecture=%s\n' "$architecture"
  printf 'kernel=%s\n' "$(uname -srvmo)"
  printf 'alire=%s\n' "$(alr --version)"
  printf 'rust=%s\n' "$(rustc --version)"
  printf 'gcc=%s\n' "$(gcc --version | sed -n '1p')"
  printf 'source_head=%s\n' "$SOURCE_HEAD"
  printf 'source_diff_sha256=%s\n' "$SOURCE_DIFF_SHA256"
} >"$evidence_root/host.env"
lscpu -J >"$evidence_root/lscpu.json"
lsblk -O -J >"$evidence_root/lsblk.json"
"$power_detector" >"$evidence_root/power-before-build.env" || test "$?" -eq 2

cargo build --manifest-path "$benchmark/slatedb/Cargo.toml" --release --locked \
  >"$evidence_root/cargo-build.log" 2>&1
(
  cd "$source_root"
  FLYOLOGY_DB_FORCE_REBUILD=1 ./oracles/adapters/tidesdb/scripts/build.sh
) >"$evidence_root/tidesdb-build.log" 2>&1
(
  cd "$benchmark"
  alr build --release -- -f
) >"$evidence_root/ada-build.log" 2>&1
grep -F 'flyology-db.adb' "$evidence_root/ada-build.log" >/dev/null
grep -F 'flyology_db_benchmark_flyology.adb' "$evidence_root/ada-build.log" >/dev/null
grep -F 'flyology_db_benchmark_panel.adb' "$evidence_root/ada-build.log" >/dev/null
test "$(sha256sum "$benchmark/alire/alire.lock" | cut -d ' ' -f 1)" = \
  "$expected_benchmark_lock"
test "$(sha256sum "$source_root/alire/alire.lock" | cut -d ' ' -f 1)" = \
  "$ROOT_ALIRE_LOCK_SHA256"

panel=$benchmark/bin/flyology_db_benchmark_panel
test -x "$panel"
for marker in \
  FLYOLOGY_DB_BENCH_ADAPTIVE_PREPARATION_CONCURRENCY \
  FLYOLOGY_DB_BENCH_ADAPTIVE_PIPELINE_COHORTS \
  runtime_preparation_concurrency runtime_pipeline_depth
do
  strings "$panel" | grep -F "$marker" >/dev/null
done
sha256sum "$panel" "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  >"$evidence_root/binaries.sha256"
export LD_LIBRARY_PATH="$benchmark/slatedb/target/release:\
$source_root/oracles/adapters/tidesdb/build:\
$source_root/oracles/adapters/tidesdb/build/upstream"
ldd "$panel" >"$evidence_root/panel-ldd.txt"
grep -F "$source_root/oracles/adapters/tidesdb/build/libflyology_tidesdb_oracle.so" \
  "$evidence_root/panel-ldd.txt" >/dev/null
grep -F "$source_root/oracles/adapters/tidesdb/build/upstream/libtidesdb.so" \
  "$evidence_root/panel-ldd.txt" >/dev/null

export FLYOLOGY_DB_BENCH_SCRATCH_ROOT=$scratch_root
export FLYOLOGY_BENCH_LOCK_PATH=/run/lock/flyology-bench-host-cpu.lock
python3 "$input_root/natural-pipeline-driver.py" "$source_root" "$architecture" \
  "$evidence_root/matrix"
test -z "$(find "$scratch_root" -mindepth 1 -print -quit)"
"$power_detector" >"$evidence_root/power-after.env" || test "$?" -eq 2
test "$(git -C "$source_root" rev-parse HEAD)" = "$SOURCE_HEAD"
test "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$SOURCE_DIFF_SHA256"
git -C "$source_root" status --short >"$evidence_root/source-status.txt"
cp "$input_root/source.env" "$evidence_root/source.env"
cp "$input_root/inputs.sha256" "$evidence_root/inputs.sha256"
printf '%s\n' 'Flyology.DB natural adaptive-pipeline remote campaign passed' \
  >"$evidence_root/sentinel.txt"
(
  cd "$evidence_root"
  find . -type f ! -name sha256sums.txt -print0 | LC_ALL=C sort -z | \
    xargs -0 sha256sum >sha256sums.txt
)
tar -C "$evidence_root" -czf "$experiment_root/artifacts.tar.gz" .
printf '%s\n' 'Flyology.DB natural adaptive-pipeline remote campaign passed'
