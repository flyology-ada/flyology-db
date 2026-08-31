#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
power_detector=$repository/.agents/skills/performance-testing/scripts/check-power-profile.sh

usage()
{
  cat <<'EOF'
Usage: run-aws-nitro-campaign.sh AWS_PROFILE INSTANCE_TYPE [options]
       run-aws-nitro-campaign.sh rerun AWS_PROFILE EVIDENCE_DIRECTORY [options]
       run-aws-nitro-campaign.sh teardown AWS_PROFILE EVIDENCE_DIRECTORY [options]

Required:
  AWS_PROFILE       Configured AWS CLI profile
  INSTANCE_TYPE     x86-64 Nitro type with exactly one instance-store disk

Options:
  --region REGION   AWS region (default: us-west-2)
  --output PATH     New local evidence directory
  --include-untracked PATH
                    Admit one intentional Git-relative untracked source path
  --keep-instance   Keep EC2 instance, key pair, and security group

Teardown:
  EVIDENCE_DIRECTORY
                    Retained campaign directory containing instance.json,
                    caller-identity.json, and instance-key.pem
  --region REGION   AWS region used by the campaign (default: us-west-2)

Rerun:
  EVIDENCE_DIRECTORY
                    Original retained-host campaign containing instance.json
                    caller-identity.json, instance-key.pem, and, for current
                    campaigns, key-pair.json and known_hosts
  --region REGION   AWS region used by the campaign (default: us-west-2)
  --output PATH     New local evidence directory
  --include-untracked PATH
                    Admit one intentional Git-relative untracked source path
EOF
}

fail()
{
  printf '%s\n' "$*" >&2
  exit 1
}

rsa_private_fingerprint()
{
  openssl pkcs8 -in "$1" -inform PEM -outform DER -topk8 -nocrypt 2>/dev/null |
    openssl sha1 -c | sed 's/^SHA1(stdin)= //'
}

capture_console_host_key()
{
  console_profile=$1
  console_region=$2
  console_instance_id=$3
  console_public_ip=$4
  console_target=$5
  console_record=$6
  console_attempt=1
  while [ "$console_attempt" -le 40 ]; do
    if aws --profile "$console_profile" --region "$console_region" \
      ec2 get-console-output --instance-id "$console_instance_id" --latest \
      --output json > "$console_record"; then
      console_host_keys=$(
        jq -r '.Output // ""' "$console_record" |
          awk '$1 == "ssh-ed25519" && NF >= 2 { print $1 " " $2 }'
      )
      console_host_key_count=$(printf '%s\n' "$console_host_keys" | awk 'NF { count++ } END {
        print count + 0
      }')
      if [ "$console_host_key_count" -eq 1 ]; then
        printf '%s %s\n' "$console_public_ip" "$console_host_keys" > "$console_target"
        chmod 0600 "$console_target"
        return 0
      fi
      [ "$console_host_key_count" -le 1 ] ||
        fail 'AWS console output contains ambiguous ED25519 host keys'
    fi
    [ "$console_attempt" -lt 40 ] || break
    sleep 5
    console_attempt=$((console_attempt + 1))
  done
  fail 'AWS console output did not establish one ED25519 SSH host key'
}

