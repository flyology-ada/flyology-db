#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
exec 9>/run/lock/flyology-db-aws-campaign.lock
flock -n 9
# The maintained panel itself owns this machine-wide CPU lock during timing.
# Do not hold a second flock description across the panel invocation.
flock -n /run/lock/flyology-bench-host-cpu.lock true
test "$(sha256sum /mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-screen-copy.py |
    cut -d ' ' -f 1)" = 753885bc4e9ff5c4c0af267e09713bb2872d6b9e0640168d45cbea0646f52147
python3 /mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-screen-copy.py
