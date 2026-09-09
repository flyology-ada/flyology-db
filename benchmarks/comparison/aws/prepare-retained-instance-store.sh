#!/usr/bin/env bash
set -euo pipefail

mount_root=/mnt/flyology-bench

fail()
{
  printf '%s\n' "$*" >&2
  exit 1
}

validate_instance_store()
{
  local device=$1
  local holder_inventory
  local swap_inventory

  [ "$(lsblk -dn -o TYPE "$device")" = disk ] ||
    fail "instance-store candidate is not a whole disk: $device"
  [ "$(lsblk -dn -o MODEL "$device" | sed 's/[[:space:]]*$//')" = \
    'Amazon EC2 NVMe Instance Storage' ] ||
    fail "candidate is not EC2 NVMe instance storage: $device"
  [ "$(lsblk -nr -o PATH "$device" | wc -l | tr -d '[:space:]')" -eq 1 ] ||
    fail "instance-store candidate has child partitions: $device"
  swap_inventory=$(swapon --show=NAME --noheadings) ||
    fail "could not inspect active swap devices"
  case $'\n'"$swap_inventory"$'\n' in
    *$'\n'"$device"$'\n'*) fail "instance-store candidate is active swap: $device" ;;
  esac
  holder_inventory=$(find "/sys/class/block/${device##*/}/holders" \
    -mindepth 1 -maxdepth 1 -print -quit) ||
    fail "could not inspect instance-store kernel holders: $device"
  [ -z "$holder_inventory" ] ||
    fail "instance-store candidate has kernel holders: $device"
}

[ ! -L "$mount_root" ] || fail "retained benchmark mountpoint is a symbolic link"
if [ ! -e "$mount_root" ]; then
  mkdir -p "$mount_root" || fail "could not create retained benchmark mountpoint"
fi
[ -d "$mount_root" ] || fail "retained benchmark mountpoint is not a directory"

if mountpoint -q "$mount_root"; then
  mounted_device=$(findmnt -rn -o SOURCE --target "$mount_root") ||
    fail "could not identify retained benchmark volume"
  validate_instance_store "$mounted_device"
  mount_options=$(findmnt -rn -o OPTIONS --target "$mount_root") ||
    fail "could not inspect retained benchmark mount options"
  case ",$mount_options," in
    *,noatime,*) ;;
    *) fail "retained benchmark volume is not mounted with noatime" ;;
  esac
  printf '%s\n' "Flyology.DB retained instance store is ready: $mounted_device"
  exit 0
else
  mountpoint_status=$?
  [ "$mountpoint_status" -eq 32 ] ||
    fail "could not inspect retained benchmark mountpoint"
fi

block_inventory=$(lsblk -J -d -o PATH,TYPE,MODEL,MOUNTPOINT) ||
  fail "could not inspect block devices"
benchmark_disk=$(printf '%s\n' "$block_inventory" |
  jq -er '[.blockdevices[] | select(
      .type == "disk" and
      .model == "Amazon EC2 NVMe Instance Storage" and
      .mountpoint == null
    ) | .path] | if length == 1 then .[0] else error("wrong disk count") end') ||
  fail "expected exactly one unmounted EC2 NVMe instance-store disk"
validate_instance_store "$benchmark_disk"
mountpoint_inventory=$(lsblk -nr -o MOUNTPOINTS "$benchmark_disk") ||
  fail "could not inspect instance-store mountpoints"
[ -z "$(printf '%s' "$mountpoint_inventory" | tr -d '[:space:]')" ] ||
  fail "instance-store candidate or child is mounted"
mount_inventory=
if mount_inventory=$(findmnt -rn -S "$benchmark_disk"); then
  fail "instance-store candidate is present in the mount table"
else
  mount_status=$?
  [ "$mount_status" -eq 1 ] ||
    fail "could not inspect the instance-store mount table"
fi
[ -z "$mount_inventory" ] ||
  fail "instance-store candidate is present in the mount table"
signature_inventory=$(wipefs -n "$benchmark_disk") ||
  fail "could not inspect instance-store signatures"
[ -z "$signature_inventory" ] ||
  fail "instance-store candidate contains an existing signature"

mkfs.ext4 -F -L flyology-bench "$benchmark_disk"
mount -o noatime "$benchmark_disk" "$mount_root"
validate_instance_store "$(findmnt -rn -o SOURCE --target "$mount_root")"
printf '%s\n' "Flyology.DB retained instance store is ready: $benchmark_disk"