teardown_kept_host()
{
  [ "$#" -ge 2 ] || {
    usage >&2
    exit 2
  }
  teardown_profile=$1
  teardown_evidence=$2
  shift 2
  teardown_region=us-west-2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --region)
        [ "$#" -ge 2 ] || fail '--region requires a value'
        teardown_region=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) fail "unknown teardown argument: $1" ;;
    esac
  done
  case "$teardown_region" in
    '' | *[!a-z0-9-]*) fail "invalid AWS region: $teardown_region" ;;
  esac
  for command in aws jq openssl sed; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
  done
  [ -d "$teardown_evidence" ] || fail "evidence directory is absent: $teardown_evidence"
  teardown_evidence=$(CDPATH= cd -- "$teardown_evidence" && pwd -P)
  case "$teardown_evidence/" in
    "$repository/benchmarks/comparison/results/aws-nitro-"*/) ;;
    *) fail "teardown evidence is outside the admitted campaign results: $teardown_evidence" ;;
  esac
  teardown_instance_file=$teardown_evidence/instance.json
  teardown_identity_file=$teardown_evidence/caller-identity.json
  teardown_key_pair_file=$teardown_evidence/key-pair.json
  teardown_key_path=$teardown_evidence/instance-key.pem
  [ -f "$teardown_instance_file" ] || fail "instance evidence is absent: $teardown_instance_file"
  [ -f "$teardown_identity_file" ] || fail "caller identity is absent: $teardown_identity_file"
  [ -f "$teardown_key_path" ] && [ ! -L "$teardown_key_path" ] ||
    fail "retained PEM is absent or symbolic: $teardown_key_path"
  [ "$(jq '[.Reservations[].Instances[]] | length' "$teardown_instance_file")" -eq 1 ] ||
    fail 'instance evidence must describe exactly one instance'

  teardown_instance_id=$(jq -r '.Reservations[].Instances[].InstanceId' "$teardown_instance_file")
  teardown_key_name=$(jq -r '.Reservations[].Instances[].KeyName' "$teardown_instance_file")
  teardown_public_ip=$(jq -r '.Reservations[].Instances[].PublicIpAddress' "$teardown_instance_file")
  teardown_group_count=$(jq '[.Reservations[].Instances[].SecurityGroups[]] | length' \
    "$teardown_instance_file")
  [ "$teardown_group_count" -eq 1 ] ||
    fail 'instance evidence must describe exactly one security group'
  teardown_group_id=$(jq -r '.Reservations[].Instances[].SecurityGroups[].GroupId' \
    "$teardown_instance_file")
  teardown_group_name=$(jq -r '.Reservations[].Instances[].SecurityGroups[].GroupName' \
    "$teardown_instance_file")
  teardown_pem_fingerprint=$(rsa_private_fingerprint "$teardown_key_path")
  teardown_key_pair_id=
  teardown_key_fingerprint=$teardown_pem_fingerprint
  if [ -f "$teardown_key_pair_file" ]; then
    teardown_key_pair_id=$(jq -r '.KeyPairId' "$teardown_key_pair_file")
    teardown_key_fingerprint=$(jq -r '.KeyFingerprint' "$teardown_key_pair_file")
    [ "$(jq -r '.KeyName' "$teardown_key_pair_file")" = "$teardown_key_name" ] ||
      fail 'key-pair evidence name does not match instance evidence'
    [ "$(jq -r '.KeyType' "$teardown_key_pair_file")" = rsa ] ||
      fail 'retained benchmark key is not RSA'
    [ "$teardown_pem_fingerprint" = "$teardown_key_fingerprint" ] ||
      fail 'retained PEM does not match evidenced AWS key fingerprint'
  fi
  teardown_evidenced_name=$(jq -r \
    '[.Reservations[].Instances[].Tags[] | select(.Key == "Name") | .Value] |
     if length == 1 then .[0] else "" end' "$teardown_instance_file")
  teardown_evidenced_purpose=$(jq -r \
    '[.Reservations[].Instances[].Tags[] | select(.Key == "Purpose") | .Value] |
     if length == 1 then .[0] else "" end' "$teardown_instance_file")
  teardown_evidenced_campaign=$(jq -r \
    '[.Reservations[].Instances[].Tags[] | select(.Key == "CampaignId") | .Value] |
     if length == 0 then "" elif length == 1 then .[0] else error("ambiguous CampaignId") end' \
    "$teardown_instance_file")
  teardown_allocation_id=$(jq -r \
    '[.Reservations[].Instances[].NetworkInterfaces[].Association.AllocationId // empty] | unique |
     if length == 0 then "" elif length == 1 then .[0] else error("multiple IPv4 allocations") end' \
    "$teardown_instance_file")
  case "$teardown_instance_id" in
    i-[0-9a-f]*) ;;
    *) fail "invalid evidenced instance ID: $teardown_instance_id" ;;
  esac
  case "$teardown_group_id" in
    sg-[0-9a-f]*) ;;
    *) fail "invalid evidenced security group ID: $teardown_group_id" ;;
  esac
  case "$teardown_public_ip" in
    *.*.*.*) ;;
    *) fail "invalid evidenced public IPv4 address: $teardown_public_ip" ;;
  esac
  [ "$teardown_evidenced_name" = "$teardown_key_name" ] ||
    fail 'evidenced instance Name tag does not match its key name'
  [ "$teardown_evidenced_purpose" = FlyologyDBBenchmark ] ||
    fail 'evidenced instance purpose tag is missing or ambiguous'
  if [ -n "$teardown_evidenced_campaign" ]; then
    [ "$teardown_evidenced_campaign" = "$teardown_key_name" ] ||
      fail 'evidenced campaign identity does not match its key name'
  fi

  teardown_aws=(aws --profile "$teardown_profile" --region "$teardown_region")
  teardown_temporary=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-aws-teardown.XXXXXX")
  teardown_cleanup()
  {
    teardown_cleanup_status=$?
    trap - EXIT
    rm -rf -- "$teardown_temporary"
    exit "$teardown_cleanup_status"
  }
  trap teardown_cleanup EXIT
  "${teardown_aws[@]}" sts get-caller-identity > "$teardown_temporary/caller-identity.json"
  [ "$(jq -r '.Account' "$teardown_temporary/caller-identity.json")" = \
    "$(jq -r '.Account' "$teardown_identity_file")" ] ||
    fail 'live AWS account does not match retained evidence'

  teardown_instance_exists=true
  if ! "${teardown_aws[@]}" ec2 describe-instances --instance-ids "$teardown_instance_id" \
    --output json > "$teardown_temporary/instance.json" \
    2> "$teardown_temporary/instance.err"; then
    grep -F 'InvalidInstanceID.NotFound' "$teardown_temporary/instance.err" >/dev/null ||
      fail 'live instance reconciliation failed'
    teardown_instance_exists=false
  fi
  if [ "$teardown_instance_exists" = true ]; then
    teardown_live_json=$(<"$teardown_temporary/instance.json")
    [ "$(jq '[.Reservations[].Instances[]] | length' <<<"$teardown_live_json")" -eq 1 ] ||
      fail 'live query must resolve exactly one instance'
    [ "$(jq -r '.Reservations[].Instances[].KeyName' <<<"$teardown_live_json")" = \
      "$teardown_key_name" ] || fail 'live instance key does not match retained evidence'
    [ "$(jq '[.Reservations[].Instances[].SecurityGroups[]] | length' \
      <<<"$teardown_live_json")" -eq 1 ] || fail 'live security group inventory is ambiguous'
    [ "$(jq -r '.Reservations[].Instances[].SecurityGroups[].GroupId' \
      <<<"$teardown_live_json")" = "$teardown_group_id" ] ||
      fail 'live instance security group does not match retained evidence'
    [ "$(jq -r '[.Reservations[].Instances[].Tags[] | select(.Key == "Name") | .Value] |
      if length == 1 then .[0] else "" end' <<<"$teardown_live_json")" = \
      "$teardown_evidenced_name" ] || fail 'live instance Name tag differs from evidence'
    [ "$(jq -r '[.Reservations[].Instances[].Tags[] | select(.Key == "Purpose") | .Value] |
      if length == 1 then .[0] else "" end' <<<"$teardown_live_json")" = \
      "$teardown_evidenced_purpose" ] || fail 'live instance purpose tag differs from evidence'
    teardown_live_campaign=$(jq -r \
      '[.Reservations[].Instances[].Tags[] | select(.Key == "CampaignId") | .Value] |
       if length == 0 then "" elif length == 1 then .[0] else error("ambiguous CampaignId") end' \
      <<<"$teardown_live_json")
    [ "$teardown_live_campaign" = "$teardown_evidenced_campaign" ] ||
      fail 'live campaign identity does not match retained evidence'
    teardown_state=$(jq -r '.Reservations[].Instances[].State.Name' <<<"$teardown_live_json")
    teardown_live_ip=$(jq -r '.Reservations[].Instances[].PublicIpAddress // ""' \
      <<<"$teardown_live_json")
    teardown_live_allocation=$(jq -r \
      '[.Reservations[].Instances[].NetworkInterfaces[].Association.AllocationId // empty] |
       unique | if length == 0 then "" elif length == 1 then .[0]
       else error("multiple IPv4 allocations") end' <<<"$teardown_live_json")
    if [ "$teardown_state" != terminated ]; then
      if [ -n "$teardown_live_ip" ]; then
        [ "$teardown_live_ip" = "$teardown_public_ip" ] ||
          fail 'live public IPv4 address does not match retained evidence'
      fi
      [ "$teardown_live_allocation" = "$teardown_allocation_id" ] ||
        fail 'live IPv4 allocation does not match retained evidence'
    fi
  else
    teardown_state=absent
  fi

  if [ "$teardown_state" != terminated ] && [ "$teardown_state" != absent ]; then
    "${teardown_aws[@]}" ec2 terminate-instances \
      --instance-ids "$teardown_instance_id" >/dev/null
    "${teardown_aws[@]}" ec2 wait instance-terminated \
      --instance-ids "$teardown_instance_id"
  fi
  if [ -n "$teardown_allocation_id" ]; then
    teardown_allocation_exists=true
    if ! "${teardown_aws[@]}" ec2 describe-addresses \
      --allocation-ids "$teardown_allocation_id" --output json \
      > "$teardown_temporary/address.json" 2> "$teardown_temporary/address.err"; then
      grep -F 'InvalidAllocationID.NotFound' "$teardown_temporary/address.err" >/dev/null ||
        fail 'live IPv4 allocation reconciliation failed'
      teardown_allocation_exists=false
    fi
    if [ "$teardown_allocation_exists" = true ]; then
      [ "$(jq -r '.Addresses | length' "$teardown_temporary/address.json")" -eq 1 ] ||
        fail 'live IPv4 allocation is ambiguous'
      [ "$(jq -r '.Addresses[0].PublicIp' "$teardown_temporary/address.json")" = \
        "$teardown_public_ip" ] || fail 'live allocated IPv4 differs from evidence'
      "${teardown_aws[@]}" ec2 release-address --allocation-id "$teardown_allocation_id"
    fi
  fi
  [ "$("${teardown_aws[@]}" ec2 describe-addresses \
    --filters "Name=public-ip,Values=$teardown_public_ip" \
    --query 'length(Addresses)' --output text)" -eq 0 ] ||
    fail "public IPv4 address remains allocated: $teardown_public_ip"
  teardown_key_exists=true
  teardown_key_selector=(--key-names "$teardown_key_name")
  if [ -n "$teardown_key_pair_id" ]; then
    teardown_key_selector=(--key-pair-ids "$teardown_key_pair_id")
  fi
  if ! "${teardown_aws[@]}" ec2 describe-key-pairs "${teardown_key_selector[@]}" \
    --output json > "$teardown_temporary/key.json" 2> "$teardown_temporary/key.err"; then
    grep -F 'InvalidKeyPair.NotFound' "$teardown_temporary/key.err" >/dev/null ||
      fail 'live AWS key-pair reconciliation failed'
    teardown_key_exists=false
  fi
  if [ "$teardown_key_exists" = true ]; then
    [ "$(jq -r '.KeyPairs | length' "$teardown_temporary/key.json")" -eq 1 ] ||
      fail 'live AWS key-pair inventory is ambiguous'
    [ "$(jq -r '.KeyPairs[0].KeyName' "$teardown_temporary/key.json")" = \
      "$teardown_key_name" ] || fail 'live AWS key-pair name differs from evidence'
    [ "$(jq -r '.KeyPairs[0].KeyFingerprint' "$teardown_temporary/key.json")" = \
      "$teardown_key_fingerprint" ] || fail 'live AWS key-pair fingerprint differs from evidence'
    teardown_key_pair_id=$(jq -r '.KeyPairs[0].KeyPairId' "$teardown_temporary/key.json")
    "${teardown_aws[@]}" ec2 delete-key-pair \
      --key-pair-id "$teardown_key_pair_id" >/dev/null
  fi

  teardown_group_exists=true
  if ! "${teardown_aws[@]}" ec2 describe-security-groups --group-ids "$teardown_group_id" \
    --output json > "$teardown_temporary/group.json" 2> "$teardown_temporary/group.err"; then
    grep -F 'InvalidGroup.NotFound' "$teardown_temporary/group.err" >/dev/null ||
      fail 'live security-group reconciliation failed'
    teardown_group_exists=false
  fi
  if [ "$teardown_group_exists" = true ]; then
    [ "$(jq -r '.SecurityGroups | length' "$teardown_temporary/group.json")" -eq 1 ] ||
      fail 'live security-group inventory is ambiguous'
    [ "$(jq -r '.SecurityGroups[0].GroupName' "$teardown_temporary/group.json")" = \
      "$teardown_group_name" ] || fail 'live security-group name differs from evidence'
    teardown_attempt=1
    teardown_group_deleted=false
    while [ "$teardown_attempt" -le 12 ]; do
      if "${teardown_aws[@]}" ec2 delete-security-group \
        --group-id "$teardown_group_id" >/dev/null 2>&1; then
        teardown_group_deleted=true
        break
      fi
      [ "$teardown_attempt" -lt 12 ] && sleep 5
      teardown_attempt=$((teardown_attempt + 1))
    done
    [ "$teardown_group_deleted" = true ] ||
      fail "failed to delete security group $teardown_group_id"
  fi

  printf 'terminated_instance=%s\n' "$teardown_instance_id"
  printf 'released_public_ipv4=%s\n' "$teardown_public_ip"
  printf '%s\n' 'Flyology.DB EC2 benchmark host teardown passed'
}

rerun_kept_host()
{
  [ "$#" -ge 2 ] || {
    usage >&2
    exit 2
  }
  rerun_profile=$1
  rerun_evidence=$2
  shift 2
  rerun_region=us-west-2
  rerun_output=
  rerun_untracked_paths=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --region)
        [ "$#" -ge 2 ] || fail '--region requires a value'
        rerun_region=$2
        shift 2
        ;;
      --output)
        [ "$#" -ge 2 ] || fail '--output requires a value'
        rerun_output=$2
        shift 2
        ;;
      --include-untracked)
        [ "$#" -ge 2 ] || fail '--include-untracked requires a value'
        rerun_untracked_paths+=("$2")
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) fail "unknown rerun argument: $1" ;;
    esac
  done
  case "$rerun_region" in
    '' | *[!a-z0-9-]*) fail "invalid AWS region: $rerun_region" ;;
  esac
  for command in aws curl git jq openssl python3 scp sed shasum ssh stat tar; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
  done
  [ -x "$power_detector" ] || fail 'maintained power-profile detector is unavailable'
  [ -d "$rerun_evidence" ] || fail "evidence directory is absent: $rerun_evidence"
  rerun_evidence=$(CDPATH= cd -- "$rerun_evidence" && pwd -P)
  case "$rerun_evidence/" in
    "$repository/benchmarks/comparison/results/aws-nitro-"*/) ;;
    *) fail "rerun evidence is outside admitted campaign results: $rerun_evidence" ;;
  esac
  rerun_instance_file=$rerun_evidence/instance.json
  rerun_identity_file=$rerun_evidence/caller-identity.json
  rerun_key_pair_file=$rerun_evidence/key-pair.json
  rerun_key_path=$rerun_evidence/instance-key.pem
  rerun_known_hosts=$rerun_evidence/known_hosts
  [ -f "$rerun_instance_file" ] || fail "instance evidence is absent: $rerun_instance_file"
  [ -f "$rerun_identity_file" ] || fail "caller identity is absent: $rerun_identity_file"
  [ -f "$rerun_key_path" ] && [ ! -L "$rerun_key_path" ] ||
    fail "retained PEM is absent or symbolic: $rerun_key_path"
  if rerun_key_mode=$(stat -f '%Lp' "$rerun_key_path" 2>/dev/null); then
    :
  else
    rerun_key_mode=$(stat -c '%a' "$rerun_key_path")
  fi
  [ "$rerun_key_mode" = 600 ] || fail "retained PEM mode is not 0600: $rerun_key_mode"
  [ "$(jq '[.Reservations[].Instances[]] | length' "$rerun_instance_file")" -eq 1 ] ||
    fail 'instance evidence must describe exactly one instance'

  rerun_instance_id=$(jq -r '.Reservations[].Instances[].InstanceId' "$rerun_instance_file")
  rerun_key_name=$(jq -r '.Reservations[].Instances[].KeyName' "$rerun_instance_file")
  rerun_public_ip=$(jq -r '.Reservations[].Instances[].PublicIpAddress' "$rerun_instance_file")
  rerun_instance_type=$(jq -r '.Reservations[].Instances[].InstanceType' "$rerun_instance_file")
  rerun_ami_id=$(jq -r '.Reservations[].Instances[].ImageId' "$rerun_instance_file")
  rerun_zone=$(jq -r '.Reservations[].Instances[].Placement.AvailabilityZone' \
    "$rerun_instance_file")
  rerun_group_count=$(jq '[.Reservations[].Instances[].SecurityGroups[]] | length' \
    "$rerun_instance_file")
  [ "$rerun_group_count" -eq 1 ] ||
    fail 'instance evidence must describe exactly one security group'
  rerun_group_id=$(jq -r '.Reservations[].Instances[].SecurityGroups[].GroupId' \
    "$rerun_instance_file")
  rerun_pem_fingerprint=$(rsa_private_fingerprint "$rerun_key_path")
  rerun_key_pair_id=
  rerun_key_fingerprint=$rerun_pem_fingerprint
  if [ -f "$rerun_key_pair_file" ]; then
    rerun_key_pair_id=$(jq -r '.KeyPairId' "$rerun_key_pair_file")
    rerun_key_fingerprint=$(jq -r '.KeyFingerprint' "$rerun_key_pair_file")
    [ "$(jq -r '.KeyName' "$rerun_key_pair_file")" = "$rerun_key_name" ] ||
      fail 'key-pair evidence name does not match instance evidence'
    [ "$(jq -r '.KeyType' "$rerun_key_pair_file")" = rsa ] ||
      fail 'retained benchmark key is not RSA'
    [ "$rerun_pem_fingerprint" = "$rerun_key_fingerprint" ] ||
      fail 'retained PEM does not match evidenced AWS key fingerprint'
  fi
  rerun_evidenced_name=$(jq -r \
    '[.Reservations[].Instances[].Tags[] | select(.Key == "Name") | .Value] |
     if length == 1 then .[0] else "" end' "$rerun_instance_file")
  rerun_evidenced_purpose=$(jq -r \
    '[.Reservations[].Instances[].Tags[] | select(.Key == "Purpose") | .Value] |
     if length == 1 then .[0] else "" end' "$rerun_instance_file")
  rerun_evidenced_campaign=$(jq -r \
    '[.Reservations[].Instances[].Tags[] | select(.Key == "CampaignId") | .Value] |
     if length == 0 then "" elif length == 1 then .[0] else error("ambiguous CampaignId") end' \
    "$rerun_instance_file")
  [ "$rerun_evidenced_name" = "$rerun_key_name" ] ||
    fail 'evidenced instance Name tag does not match its key name'
  [ "$rerun_evidenced_purpose" = FlyologyDBBenchmark ] ||
    fail 'evidenced instance purpose tag is missing or ambiguous'
  if [ -n "$rerun_evidenced_campaign" ]; then
    [ "$rerun_evidenced_campaign" = "$rerun_key_name" ] ||
      fail 'evidenced campaign identity does not match its key name'
  fi

  rerun_aws=(aws --profile "$rerun_profile" --region "$rerun_region")
  rerun_temporary=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-aws-rerun.XXXXXX")
  rerun_remote_input=
  rerun_remote_work=
  rerun_remote_cleaned=false
  rerun_cleanup()
  {
    rerun_cleanup_status=$?
    trap - EXIT
    if [ "$rerun_cleanup_status" -ne 0 ] && [ "$rerun_remote_cleaned" = false ] && \
      [ -n "$rerun_remote_input" ]; then
      printf 'retained_failed_input=%s\n' "$rerun_remote_input" >&2
      printf 'retained_failed_work=%s\n' "$rerun_remote_work" >&2
      if [ -n "${rerun_output:-}" ] && [ -d "$rerun_output" ]; then
        {
          printf 'state=retained_after_failure\n'
          printf 'input=%s\n' "$rerun_remote_input"
          printf 'work=%s\n' "$rerun_remote_work"
        } > "$rerun_output/remote-roots.txt"
      fi
    fi
    rm -rf -- "$rerun_temporary"
    exit "$rerun_cleanup_status"
  }
  trap rerun_cleanup EXIT
  "${rerun_aws[@]}" sts get-caller-identity > "$rerun_temporary/caller-identity.json"
  [ "$(jq -r '.Account' "$rerun_temporary/caller-identity.json")" = \
    "$(jq -r '.Account' "$rerun_identity_file")" ] ||
    fail 'live AWS account does not match retained evidence'
  "${rerun_aws[@]}" ec2 describe-instances --instance-ids "$rerun_instance_id" \
    --output json > "$rerun_temporary/instance.json"
  rerun_live_json=$(<"$rerun_temporary/instance.json")
  [ "$(jq '[.Reservations[].Instances[]] | length' <<<"$rerun_live_json")" -eq 1 ] ||
    fail 'live query must resolve exactly one instance'
  [ "$(jq -r '.Reservations[].Instances[].State.Name' <<<"$rerun_live_json")" = running ] ||
    fail 'retained benchmark instance is not running'
  [ "$(jq -r '.Reservations[].Instances[].PublicIpAddress // ""' \
    <<<"$rerun_live_json")" = "$rerun_public_ip" ] || fail 'live public IPv4 address drifted'
  [ "$(jq -r '.Reservations[].Instances[].KeyName' <<<"$rerun_live_json")" = \
    "$rerun_key_name" ] || fail 'live instance key drifted'
  [ "$(jq '[.Reservations[].Instances[].SecurityGroups[]] | length' \
    <<<"$rerun_live_json")" -eq 1 ] || fail 'live security group inventory is ambiguous'
  [ "$(jq -r '.Reservations[].Instances[].SecurityGroups[].GroupId' \
    <<<"$rerun_live_json")" = "$rerun_group_id" ] || fail 'live security group drifted'
  [ "$(jq -r '.Reservations[].Instances[].InstanceType' <<<"$rerun_live_json")" = \
    "$rerun_instance_type" ] || fail 'live instance type drifted'
  [ "$(jq -r '.Reservations[].Instances[].ImageId' <<<"$rerun_live_json")" = \
    "$rerun_ami_id" ] || fail 'live AMI drifted'
  [ "$(jq -r '.Reservations[].Instances[].Placement.AvailabilityZone' \
    <<<"$rerun_live_json")" = "$rerun_zone" ] || fail 'live availability zone drifted'
  [ "$(jq -r '[.Reservations[].Instances[].Tags[] | select(.Key == "Name") | .Value] |
    if length == 1 then .[0] else "" end' <<<"$rerun_live_json")" = \
    "$rerun_evidenced_name" ] || fail 'live instance Name tag drifted'
  [ "$(jq -r '[.Reservations[].Instances[].Tags[] | select(.Key == "Purpose") | .Value] |
    if length == 1 then .[0] else "" end' <<<"$rerun_live_json")" = \
    "$rerun_evidenced_purpose" ] || fail 'live instance purpose tag drifted'
  rerun_live_campaign=$(jq -r \
    '[.Reservations[].Instances[].Tags[] | select(.Key == "CampaignId") | .Value] |
     if length == 0 then "" elif length == 1 then .[0] else error("ambiguous CampaignId") end' \
    <<<"$rerun_live_json")
  [ "$rerun_live_campaign" = "$rerun_evidenced_campaign" ] ||
    fail 'live campaign identity differs from retained evidence'
  rerun_key_selector=(--key-names "$rerun_key_name")
  if [ -n "$rerun_key_pair_id" ]; then
    rerun_key_selector=(--key-pair-ids "$rerun_key_pair_id")
  fi
  "${rerun_aws[@]}" ec2 describe-key-pairs "${rerun_key_selector[@]}" \
    --output json > "$rerun_temporary/key-pair.json"
  [ "$(jq '[.KeyPairs[]] | length' "$rerun_temporary/key-pair.json")" -eq 1 ] ||
    fail 'live query must resolve exactly one AWS key pair'
  [ "$(jq -r '.KeyPairs[0].KeyName' "$rerun_temporary/key-pair.json")" = \
    "$rerun_key_name" ] || fail 'live AWS key-pair name drifted'
  [ "$(jq -r '.KeyPairs[0].KeyFingerprint' "$rerun_temporary/key-pair.json")" = \
    "$rerun_key_fingerprint" ] || fail 'live AWS key-pair fingerprint drifted'
  rerun_key_pair_id=$(jq -r '.KeyPairs[0].KeyPairId' "$rerun_temporary/key-pair.json")
  rerun_caller_ip=$(curl -fsSL https://checkip.amazonaws.com | tr -d '[:space:]')
  case "$rerun_caller_ip" in
    *.*.*.*) ;;
    *) fail 'could not determine current public IPv4 address' ;;
  esac
  "${rerun_aws[@]}" ec2 describe-security-groups --group-ids "$rerun_group_id" \
    --output json > "$rerun_temporary/security-group.json"
  [ "$(jq '[.SecurityGroups[0].IpPermissions[]] | length' \
    "$rerun_temporary/security-group.json")" -eq 1 ] ||
    fail 'retained host security group has unexpected ingress rules'
  [ "$(jq -r '.SecurityGroups[0].IpPermissions[0].IpProtocol' \
    "$rerun_temporary/security-group.json")" = tcp ] || fail 'retained ingress is not TCP'
  [ "$(jq -r '.SecurityGroups[0].IpPermissions[0].FromPort' \
    "$rerun_temporary/security-group.json")" -eq 22 ] || fail 'retained ingress is not port 22'
  [ "$(jq -r '.SecurityGroups[0].IpPermissions[0].ToPort' \
    "$rerun_temporary/security-group.json")" -eq 22 ] || fail 'retained ingress is not port 22'
  [ "$(jq -r '.SecurityGroups[0].IpPermissions[0].IpRanges | length' \
    "$rerun_temporary/security-group.json")" -eq 1 ] || fail 'retained SSH CIDR is ambiguous'
  [ "$(jq -r '.SecurityGroups[0].IpPermissions[0].Ipv6Ranges | length' \
    "$rerun_temporary/security-group.json")" -eq 0 ] || fail 'retained SSH admits IPv6 sources'
  [ "$(jq -r '.SecurityGroups[0].IpPermissions[0].PrefixListIds | length' \
    "$rerun_temporary/security-group.json")" -eq 0 ] || fail 'retained SSH admits prefix lists'
  [ "$(jq -r '.SecurityGroups[0].IpPermissions[0].UserIdGroupPairs | length' \
    "$rerun_temporary/security-group.json")" -eq 0 ] || fail 'retained SSH admits security groups'
  [ "$(jq -r '.SecurityGroups[0].IpPermissions[0].IpRanges[0].CidrIp' \
    "$rerun_temporary/security-group.json")" = "$rerun_caller_ip/32" ] ||
    fail 'retained host does not admit SSH from the current exact public IPv4 address'
  [ "$(jq '.SecurityGroups[0].IpPermissionsEgress | length' \
    "$rerun_temporary/security-group.json")" -eq 1 ] ||
    fail 'retained host security group has unexpected egress rules'
  [ "$(jq -r '.SecurityGroups[0].IpPermissionsEgress[0].IpProtocol' \
    "$rerun_temporary/security-group.json")" = -1 ] ||
    fail 'retained host security group egress is not the default all-protocol rule'
  [ "$(jq -r '.SecurityGroups[0].IpPermissionsEgress[0].IpRanges | length' \
    "$rerun_temporary/security-group.json")" -eq 1 ] ||
    fail 'retained host security group egress CIDR is ambiguous'
  [ "$(jq -r '.SecurityGroups[0].IpPermissionsEgress[0].Ipv6Ranges | length' \
    "$rerun_temporary/security-group.json")" -eq 0 ] ||
    fail 'retained host security group has unexpected IPv6 egress'
  [ "$(jq -r '.SecurityGroups[0].IpPermissionsEgress[0].PrefixListIds | length' \
    "$rerun_temporary/security-group.json")" -eq 0 ] ||
    fail 'retained host security group has unexpected prefix-list egress'
  [ "$(jq -r '.SecurityGroups[0].IpPermissionsEgress[0].UserIdGroupPairs | length' \
    "$rerun_temporary/security-group.json")" -eq 0 ] ||
    fail 'retained host security group has unexpected security-group egress'
  [ "$(jq -r '.SecurityGroups[0].IpPermissionsEgress[0].IpRanges[0].CidrIp' \
    "$rerun_temporary/security-group.json")" = 0.0.0.0/0 ] ||
    fail 'retained host security group egress CIDR drifted'

  rerun_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  rerun_id="rerun-$rerun_stamp-$$"
  if [ -z "$rerun_output" ]; then
    rerun_output="$script_dir/results/aws-nitro-rerun-$rerun_stamp"
  fi
  [ ! -e "$rerun_output" ] || fail "output already exists: $rerun_output"
  mkdir -p "$rerun_output"
  rerun_output=$(CDPATH= cd -- "$rerun_output" && pwd -P)
  case "$rerun_output/" in
    "$repository/benchmarks/comparison/results/aws-nitro-"*) ;;
    "$repository/"*)
      fail 'repository-local output must use benchmarks/comparison/results/aws-nitro-*'
      ;;
  esac
  cp "$rerun_temporary/caller-identity.json" "$rerun_output/caller-identity.json"
  cp "$rerun_temporary/instance.json" "$rerun_output/instance.json"
  cp "$rerun_temporary/key-pair.json" "$rerun_output/live-key-pair.json"
  cp "$rerun_temporary/security-group.json" "$rerun_output/security-group.json"
  printf '%s\n' "$rerun_evidence" > "$rerun_output/retained-host-evidence.txt"
  if [ -f "$rerun_known_hosts" ] && [ ! -L "$rerun_known_hosts" ]; then
    if rerun_hosts_mode=$(stat -f '%Lp' "$rerun_known_hosts" 2>/dev/null); then
      :
    else
      rerun_hosts_mode=$(stat -c '%a' "$rerun_known_hosts")
    fi
    [ "$rerun_hosts_mode" = 600 ] ||
      fail "retained SSH host-key mode is not 0600: $rerun_hosts_mode"
  elif [ -e "$rerun_known_hosts" ]; then
    fail "retained SSH host keys are not a regular file: $rerun_known_hosts"
  else
    rerun_known_hosts=$rerun_temporary/known_hosts
    capture_console_host_key "$rerun_profile" "$rerun_region" "$rerun_instance_id" \
      "$rerun_public_ip" "$rerun_known_hosts" "$rerun_output/console-output.json"
  fi
  cp "$rerun_known_hosts" "$rerun_output/known_hosts"
  chmod 0600 "$rerun_output/known_hosts"

  cd "$repository"
  git status --short --branch | tee "$rerun_output/source-status.txt"
  rerun_source_head=$(git rev-parse HEAD)
  git bundle create "$rerun_temporary/flyology-db.bundle" HEAD
  git diff --binary HEAD -- > "$rerun_temporary/flyology-db.patch"
  rerun_source_diff_sha=$(
    shasum -a 256 "$rerun_temporary/flyology-db.patch" | cut -d ' ' -f 1
  )
  python3 "$script_dir/aws/package-source.py" "$repository" \
    "$rerun_temporary/flyology-db-untracked.json" \
    "$rerun_temporary/flyology-db-untracked.tar.gz" \
    "${rerun_untracked_paths[@]}"
  python3 "$script_dir/aws/package-source.py" "$repository" \
    "$rerun_temporary/flyology-db-untracked-recheck.json" \
    "$rerun_temporary/flyology-db-untracked-recheck.tar.gz" \
    --allow-manifest "$rerun_temporary/flyology-db-untracked.json"
  cmp "$rerun_temporary/flyology-db-untracked.json" \
    "$rerun_temporary/flyology-db-untracked-recheck.json"
  rerun_untracked_sha=$(
    shasum -a 256 "$rerun_temporary/flyology-db-untracked.tar.gz" | cut -d ' ' -f 1
  )
  rerun_untracked_manifest_sha=$(
    shasum -a 256 "$rerun_temporary/flyology-db-untracked.json" | cut -d ' ' -f 1
  )
  rerun_power_detector_sha=$(shasum -a 256 "$power_detector" | cut -d ' ' -f 1)
  git clone --quiet "$rerun_temporary/flyology-db.bundle" \
    "$rerun_temporary/authenticated-source"
  if [ -s "$rerun_temporary/flyology-db.patch" ]; then
    git -C "$rerun_temporary/authenticated-source" apply --binary \
      "$rerun_temporary/flyology-db.patch"
  fi
  tar -C "$rerun_temporary/authenticated-source" -xzf \
    "$rerun_temporary/flyology-db-untracked.tar.gz"
  [ "$(git -C "$rerun_temporary/authenticated-source" rev-parse HEAD)" = \
    "$rerun_source_head" ] || fail 'source HEAD changed while constructing rerun snapshot'
  rerun_snapshot_diff_sha=$(
    git -C "$rerun_temporary/authenticated-source" diff --binary HEAD -- |
      shasum -a 256 | cut -d ' ' -f 1
  )
  [ "$rerun_snapshot_diff_sha" = "$rerun_source_diff_sha" ] ||
    fail 'tracked source changed while constructing rerun snapshot'
  rerun_remote_runner=$rerun_temporary/authenticated-source/benchmarks/comparison/aws/remote-run.sh
  rerun_remote_runner_sha=$(shasum -a 256 "$rerun_remote_runner" | cut -d ' ' -f 1)
  rerun_artifact_extractor=$rerun_temporary/authenticated-source/benchmarks/comparison/aws/\
extract-artifacts.py
  rerun_artifact_extractor_sha=$(
    shasum -a 256 "$rerun_artifact_extractor" | cut -d ' ' -f 1
  )
  {
    printf 'SOURCE_HEAD=%q\n' "$rerun_source_head"
    printf 'SOURCE_DIFF_SHA256=%q\n' "$rerun_source_diff_sha"
    printf 'SOURCE_UNTRACKED_SHA256=%q\n' "$rerun_untracked_sha"
    printf 'SOURCE_UNTRACKED_MANIFEST_SHA256=%q\n' "$rerun_untracked_manifest_sha"
    printf 'SOURCE_POWER_PROFILE_SHA256=%q\n' "$rerun_power_detector_sha"
    printf 'SOURCE_REMOTE_RUNNER_SHA256=%q\n' "$rerun_remote_runner_sha"
  } > "$rerun_temporary/flyology-db-source.env"

  rerun_ssh_options=(-i "$rerun_key_path" -o BatchMode=yes -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$rerun_known_hosts")
  ssh "${rerun_ssh_options[@]}" "ubuntu@$rerun_public_ip" true
  rerun_remote_input=/tmp/flyology-db-aws-runs/$rerun_id
  rerun_remote_work=/mnt/flyology-bench/runs/$rerun_id
  {
    printf 'state=pending\n'
    printf 'input=%s\n' "$rerun_remote_input"
    printf 'work=%s\n' "$rerun_remote_work"
  } > "$rerun_output/remote-roots.txt"
  printf -v rerun_prepare_command \
    'umask 077; mkdir -p /tmp/flyology-db-aws-runs; test ! -e %q; mkdir %q' \
    "$rerun_remote_input" "$rerun_remote_input"
  ssh "${rerun_ssh_options[@]}" "ubuntu@$rerun_public_ip" "$rerun_prepare_command"
  scp "${rerun_ssh_options[@]}" \
    "$rerun_temporary/flyology-db.bundle" \
    "$rerun_temporary/flyology-db.patch" \
    "$rerun_temporary/flyology-db-untracked.tar.gz" \
    "$rerun_temporary/flyology-db-untracked.json" \
    "$rerun_temporary/flyology-db-source.env" \
    "$power_detector" \
    "$rerun_remote_runner" \
    "ubuntu@$rerun_public_ip:$rerun_remote_input/"

  set +e
  printf -v rerun_remote_command 'sudo -H env AWS_CAMPAIGN_MODE=rerun'
  printf -v rerun_remote_command '%s AWS_CAMPAIGN_RUN_ID=%q' \
    "$rerun_remote_command" "$rerun_id"
  printf -v rerun_remote_command '%s AWS_CAMPAIGN_INPUT_ROOT=%q' \
    "$rerun_remote_command" "$rerun_remote_input"
  printf -v rerun_remote_command '%s AWS_INSTANCE_TYPE=%q' \
    "$rerun_remote_command" "$rerun_instance_type"
  printf -v rerun_remote_command '%s AWS_REGION=%q' "$rerun_remote_command" "$rerun_region"
  printf -v rerun_remote_command '%s AWS_AVAILABILITY_ZONE=%q' \
    "$rerun_remote_command" "$rerun_zone"
  printf -v rerun_remote_command '%s AWS_AMI_ID=%q' "$rerun_remote_command" "$rerun_ami_id"
  printf -v rerun_remote_command '%s AWS_INSTANCE_ID=%q bash %q' \
    "$rerun_remote_command" "$rerun_instance_id" "$rerun_remote_input/remote-run.sh"
  ssh "${rerun_ssh_options[@]}" "ubuntu@$rerun_public_ip" "$rerun_remote_command"
  rerun_remote_status=$?
  set -e
  scp "${rerun_ssh_options[@]}" \
    "ubuntu@$rerun_public_ip:$rerun_remote_input/artifacts.tar.gz" \
    "$rerun_output/artifacts.tar.gz" || fail 'rerun evidence could not be downloaded'
  [ "$(shasum -a 256 "$rerun_artifact_extractor" | cut -d ' ' -f 1)" = \
    "$rerun_artifact_extractor_sha" ] || fail 'artifact extractor changed during rerun'
  python3 "$rerun_artifact_extractor" \
    "$rerun_output/artifacts.tar.gz" "$rerun_output/remote"
  rerun_artifact_status=$(<"$rerun_output/remote/exit-status")
  [ "$rerun_artifact_status" = "$rerun_remote_status" ] ||
    fail "remote status $rerun_remote_status disagrees with artifact $rerun_artifact_status"
  if [ "$rerun_remote_status" -ne 0 ]; then
    fail "remote rerun exited $rerun_remote_status"
  fi
  grep -Fx 'Flyology.DB AWS deterministic suite passed' \
    "$rerun_output/remote/evidence/deterministic-sentinel.txt" >/dev/null ||
    fail 'remote deterministic sentinel is missing'
  grep -Fx 'Flyology.DB AWS Nitro benchmark campaign passed' \
    "$rerun_output/remote/evidence/benchmark-sentinel.txt" >/dev/null ||
    fail 'remote benchmark sentinel is missing'

  printf -v rerun_remove_command 'sudo -n rm -rf -- %q %q' \
    "$rerun_remote_input" "$rerun_remote_work"
  ssh "${rerun_ssh_options[@]}" "ubuntu@$rerun_public_ip" "$rerun_remove_command"
  rerun_remote_cleaned=true
  {
    printf 'state=removed_after_success\n'
    printf 'input=%s\n' "$rerun_remote_input"
    printf 'work=%s\n' "$rerun_remote_work"
  } > "$rerun_output/remote-roots.txt"

  printf '%s\n' "AWS Nitro retained-host rerun passed; evidence: $rerun_output"
}

if [ "${1:-}" = rerun ]; then
  shift
  rerun_kept_host "$@"
  exit 0
fi

if [ "${1:-}" = teardown ]; then
  shift
  teardown_kept_host "$@"
  exit 0
fi

if [ "$#" -eq 1 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then
  usage
  exit 0
fi
[ "$#" -ge 2 ] || {
  usage >&2
  exit 2
}
profile=$1
instance_type=$2
shift 2
region=us-west-2
output=
keep_instance=false
untracked_paths=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --region)
      [ "$#" -ge 2 ] || fail '--region requires a value'
      region=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || fail '--output requires a value'
      output=$2
      shift 2
      ;;
    --keep-instance)
      keep_instance=true
      shift
      ;;
    --include-untracked)
      [ "$#" -ge 2 ] || fail '--include-untracked requires a value'
      untracked_paths+=("$2")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done
case "$instance_type" in
  '' | *[!a-z0-9.]*) fail "invalid EC2 instance type: $instance_type" ;;
