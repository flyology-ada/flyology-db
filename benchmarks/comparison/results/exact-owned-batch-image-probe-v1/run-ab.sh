#!/usr/bin/env bash
set -euo pipefail

root=/mnt/flyology-bench/experiments/exact-owned-batch-image-probe-v1
detector=/mnt/flyology-bench/experiments/transaction-payload-release-v1/benchmark-source/check-power-profile.sh
library_root=/mnt/flyology-bench/experiments/transaction-payload-release-v1/control/db
results=$root/results-v2

library_path="$library_root/benchmarks/comparison/slatedb/target/release"
library_path="$library_path:$library_root/oracles/adapters/tidesdb/build"
export LD_LIBRARY_PATH="$library_path:$library_root/oracles/adapters/tidesdb/build/upstream"

test ! -e "$results"
mkdir -p "$results/roots" "$results/smoke"
printf '%s\n' \
  'cycle,ordinal,group_size,variant,elapsed_nanoseconds,verified_keys,state_sha256,batch_objects,batch_digest' \
  >"$results/measurements.csv"

field () {
  local name=$1
  local log=$2
  local matches
  matches=$(sed -n "s/^$name= *//p" "$log")
  test "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l)" -eq 1
  printf '%s\n' "$matches"
}

detect_power () {
  local output=$1
  local status_file=$2
  local status
  set +e
  "$detector" >"$output" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" >"$status_file"
  case $status in
    0 | 2) ;;
    *) cat "$output" >&2; return "$status" ;;
  esac
  if [ -e "$results/power-profile.reference.txt" ]; then
    cmp "$results/power-profile.reference.txt" "$output"
    cmp "$results/power-profile-status.reference.txt" "$status_file"
  else
    cp "$output" "$results/power-profile.reference.txt"
    cp "$status_file" "$results/power-profile-status.reference.txt"
  fi
}

batch_inventory () {
  local data_root=$1
  local target=$2
  local objects=$data_root/buckets/flyology-db-benchmark/objects
  find "$objects" -maxdepth 1 -type f -name '*.fos' -print | while IFS= read -r path; do
    magic=$(dd if="$path" bs=1 count=8 status=none)
    test "$magic" = FOSOBJ05
    body_hex=$(dd if="$path" bs=1 skip=28 count=8 status=none | xxd -p -c 16)
    case $body_hex in
      '' | *[!0-9a-fA-F]*) return 1 ;;
    esac
    body_size=$((16#$body_hex))
    test "$body_size" -gt 0
    file_size=$(wc -c <"$path")
    test "$file_size" -ge "$((36 + body_size))"
    encoded=${path##*/}
    encoded=${encoded%.fos}
    key=$(printf '%s' "$encoded" | xxd -r -p)
    case $key in
      database/commits/*)
        batch_magic=$(tail -c "$body_size" "$path" | dd bs=1 count=8 status=none)
        test "$batch_magic" = FLYBATC1
        header_hex=$(tail -c "$body_size" "$path" | dd bs=1 skip=28 count=4 status=none | xxd -p -c 16)
        payload_hex=$(tail -c "$body_size" "$path" | dd bs=1 skip=32 count=8 status=none | xxd -p -c 16)
        case $header_hex:$payload_hex in
          *[!0-9a-fA-F:]*) return 1 ;;
        esac
        header_size=$((16#$header_hex))
        payload_size=$((16#$payload_hex))
        test "$body_size" -eq "$((header_size + payload_size + 4))"
        printf '%s  %s\n' \
          "$(tail -c "$body_size" "$path" | sha256sum | cut -d ' ' -f 1)" "$key"
        ;;
    esac
  done | LC_ALL=C sort -k2 >"$target"
}

run_one () {
  local phase=$1
  local cycle=$2
  local ordinal=$3
  local group_size=$4
  local variant=$5
  local base="$results/$phase/$cycle-$ordinal-group-$group_size-$variant"
  local data_root="$results/roots/$phase-$cycle-$ordinal-group-$group_size-$variant"
  local log=$base.log
  local inventory=$base.batches.txt
  local elapsed verified state object_total object_digest

  mkdir -p "$(dirname "$base")"
  test ! -e "$data_root"
  detect_power "$base.power.txt" "$base.power-status.txt"
  FLYOLOGY_DB_GROUP_SIZE=$group_size \
    "$root/$variant/binaries/flyology_db_benchmark" \
      local "$data_root" 8 32 16 1024 256 >"$log" 2>&1
  elapsed=$(field elapsed_nanoseconds "$log")
  verified=$(field verified_keys "$log")
  state=$(field state_sha256 "$log")
  case $elapsed in
    '' | *[!0-9]*) return 1 ;;
  esac
  test "$elapsed" -gt 0
  test "$verified" = 10240
  test "$state" = 5283189c4531950d9f91a1aff1212a3cd36d69a2768ee759aa801ee3471b79a9
  batch_inventory "$data_root" "$inventory"
  object_total=$(wc -l <"$inventory" | tr -d ' ')
  test "$object_total" -eq "$((40 / group_size))"
  object_digest=$(sha256sum "$inventory" | cut -d ' ' -f 1)
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$cycle" "$ordinal" "$group_size" "$variant" "$elapsed" "$verified" \
    "$state" "$object_total" "$object_digest" >>"$results/measurements.csv"
}

for group_size in 1 2 4 8; do
  run_one smoke "$group_size" 1 "$group_size" control
  run_one smoke "$group_size" 2 "$group_size" candidate
  cmp \
    "$results/smoke/$group_size-1-group-$group_size-control.batches.txt" \
    "$results/smoke/$group_size-2-group-$group_size-candidate.batches.txt"
done

for cycle in 1 2 3 4 5 6 7 8; do
  if [ "$((cycle % 2))" -eq 1 ]; then
    first=control
    second=candidate
  else
    first=candidate
    second=control
  fi
  ordinal=0
  for group_size in 1 8; do
    for variant in "$first" "$second"; do
      ordinal=$((ordinal + 1))
      run_one measured "$cycle" "$ordinal" "$group_size" "$variant"
    done
    cmp \
      "$results/measured/$cycle-$((ordinal - 1))-group-$group_size-$first.batches.txt" \
      "$results/measured/$cycle-$ordinal-group-$group_size-$second.batches.txt"
  done
done

sha256sum "$results/measurements.csv" "$root"/*/binaries/flyology_db_benchmark \
  >"$results/sha256sums.txt"
printf '%s\n' EXACT_OWNED_BATCH_IMAGE_AB_COMPLETE
