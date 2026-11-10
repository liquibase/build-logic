#!/usr/bin/env bash
# Runs the FIPS VM self-test checks on real RHEL 9 in FIPS mode (INT-2446). Starts an on-demand RHEL 9 EC2
# instance (the license is in the hourly price), which installs everything with fips/provision.sh, reboots
# into FIPS mode and runs fips/rhel/checks.sh. Reads the results from the instance's serial console, then
# terminates it. Nothing connects to the instance: its security group has no inbound rule.
#
# The instance gets this folder's scripts and fips/selftest in its user data, so a run tests exactly the
# files it was started from, committed or not.
#
# Needs the aws CLI and jq, and AWS credentials that may launch, read the console of and terminate instances
# tagged managed_by=fips-rhel (in CI, the role github-actions-fips-rhel).
#
# Settings (environment):
#   AWS_REGION                   us-east-1 by default
#   FIPS_RHEL_SUBNET_IDS         comma-separated public subnets; by default from SSM /fips-rhel/config/public_subnet_ids
#   FIPS_RHEL_SECURITY_GROUP_ID  egress-only security group; by default from SSM /fips-rhel/config/security_group_id
#   FIPS_RHEL_INSTANCE_TYPE      m7i.xlarge by default
#   FIPS_RHEL_AMI                by default Red Hat's hourly x86_64 AMI of the newest RHEL 9 minor release
#   FIPS_RHEL_TIMEOUT_MINUTES    45 by default; the instance also stops itself 15 minutes after that
#   FIPS_RHEL_OUT_DIR            where report.txt and console.txt go; a temporary folder by default
#
# Liquibase Secure (optional; without it the checks use Liquibase Community, as the FIPS VM self-test does):
#   FIPS_RHEL_SECURE_VERSION     a release (6.0.1) or an RC (6.0.1-RC1) on repo.liquibase.com; the archive and its
#                                published .sha256 come from releases/secure/ or non-releases/secure/
#   FIPS_RHEL_SECURE_PACKAGE     liquibase-secure (default) or liquibase-secure-fips
#   FIPS_RHEL_SECURE_URL         instead of a version: an https archive URL, with FIPS_RHEL_SECURE_SHA256
#   FIPS_RHEL_LICENSE_ROLE_ARN   the vault role that holds PRO_LICENSE_FILE (vault-grouped-pro-license-file). The
#                                instance assumes it with the fips-rhel-instance role and reads the license itself.
#   FIPS_RHEL_REQUIRE_FIPS_LICENSE  true to fail when the license or update fails in FIPS mode (false by default
#                                until license files verify in FIPS mode, INT-2438)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
export AWS_REGION=${AWS_REGION:-us-east-1}
export AWS_PAGER=""
type=${FIPS_RHEL_INSTANCE_TYPE:-m7i.xlarge}
timeout_min=${FIPS_RHEL_TIMEOUT_MINUTES:-45}
out=${FIPS_RHEL_OUT_DIR:-$(mktemp -d)}
work=$(mktemp -d)
redhat_owner=309956199498
mkdir -p "$out"
: >"$out/report.txt"

step() { echo "==> $*"; }
fail() {
  echo "::error::$*"
  exit 1
}

param() { aws ssm get-parameter --name "/fips-rhel/config/$1" --query Parameter.Value --output text; }
subnets=${FIPS_RHEL_SUBNET_IDS:-$(param public_subnet_ids)}
sg=${FIPS_RHEL_SECURITY_GROUP_ID:-$(param security_group_id)}

if [ -n "${FIPS_RHEL_AMI:-}" ]; then
  ami=$FIPS_RHEL_AMI
else
  # The newest minor release, then the newest build of it. Not the newest image: Red Hat keeps
  # rebuilding older minor releases (EUS), so the most recent image can be 9.6 while 9.8 is out.
  ami=$(aws ec2 describe-images --owners "$redhat_owner" \
    --filters 'Name=name,Values=RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3' Name=architecture,Values=x86_64 \
    Name=state,Values=available \
    --query 'Images[].[Name, ImageId]' --output text | sort -V | tail -n 1 | cut -f2)
fi
[[ $ami == ami-* ]] || fail "No RHEL 9 AMI found."