esac
case "$region" in
  '' | *[!a-z0-9-]*) fail "invalid AWS region: $region" ;;
esac

for command in aws awk curl git jq openssl python3 scp sed shasum ssh tar; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done
[ -x "$power_detector" ] || fail "maintained power-profile detector is unavailable"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
if [ -z "$output" ]; then
  output="$script_dir/results/aws-nitro-$stamp"
fi
[ ! -e "$output" ] || fail "output already exists: $output"
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd -P)
case "$output/" in
  "$repository/benchmarks/comparison/results/aws-nitro-"*) ;;
  "$repository/"*) fail "repository-local output must use benchmarks/comparison/results/aws-nitro-*" ;;
esac

temporary=$(mktemp -d "${TMPDIR:-/tmp}/flyology-db-aws.XXXXXX")
instance_id=
key_name="flyology-db-bench-$stamp-$$"
security_group_id=
campaign_complete=false
key_pair_started=false
security_group_started=false
run_instances_started=false
known_hosts=$temporary/known_hosts
key_path=$temporary/key.pem
aws=(aws --profile "$profile" --region "$region")

launch_instance()
{
  "${aws[@]}" ec2 run-instances \
    --image-id "$ami_id" --instance-type "$instance_type" \
    --client-token "$key_name" \
    --key-name "$key_name" --security-group-ids "$security_group_id" \
    --subnet-id "$subnet_id" --associate-public-ip-address \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --block-device-mappings \
      'DeviceName=/dev/sda1,Ebs={VolumeSize=40,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
    --tag-specifications "$tag_specification" \
    --query 'Instances[0].InstanceId' --output text
}

