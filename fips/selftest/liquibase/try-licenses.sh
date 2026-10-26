#!/usr/bin/env bash
# Runs Liquibase Secure with each license, once with the FIPS-mode JVM and once with FIPS turned off for that JVM,
# and writes a table to the job summary. Used by the "Liquibase Secure licenses" job in fips-vm-test.yml, inside
# the FIPS VM.
#
# Fails only when a license doesn't work even with FIPS off, which means the license in the vault is broken.
# Today Liquibase 6 can't verify license files in a FIPS-mode JVM (LB-LIC-0003: Ed25519), so the FIPS rows are
# reported, not enforced, until the FIPS work changes the license signature (INT-2302, INT-2395).
#
# usage: try-licenses.sh LICENSES_DIR   (holds PRO_LICENSE_KEY and PRO_LICENSE_FILE, either may be missing)
set -euo pipefail

dir=${1:?usage: try-licenses.sh LICENSES_DIR}
classpath=${LIQUIBASE_CLASSPATH:-}
broken=0
rows=()

attempt() { # LICENSE_LABEL JVM_LABEL JAVA_OPTS ENV...
  local label=$1 jvm=$2 java_opts=$3
  shift 3
  local out status code update
  out=$(env "$@" JAVA_OPTS="$java_opts" liquibase ${classpath:+--classpath="$classpath"} license status 2>&1 || true)
  status=$(awk '/^Status:/ {print $2; exit}' <<<"$out")
  code=$(awk '/^Code:/ {print $2; exit}' <<<"$out")
  if env "$@" JAVA_OPTS="$java_opts" liquibase ${classpath:+--classpath="$classpath"} update >/dev/null 2>&1; then
    update=works
  else
    update=refused
  fi
  rows+=("| $label | $jvm | ${status:-unknown} | ${code:--} | $update |")
  echo "$label, $jvm JVM: license ${status:-unknown} ${code:+($code)}, update $update"
  if [ "$jvm" = "FIPS off" ] && [ "$update" != works ]; then
    echo "::error::The $label doesn't work even with FIPS off. Check the license in the vault."
    broken=1
  fi
}

for kind in key file; do
  if [ "$kind" = key ]; then
    label="old license key"
    secret="$dir/PRO_LICENSE_KEY"
  else
    label="new license file"
    secret="$dir/PRO_LICENSE_FILE"
  fi
  if [ ! -s "$secret" ]; then
    echo "::warning::No $label: $(basename "$secret") isn't in /vault/liquibase."
    rows+=("| $label | - | not in the vault | - | - |")
    continue
  fi
  if [ "$kind" = key ]; then
    license_env=("LIQUIBASE_LICENSE_KEY=$(cat "$secret")")
  else
    license_env=("LIQUIBASE_LICENSE_FILE=$secret")
  fi
  attempt "$label" "FIPS" "" "${license_env[@]}"
  attempt "$label" "FIPS off" "-Dcom.redhat.fips=false" "${license_env[@]}"
done

{
  echo "### Liquibase Secure $(liquibase --version 2>/dev/null | awk '/Liquibase Secure Version/ {print $4}') licenses in the FIPS VM"
  echo
  echo "| License | Liquibase JVM | License status | Code | update |"
  echo "| --- | --- | --- | --- | --- |"
  printf '%s\n' "${rows[@]}"
  echo
  echo "FIPS rows are reported, not enforced: Liquibase 6 can't verify Ed25519-signed license files in a FIPS-mode JVM yet (INT-2302, INT-2395)."
} >> "$GITHUB_STEP_SUMMARY"

exit "$broken"
