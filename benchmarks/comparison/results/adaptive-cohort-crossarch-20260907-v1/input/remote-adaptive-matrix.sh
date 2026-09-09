#!/usr/bin/env bash
set -euo pipefail

export PATH=/root/.cargo/bin:/root/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

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
  /mnt/flyology-bench/experiments/adaptive-cohort-crossarch-20260907-v1-*/ ) ;;
  *) printf 'invalid experiment root: %s\n' "$experiment_root" >&2; exit 1 ;;
esac
[ -d "$input_root" ] || { printf 'missing input root\n' >&2; exit 1; }
[ -d "$reuse_source" ] || { printf 'missing retained source root\n' >&2; exit 1; }
[ ! -e "$source_root" ] || { printf 'source root already exists\n' >&2; exit 1; }
[ ! -e "$evidence_root" ] || { printf 'evidence root already exists\n' >&2; exit 1; }
[ ! -e "$scratch_root" ] || { printf 'scratch root already exists\n' >&2; exit 1; }

exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9 || { printf 'another benchmark campaign owns this host\n' >&2; exit 1; }

# shellcheck disable=SC1091
. "$input_root/source.env"
(cd "$input_root" && sha256sum -c inputs.sha256)

git clone "$input_root/source.bundle" "$source_root"
[ "$(git -C "$source_root" rev-parse HEAD)" = "$SOURCE_HEAD" ]
git -C "$source_root" apply --check --binary "$input_root/source.patch"
git -C "$source_root" apply --binary "$input_root/source.patch"
[ "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$SOURCE_DIFF_SHA256" ]
git -C "$source_root" apply --check "$input_root/linux-cpu-model.patch"
git -C "$source_root" apply "$input_root/linux-cpu-model.patch"
[ "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$MEASUREMENT_SOURCE_DIFF_SHA256" ]

copy_release_config()
{
  config_source=$1
  config_target=$2
  case "$architecture" in
    x86_64)
      expected_config_ads=ea6c67dcc3e3f806febe2b5f47f0fd911fd2923359c75a54e44605f2b3aea6f5
      expected_config_gpr=33d78e4ad164038483e1f239431514ded66c5f88ac00edc7569154df7df72ee9
      expected_config_h=f4dbd85d12ed6c7d675a83a8d8f75509a933f31587c2251b0211080eead968cd
      ;;
    arm64)
      expected_config_ads=314d5c322aa216fecc7571570b8019dec1bfbcca06ae292a83516728351c8c0a
      expected_config_gpr=d161527093e33dd5366c8d604c318a16e6c63dae2865731b5658845ca7d4a601
      expected_config_h=6ea517c182da2bd7b9baa8f03404b17f492debd08a915e38f5643943e0e4d505
      ;;
  esac
  [ "$(find "$config_source" -maxdepth 1 -type f | wc -l)" -eq 3 ]
  [ ! -e "$config_target" ]
  cp -a "$config_source" "$config_target"
  [ "$(sha256sum "$config_target/flyology_db_config.ads" | cut -d ' ' -f 1)" = \
    "$expected_config_ads" ]
  [ "$(sha256sum "$config_target/flyology_db_config.gpr" | cut -d ' ' -f 1)" = \
    "$expected_config_gpr" ]
  [ "$(sha256sum "$config_target/flyology_db_config.h" | cut -d ' ' -f 1)" = \
    "$expected_config_h" ]
  grep -F 'Build_Profile : Build_Profile_Kind := "release";' \
    "$config_target/flyology_db_config.gpr" >/dev/null
}

copy_release_config "$reuse_source/config" "$source_root/config"

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
  [ "$(git -C "$target" rev-parse HEAD)" = "$expected_commit" ]
  [ "$(git -C "$target" rev-parse 'HEAD^{tree}')" = "$expected_tree" ]
  [ -z "$(git -C "$target" status --porcelain --untracked-files=all)" ]
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
mkdir -p "$benchmark/.deps"
benchmark_db=$benchmark/.deps/flyology_db-fca74780
git clone "$input_root/source.bundle" "$benchmark_db"
git -C "$benchmark_db" apply --binary "$input_root/source.patch"
copy_release_config "$reuse_source/config" "$benchmark_db/config"
expected_db_pin=$(printf '%s\n%s' '[[pins]]' \
  "flyology_object_storage = { path='.deps/flyology-object-storage' }")