cleanup()
{
  cleanup_status=$?
  trap - EXIT
  set +e
  remove_temporary=true
  instance_reconciliation_safe=true
  access_reconciliation_safe=true
  if [ -z "$instance_id" ]; then
    if [ "$run_instances_started" = true ]; then
      instance_id=$(launch_instance)
      launch_status=$?
      case "$instance_id" in
        i-[0-9a-f]*) ;;
        *) instance_id= ;;
      esac
      if [ "$launch_status" -ne 0 ] || [ -z "$instance_id" ]; then
        printf '%s\n' \
          "idempotent campaign instance reconciliation failed for $key_name" >&2
        instance_reconciliation_safe=false
        cleanup_status=1
      fi
    fi
  fi
  if [ -z "$security_group_id" ]; then
    recovered_groups=$(
      "${aws[@]}" ec2 describe-security-groups \
        --filters "Name=group-name,Values=$key_name" \
        --query 'SecurityGroups[].GroupId' --output text
    )
    if [ "$?" -ne 0 ]; then
      printf '%s\n' "failed to reconcile campaign security group $key_name" >&2
      access_reconciliation_safe=false
      cleanup_status=1
    elif [ "$(printf '%s\n' "$recovered_groups" | awk 'NF { count += NF } END { print count + 0 }')" \
      -gt 1 ]; then
      printf '%s\n' "multiple campaign security groups require recovery: $recovered_groups" >&2
      access_reconciliation_safe=false
      cleanup_status=1
    elif [ -n "$recovered_groups" ]; then
      security_group_id=$recovered_groups
    elif [ "$security_group_started" = true ]; then
      printf '%s\n' \
        "campaign security group existence is inconclusive: name=$key_name" >&2
      access_reconciliation_safe=false
      cleanup_status=1
    fi
  fi
  cleanup_resources=$keep_instance
  if [ "$keep_instance" = true ] && [ -z "$instance_id" ] && \
    [ "$instance_reconciliation_safe" = true ]; then
    printf '%s\n' 'no campaign instance exists; removing orphan access resources' >&2
    cleanup_resources=false
  fi
  if [ "$cleanup_resources" = false ]; then
    access_resources_releasable=true
    if [ "$instance_reconciliation_safe" = false ] || \
      [ "$access_reconciliation_safe" = false ]; then
      access_resources_releasable=false
    fi
    if [ -n "$instance_id" ]; then
      if ! "${aws[@]}" ec2 terminate-instances --instance-ids "$instance_id" >/dev/null; then
        printf '%s\n' "failed to request termination of $instance_id" >&2
        access_resources_releasable=false
        [ "$cleanup_status" -ne 0 ] || cleanup_status=1
      elif ! "${aws[@]}" ec2 wait instance-terminated --instance-ids "$instance_id"; then
        printf '%s\n' "instance did not reach terminated state: $instance_id" >&2
        access_resources_releasable=false
        [ "$cleanup_status" -ne 0 ] || cleanup_status=1
      fi
    fi
    if [ "$access_resources_releasable" = false ]; then
      if [ -f "$key_path" ]; then
        if ! cp "$key_path" "$output/instance-key.pem" ||
          ! chmod 0600 "$output/instance-key.pem"; then
          printf '%s\n' "failed to copy retained key; preserving $temporary" >&2
          remove_temporary=false
        fi
      fi
      printf '%s%s\n' \
        "retained access resources after failed cleanup: key=$key_name" \
        " security_group=$security_group_id" \
        >&2
    elif [ "$key_pair_started" = true ]; then
      if ! "${aws[@]}" ec2 delete-key-pair \
        --key-name "$key_name" >/dev/null 2>&1; then
        printf '%s\n' "failed to delete key pair $key_name" >&2
        [ "$cleanup_status" -ne 0 ] || cleanup_status=1
      fi
    fi
    if [ "$access_resources_releasable" = true ] && [ -n "$security_group_id" ]; then
      cleanup_attempt=1
      security_group_deleted=false
      while [ "$cleanup_attempt" -le 12 ]; do
        if "${aws[@]}" ec2 delete-security-group \
          --group-id "$security_group_id" >/dev/null 2>&1; then
          security_group_deleted=true
          break
        fi
        [ "$cleanup_attempt" -lt 12 ] && sleep 5
        cleanup_attempt=$((cleanup_attempt + 1))
      done
      if [ "$security_group_deleted" = false ]; then
        printf '%s\n' "failed to delete security group $security_group_id" >&2
        [ "$cleanup_status" -ne 0 ] || cleanup_status=1
      fi
    fi
  elif [ -n "$instance_id" ] && [ -f "$key_path" ]; then
    if cp "$key_path" "$output/instance-key.pem" && chmod 0600 "$output/instance-key.pem"; then
      printf '%s\n' "kept instance $instance_id; key: $output/instance-key.pem" >&2
    else
      printf '%s\n' "failed to retain SSH key for kept instance $instance_id" >&2
      remove_temporary=false
      [ "$cleanup_status" -ne 0 ] || cleanup_status=1
    fi
  elif [ "$instance_reconciliation_safe" = false ] || \
    [ "$access_reconciliation_safe" = false ]; then
    if [ -s "$key_path" ]; then
      if ! cp "$key_path" "$output/instance-key.pem" ||
        ! chmod 0600 "$output/instance-key.pem"; then
        printf '%s\n' 'failed to preserve key after inconclusive instance reconciliation' >&2
        remove_temporary=false
      fi
    fi
    printf '%s%s\n' \
      'retained access resources after inconclusive instance reconciliation: key=' \
      "$key_name security_group=$security_group_id" >&2
    [ "$cleanup_status" -ne 0 ] || cleanup_status=1
  else
    printf '%s\n' "SSH key is missing for kept instance $instance_id" >&2
    [ "$cleanup_status" -ne 0 ] || cleanup_status=1
  fi
  if [ "$remove_temporary" = true ] && ! rm -rf -- "$temporary"; then
    printf '%s\n' "failed to remove local temporary directory $temporary" >&2
    [ "$cleanup_status" -ne 0 ] || cleanup_status=1
  fi
  if [ "$cleanup_status" -eq 0 ] && [ "$campaign_complete" = true ]; then
    printf '%s\n' "AWS Nitro campaign passed; evidence: $output"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

