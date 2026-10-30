#!/usr/bin/env bash
# Gets what the Liquibase Secure checks need, on the instance's first boot, before FIPS mode is on. Runs as root
# from instance.sh after provision.sh. Settings come from run.sh in run.env (see run.sh).
#
#   - The release archive (FIPS_RHEL_SECURE_URL), checked against FIPS_RHEL_SECURE_SHA256, unpacked to
#     /opt/liquibase-secure.
#   - The CI license, when FIPS_RHEL_LICENSE_ROLE_ARN is set: with the instance role, assume that vault role
#     (it lists fips-rhel-instance in aws_roles) and read PRO_LICENSE_FILE from /vault/grouped/pro-license-file
#     into /root/.fips-rhel/license.lic. The license never passes through the runner or the user data.
#
# usage: secure.sh RUN_ENV
set -euo pipefail

# shellcheck source=/dev/null
. "${1:?usage: secure.sh RUN_ENV}"

# AWS CLI v2, pinned: its signature checked with the AWS CLI Team key (FB5D B77F D5C1 18B8 0511 ADA8 A631
# 0ACC 4672 475C) when the pin was set.
awscli_version=2.39.2
awscli_sha256=bb3e675d5c9a915121f3f90b380ec041ba52517067d017e4a4ceba40e0213247
license_secret=/vault/grouped/pro-license-file
work=$(mktemp -d)

if [ -n "${FIPS_RHEL_SECURE_URL:-}" ]; then
  curl -fsSL --retry 3 -o "$work/secure.tar.gz" "$FIPS_RHEL_SECURE_URL"
  echo "$FIPS_RHEL_SECURE_SHA256  $work/secure.tar.gz" | sha256sum -c -
  rm -rf /opt/liquibase-secure && mkdir -p /opt/liquibase-secure
  tar -xzf "$work/secure.tar.gz" -C /opt/liquibase-secure
  [ -x /opt/liquibase-secure/liquibase ] || {
    echo "The archive has no liquibase launcher at its top level." >&2
    exit 1
  }
fi

if [ -n "${FIPS_RHEL_LICENSE_ROLE_ARN:-}" ]; then
  curl -fsSL --retry 3 -o "$work/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${awscli_version}.zip"
  echo "$awscli_sha256  $work/awscli.zip" | sha256sum -c -
  unzip -q "$work/awscli.zip" -d "$work"
  "$work/aws/install" -i /opt/aws-cli -b /usr/local/bin --update >/dev/null
  export AWS_REGION=us-east-1
  read -r key secret token < <(aws sts assume-role --role-arn "$FIPS_RHEL_LICENSE_ROLE_ARN" \
    --role-session-name fips-rhel --duration-seconds 900 \
    --query 'Credentials.[AccessKeyId, SecretAccessKey, SessionToken]' --output text)
  umask 077
  mkdir -p /root/.fips-rhel
  AWS_ACCESS_KEY_ID=$key AWS_SECRET_ACCESS_KEY=$secret AWS_SESSION_TOKEN=$token \
    aws secretsmanager get-secret-value --secret-id "$license_secret" --query SecretString --output text |
    jq -r '.PRO_LICENSE_FILE // empty' >/root/.fips-rhel/license.lic
  [ -s /root/.fips-rhel/license.lic ] || {
    echo "$license_secret has no PRO_LICENSE_FILE." >&2
    exit 1
  }
fi

rm -rf "$work"
