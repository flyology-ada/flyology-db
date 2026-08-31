#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
power_detector=$repository/.agents/skills/performance-testing/scripts/check-power-profile.sh

usage()
{
  cat <<'EOF'
Usage: run-aws-nitro-campaign.sh AWS_PROFILE INSTANCE_TYPE [options]

Required:
  AWS_PROFILE       Configured AWS CLI profile
  INSTANCE_TYPE     x86-64 Nitro type with exactly one instance-store disk

Options:
  --region REGION   AWS region (default: us-west-2)
  --output PATH     New local evidence directory
  --include-untracked PATH
                    Admit one intentional Git-relative untracked source path
  --keep-instance   Keep EC2 instance, key pair, and security group
EOF
}

fail()
{
  printf '%s\n' "$*" >&2
  exit 1
}

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

for command in aws curl git jq python3 scp shasum ssh tar; do
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
git -C "$temporary/authenticated-source" apply --binary "$temporary/flyology-db.patch"
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
  --query KeyMaterial --output text > "$key_path"
chmod 0600 "$key_path"
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

ssh_options=(-i "$key_path" -o BatchMode=yes -o ConnectTimeout=15 \
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts")
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
  "$script_dir/aws/remote-run.sh" \
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