cd "$repository"
git status --short --branch | tee "$output/source-status.txt"
source_head=$(git rev-parse HEAD)
git bundle create "$temporary/flyology-db.bundle" HEAD
git diff --binary HEAD -- > "$temporary/flyology-db.patch"
source_diff_sha=$(shasum -a 256 "$temporary/flyology-db.patch" | cut -d ' ' -f 1)
python3 "$script_dir/aws/package-source.py" "$repository" \
  "$temporary/flyology-db-untracked.json" \
  "$temporary/flyology-db-untracked.tar.gz" \
  "${untracked_paths[@]}"
python3 "$script_dir/aws/package-source.py" "$repository" \
  "$temporary/flyology-db-untracked-recheck.json" \
  "$temporary/flyology-db-untracked-recheck.tar.gz" \
  --allow-manifest "$temporary/flyology-db-untracked.json"
cmp "$temporary/flyology-db-untracked.json" \
  "$temporary/flyology-db-untracked-recheck.json"
untracked_sha=$(shasum -a 256 "$temporary/flyology-db-untracked.tar.gz" | cut -d ' ' -f 1)
untracked_manifest_sha=$(
  shasum -a 256 "$temporary/flyology-db-untracked.json" | cut -d ' ' -f 1
)
power_detector_sha=$(shasum -a 256 "$power_detector" | cut -d ' ' -f 1)
git clone --quiet "$temporary/flyology-db.bundle" "$temporary/authenticated-source"
if [ -s "$temporary/flyology-db.patch" ]; then
  git -C "$temporary/authenticated-source" apply --binary "$temporary/flyology-db.patch"