[ "$(tail -n 2 "$benchmark_db/alire.toml")" = "$expected_db_pin" ]
sed -i '/^\[\[pins\]\]$/,$d' "$benchmark_db/alire.toml"
sed -i '${/^$/d;}' "$benchmark_db/alire.toml"

indexed_source=$reuse_source/benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf
indexed_target=$benchmark/.deps/flyology_object_storage_0.1.0_5eaf79cf
[ -d "$indexed_source" ] && [ ! -L "$indexed_source" ]
cp -a "$indexed_source" "$indexed_target"
[ "$(sha256sum "$indexed_target/alire.toml" | cut -d ' ' -f 1)" = \
  c4f8e27e76bf4a2f584df7844cfbdcf6d6010586c91e25d7c49c0ebda3a5abd4 ]
[ "$(python3 "$source_root/benchmarks/comparison/aws/source-tree-digest.py" \
  "$indexed_target")" = \
  97e048bb7fa42eee3aeca832548859c8b39e64a1a8c7a2326c435398a866a172 ]

{
  printf 'architecture=%s\n' "$architecture"
  printf 'kernel=%s\n' "$(uname -srvmo)"
  printf 'alire=%s\n' "$(alr --version)"
  printf 'rust=%s\n' "$(rustc --version)"
  printf 'gcc=%s\n' "$(gcc --version | sed -n '1p')"
  printf 'source_head=%s\n' "$SOURCE_HEAD"
  printf 'source_diff_sha256=%s\n' "$SOURCE_DIFF_SHA256"
} > "$evidence_root/host.env"
lscpu -J > "$evidence_root/lscpu.json"
lsblk -O -J > "$evidence_root/lsblk.json"
"$power_detector" > "$evidence_root/power-before-build.env" || \
  [ "$?" -eq 2 ]

cargo build --manifest-path "$benchmark/slatedb/Cargo.toml" --release --locked
(
  cd "$source_root"
  FLYOLOGY_DB_FORCE_REBUILD=1 ./oracles/adapters/tidesdb/scripts/build.sh
)
(
  cd "$benchmark"
  alr build --release -- -f
)

panel=$benchmark/bin/flyology_db_benchmark_panel
[ -x "$panel" ]
sha256sum "$panel" "$benchmark/slatedb/target/release/libflyology_db_slatedb_benchmark.so" \
  > "$evidence_root/binaries.sha256"
export LD_LIBRARY_PATH="$benchmark/slatedb/target/release:\
$source_root/oracles/adapters/tidesdb/build:\
$source_root/oracles/adapters/tidesdb/build/upstream"
export FLYOLOGY_DB_BENCH_SCRATCH_ROOT=$scratch_root
export FLYOLOGY_BENCH_LOCK_PATH=/run/lock/flyology-bench-host-cpu.lock
python3 "$input_root/adaptive-matrix-driver.py" "$source_root" "$architecture" \
  "$evidence_root/matrix"
[ -z "$(find "$scratch_root" -mindepth 1 -print -quit)" ]
"$power_detector" > "$evidence_root/power-after.env" || [ "$?" -eq 2 ]
[ "$(git -C "$source_root" rev-parse HEAD)" = "$SOURCE_HEAD" ]
[ "$(git -C "$source_root" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1)" = \
  "$MEASUREMENT_SOURCE_DIFF_SHA256" ]
git -C "$source_root" status --short > "$evidence_root/source-status.txt"
cp "$input_root/source.env" "$evidence_root/source.env"
cp "$input_root/inputs.sha256" "$evidence_root/inputs.sha256"
printf '%s\n' 'Flyology.DB adaptive cross-architecture remote campaign passed' \
  > "$evidence_root/sentinel.txt"
(
  cd "$evidence_root"
  find . -type f ! -name sha256sums.txt -print0 | LC_ALL=C sort -z | \
    xargs -0 sha256sum > sha256sums.txt
)
tar -C "$evidence_root" -czf "$experiment_root/artifacts.tar.gz" .
printf '%s\n' 'Flyology.DB adaptive cross-architecture remote campaign passed'