# Liquibase Secure: the archive to test, pinned by its checksum. Every value is checked here, because it ends up
# in a shell file on the instance.
secure_version=${FIPS_RHEL_SECURE_VERSION:-}
secure_package=${FIPS_RHEL_SECURE_PACKAGE:-liquibase-secure}
secure_url=${FIPS_RHEL_SECURE_URL:-}
secure_sha256=${FIPS_RHEL_SECURE_SHA256:-}
license_role=${FIPS_RHEL_LICENSE_ROLE_ARN:-}
require_fips_license=${FIPS_RHEL_REQUIRE_FIPS_LICENSE:-false}
[[ $secure_package =~ ^liquibase-secure(-fips)?$ ]] || fail "FIPS_RHEL_SECURE_PACKAGE must be liquibase-secure or liquibase-secure-fips."
[[ $require_fips_license =~ ^(true|false)$ ]] || fail "FIPS_RHEL_REQUIRE_FIPS_LICENSE must be true or false."
if [ -n "$secure_version" ]; then
  [[ $secure_version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || fail "Bad FIPS_RHEL_SECURE_VERSION: $secure_version"
  channel=$([[ $secure_version == *-* ]] && echo non-releases || echo releases)
  secure_url="https://repo.liquibase.com/$channel/secure/$secure_version/$secure_package-$secure_version.tar.gz"
  secure_sha256=$(curl -fsSL --retry 3 "$secure_url.sha256" | awk '{print $1}') ||
    fail "No published checksum at $secure_url.sha256: is $secure_package $secure_version on repo.liquibase.com?"
fi
if [ -n "$secure_url" ]; then
  [[ $secure_url =~ ^https://[A-Za-z0-9./_+-]+$ ]] || fail "Bad FIPS_RHEL_SECURE_URL: $secure_url"
  [[ $secure_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "FIPS_RHEL_SECURE_URL needs FIPS_RHEL_SECURE_SHA256 (64 hex characters)."
  step "Liquibase Secure: $secure_url (sha256 $secure_sha256)"
fi
if [ -n "$license_role" ]; then
  [[ $license_role =~ ^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]] || fail "Bad FIPS_RHEL_LICENSE_ROLE_ARN."
fi
{
  printf 'FIPS_RHEL_SECURE_VERSION=%q\n' "$secure_version"
  printf 'FIPS_RHEL_SECURE_URL=%q\n' "$secure_url"
  printf 'FIPS_RHEL_SECURE_SHA256=%q\n' "$secure_sha256"
  printf 'FIPS_RHEL_LICENSE_ROLE_ARN=%q\n' "$license_role"
  printf 'FIPS_RHEL_REQUIRE_FIPS_LICENSE=%q\n' "$require_fips_license"
} >"$work/run.env"
# Only a run that reads the license gets an instance role, and it may only assume the vault role.
profile_args=()
[ -z "$license_role" ] || profile_args=(--iam-instance-profile "Name=${FIPS_RHEL_INSTANCE_PROFILE:-fips-rhel-instance}")
read -r ami_name root_device < <(aws ec2 describe-images --image-ids "$ami" \
  --query 'Images[0].[Name, RootDeviceName]' --output text)
step "RHEL 9 image: $ami_name ($ami), $type in $AWS_REGION"

# The scripts and the self-test go in the user data, which EC2 limits to 16 KB.
COPYFILE_DISABLE=1 tar -czf "$work/bundle.tgz" --no-xattrs -C "$root" \
  fips/provision.sh fips/rhel/instance.sh fips/rhel/checks.sh fips/rhel/say.sh fips/rhel/secure.sh \
  fips/selftest/compose.yml fips/selftest/pom.xml fips/selftest/src fips/selftest/liquibase/changelog.yaml \
  -C "$work" run.env
cat >"$work/user-data.yaml" <<EOF
#cloud-config
write_files:
  - path: /opt/fips-rhel/bundle.tgz
    encoding: b64
    permissions: "0600"
    content: $(base64 <"$work/bundle.tgz" | tr -d '\n')
  - path: /var/lib/cloud/scripts/per-boot/fips-rhel
    permissions: "0755"
    content: |
      #!/bin/bash
      # Whatever happens, the instance stops, and so terminates, $((timeout_min + 15)) minutes after each boot.
      shutdown -P +$((timeout_min + 15)) 'fips-rhel: safety stop' 2>/dev/null || true
      mkdir -p /opt/fips-rhel/src && tar -xzf /opt/fips-rhel/bundle.tgz -C /opt/fips-rhel/src
      exec /opt/fips-rhel/src/fips/rhel/instance.sh
power_state:
  mode: reboot
  message: "fips-rhel: rebooting into FIPS mode"
  condition: test -f /var/lib/fips-vm/provisioned
EOF
size=$(wc -c <"$work/user-data.yaml" | tr -d ' ')
[ "$size" -le 16384 ] || fail "The user data is $size bytes; EC2 allows 16384."

name="fips-rhel-${GITHUB_RUN_ID:-local-$(date +%s)}${GITHUB_RUN_ATTEMPT:+-$GITHUB_RUN_ATTEMPT}"
tags="{Key=managed_by,Value=fips-rhel},{Key=Name,Value=$name},{Key=Project,Value=fips-rhel}"
id=""
write_report() {
  [ ! -f "$work/seen" ] || sort -n "$work/seen" | cut -d' ' -f2- >"$out/report.txt"
}
finish() {
  # What arrived is kept also when the run ends early: a timeout, a failure, the instance gone.
  write_report
  [ -n "$id" ] || return 0
  aws ec2 get-console-output --instance-id "$id" --latest --query Output --output text >"$out/console.txt" 2>/dev/null || true
  aws ec2 terminate-instances --instance-ids "$id" >/dev/null && step "Terminated $id"
}
trap finish EXIT

# Some zones don't have every instance type at times: try the next subnet. A client token per subnet makes each
# launch idempotent: if the call fails after EC2 accepted it (a timeout), the instance is found by its token and
# used, so finish() terminates it like any other.
for subnet in ${subnets//,/ }; do
  token="$name-$subnet"
  if id=$(aws ec2 run-instances --client-token "$token" --image-id "$ami" --instance-type "$type" \
    --network-interfaces "DeviceIndex=0,SubnetId=$subnet,Groups=$sg,AssociatePublicIpAddress=true,DeleteOnTermination=true" \
    --block-device-mappings "DeviceName=$root_device,Ebs={VolumeSize=40,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
    --instance-initiated-shutdown-behavior terminate ${profile_args[@]+"${profile_args[@]}"} \
    --tag-specifications "ResourceType=instance,Tags=[$tags]" "ResourceType=volume,Tags=[$tags]" \
    --user-data "file://$work/user-data.yaml" \
    --query 'Instances[0].InstanceId' --output text 2>"$work/run.err"); then
    break
  fi
  id=$(aws ec2 describe-instances --filters "Name=client-token,Values=$token" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
  if [[ $id == i-* ]]; then
    echo "    The launch call failed, but EC2 started $id: using it"
    break
  fi
  id=""
  grep -qE 'InsufficientInstanceCapacity|Unsupported' "$work/run.err" || fail "$(cat "$work/run.err")"
  echo "    No $type capacity in $subnet, trying the next subnet"
done
[ -n "$id" ] || fail "No subnet had $type capacity."
step "Started $id ($name). It installs everything, reboots into FIPS mode and runs the checks (about 15 minutes)"

started=$SECONDS
result=""
while [ $((SECONDS - started)) -lt $((timeout_min * 60)) ]; do
  sleep 20
  console=$(aws ec2 get-console-output --instance-id "$id" --latest --query Output --output text 2>/dev/null || true)
  # New lines in sequence order: --latest shows the current boot only, so a line written just before the
  # reboot can first arrive with END's replay, after later ones.
  while read -r seq kind text; do
    grep -q "^$seq " "$work/seen" 2>/dev/null && continue
    echo "$seq $kind $text" >>"$work/seen"
    printf '    %2dm%02ds  %-5s %s\n' $(((SECONDS - started) / 60)) $(((SECONDS - started) % 60)) "$kind" "$text"
    [ "$kind" = END ] && result=${text%% *}
  done < <(tr -d '\r' <<<"$console" | grep -oE 'FIPSRHEL [0-9]{4} [A-Z]+ .*' | cut -d' ' -f2- | sort -n -k1,1 -u)
  [ -n "$result" ] && break
  state=$(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)
  case $state in pending | running) ;; *) fail "The instance is $state before the checks finished." ;; esac
done
[ -n "$result" ] || fail "No result after $timeout_min minutes."

write_report
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### FIPS checks on RHEL 9"
    echo
    echo "Image \`$ami_name\` ($ami), \`$type\`, $AWS_REGION. Result: **$result**."
    echo
    if [ -n "$secure_url" ]; then
      echo "Liquibase Secure: \`$secure_url\`, sha256 \`$secure_sha256\`$([ -n "$license_role" ] && echo ", with the CI license")."
      echo
    fi
    echo "| Result | Check |"
    echo "| --- | --- |"
    awk '$1 == "PASS" || $1 == "FAIL" {k = $1; $1 = ""; print "| " k " |" $0 " |"}' "$out/report.txt"
    echo
    echo '```'
    awk '$1 == "ENV" || $1 == "INFO" {$1 = ""; sub(/^ /, ""); print}' "$out/report.txt"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi
[ "$result" = PASS ] || fail "Some checks failed on RHEL 9. See the report above."
step "All checks passed on RHEL 9"