fi
tar -C "$temporary/authenticated-source" -xzf "$temporary/flyology-db-untracked.tar.gz"
[ "$(git -C "$temporary/authenticated-source" rev-parse HEAD)" = "$source_head" ] ||
  fail "source HEAD changed while constructing the authenticated snapshot"
snapshot_diff_sha=$(
  git -C "$temporary/authenticated-source" diff --binary HEAD -- |
    shasum -a 256 | cut -d ' ' -f 1
)
[ "$snapshot_diff_sha" = "$source_diff_sha" ] ||
  fail "tracked source changed while constructing the authenticated snapshot"
remote_runner_sha=$(
  shasum -a 256 "$temporary/authenticated-source/benchmarks/comparison/aws/remote-run.sh" |
    cut -d ' ' -f 1
)
cp "$temporary/authenticated-source/benchmarks/comparison/aws/extract-artifacts.py" \
  "$temporary/extract-artifacts.py"
artifact_extractor_sha=$(shasum -a 256 "$temporary/extract-artifacts.py" | cut -d ' ' -f 1)
{
  printf 'SOURCE_HEAD=%q\n' "$source_head"
  printf 'SOURCE_DIFF_SHA256=%q\n' "$source_diff_sha"
  printf 'SOURCE_UNTRACKED_SHA256=%q\n' "$untracked_sha"
  printf 'SOURCE_UNTRACKED_MANIFEST_SHA256=%q\n' "$untracked_manifest_sha"
  printf 'SOURCE_POWER_PROFILE_SHA256=%q\n' "$power_detector_sha"
  printf 'SOURCE_REMOTE_RUNNER_SHA256=%q\n' "$remote_runner_sha"
} > "$temporary/flyology-db-source.env"

"${aws[@]}" sts get-caller-identity > "$output/caller-identity.json"
instance_json=$("${aws[@]}" ec2 describe-instance-types \
  --instance-types "$instance_type" --output json)
printf '%s\n' "$instance_json" > "$output/instance-type.json"
[ "$(jq -r '.InstanceTypes[0].Hypervisor' <<<"$instance_json")" = nitro ] ||
  fail "$instance_type is not a Nitro instance"
[ "$(jq -r '.InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' \
  <<<"$instance_json")" = x86_64 ] || fail "$instance_type is not x86-64"
[ "$(jq -r '.InstanceTypes[0].InstanceStorageInfo.Disks | length' \
  <<<"$instance_json")" -eq 1 ] || fail "$instance_type must have exactly one instance-store disk"

ami_id=$("${aws[@]}" ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)
vpc_id=$("${aws[@]}" ec2 describe-vpcs \
  --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$vpc_id" != None ] || fail "region has no default VPC"
offerings=$("${aws[@]}" ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=$instance_type" \
  --query 'InstanceTypeOfferings[].Location' --output text)
subnet_id=
availability_zone=
for zone in $offerings; do
  candidate=$("${aws[@]}" ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=availability-zone,Values=$zone" \
    --query 'Subnets[?MapPublicIpOnLaunch==`true`] | [0].SubnetId' --output text)
  if [ -n "$candidate" ] && [ "$candidate" != None ]; then
    subnet_id=$candidate
    availability_zone=$zone
    break
  fi
done
[ -n "$subnet_id" ] || fail "$instance_type has no public default subnet in $region"

caller_ip=$(curl -fsSL https://checkip.amazonaws.com | tr -d '[:space:]')
case "$caller_ip" in
  *.*.*.*) ;;
  *) fail "could not determine caller public IPv4 address" ;;
esac
key_pair_started=true
"${aws[@]}" ec2 create-key-pair --key-name "$key_name" \
  --output json > "$temporary/key-pair-with-material.json"
jq -r '.KeyMaterial' "$temporary/key-pair-with-material.json" > "$key_path"
chmod 0600 "$key_path"
jq '{KeyPairId, KeyFingerprint, KeyName, KeyType}' \
  "$temporary/key-pair-with-material.json" > "$output/key-pair.json"
[ "$(rsa_private_fingerprint "$key_path")" = \
  "$(jq -r '.KeyFingerprint' "$output/key-pair.json")" ] ||
  fail 'created PEM does not match the AWS key-pair fingerprint'
security_group_started=true
security_group_id=$("${aws[@]}" ec2 create-security-group \
  --group-name "$key_name" --description 'Temporary Flyology.DB benchmark SSH' \
  --vpc-id "$vpc_id" --query GroupId --output text)
"${aws[@]}" ec2 authorize-security-group-ingress \
  --group-id "$security_group_id" --protocol tcp --port 22 --cidr "$caller_ip/32"

tag_specification='ResourceType=instance,Tags=['
tag_specification+="{Key=Name,Value=$key_name},"
tag_specification+='{Key=Purpose,Value=FlyologyDBBenchmark},'
tag_specification+="{Key=CampaignId,Value=$key_name}]"
run_instances_started=true
instance_id=$(launch_instance)
"${aws[@]}" ec2 wait instance-status-ok --instance-ids "$instance_id"
public_ip=$("${aws[@]}" ec2 describe-instances --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
"${aws[@]}" ec2 describe-instances --instance-ids "$instance_id" \
  > "$output/instance.json"
known_hosts=$output/known_hosts
  capture_console_host_key "$profile" "$region" "$instance_id" "$public_ip" \
    "$known_hosts" "$output/console-output.json"

ssh_options=(-i "$key_path" -o BatchMode=yes -o ConnectTimeout=15 \
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
attempt=1
while [ "$attempt" -le 40 ]; do
  if ssh "${ssh_options[@]}" "ubuntu@$public_ip" true 2>/dev/null; then
    break
  fi
  [ "$attempt" -lt 40 ] || fail "SSH did not become ready"
  sleep 5
  attempt=$((attempt + 1))
done

scp "${ssh_options[@]}" \
  "$temporary/flyology-db.bundle" \
  "$temporary/flyology-db.patch" \
  "$temporary/flyology-db-untracked.tar.gz" \
  "$temporary/flyology-db-untracked.json" \
  "$temporary/flyology-db-source.env" \
  "$power_detector" \
  "$temporary/authenticated-source/benchmarks/comparison/aws/remote-run.sh" \
  "ubuntu@$public_ip:/tmp/"

set +e
printf -v remote_command 'sudo -H env AWS_INSTANCE_TYPE=%q' "$instance_type"
printf -v remote_command '%s AWS_REGION=%q' "$remote_command" "$region"
printf -v remote_command '%s AWS_AVAILABILITY_ZONE=%q' \
  "$remote_command" "$availability_zone"
printf -v remote_command '%s AWS_AMI_ID=%q' "$remote_command" "$ami_id"
printf -v remote_command '%s AWS_INSTANCE_ID=%q bash /tmp/remote-run.sh' \
  "$remote_command" "$instance_id"
ssh "${ssh_options[@]}" "ubuntu@$public_ip" "$remote_command"
remote_status=$?
set -e
scp "${ssh_options[@]}" \
  "ubuntu@$public_ip:/tmp/flyology-db-aws-artifacts.tar.gz" \
  "$output/artifacts.tar.gz" || fail "remote campaign evidence could not be downloaded"
[ "$(shasum -a 256 "$temporary/extract-artifacts.py" | cut -d ' ' -f 1)" = \
  "$artifact_extractor_sha" ] || fail "private artifact extractor changed during campaign"
python3 "$temporary/extract-artifacts.py" \
  "$output/artifacts.tar.gz" "$output/remote"
artifact_status=$(cat "$output/remote/exit-status")
[ "$artifact_status" = "$remote_status" ] ||
  fail "remote status $remote_status disagrees with artifact status $artifact_status"
[ "$remote_status" -eq 0 ] || fail "remote campaign exited $remote_status"
grep -Fx 'Flyology.DB AWS deterministic suite passed' \
  "$output/remote/evidence/deterministic-sentinel.txt" >/dev/null ||
  fail "remote deterministic sentinel is missing"
grep -Fx 'Flyology.DB AWS Nitro benchmark campaign passed' \
  "$output/remote/evidence/benchmark-sentinel.txt" >/dev/null ||
  fail "remote benchmark sentinel is missing"

campaign_complete=true
