#!/usr/bin/env bash
# The FIPS VM self-test (the "FIPS VM on ubuntu-latest" job in .github/workflows/fips-vm-test.yml), on a real
# RHEL 9 host in FIPS mode. Keep the two in step. Runs as root on the instance that run.sh starts, from
# instance.sh, after the reboot into FIPS mode.
#
# Each result is a marker line for run.sh, which reads the serial console. Command output goes to a log file
# instead, so the console stays short; a failed check prints the end of its output to the console.
#
# usage: checks.sh SELFTEST_DIR   (the bundled fips/selftest)
set -uo pipefail

selftest=${1:?usage: checks.sh SELFTEST_DIR}
# shellcheck source=/dev/null
. "$selftest/../../run.env"
secure=/opt/liquibase-secure
license=/root/.fips-rhel/license.lic
log=/var/log/fips-rhel/checks.log
work=$(mktemp -d)
mkdir -p "$(dirname "$log")"
# shellcheck source=/dev/null
. /etc/profile.d/fips-vm.sh
passed=0
failed=0

say() { "$(dirname "${BASH_SOURCE[0]}")/say.sh" "$@"; }

# check NAME DESCRIPTION COMMAND...: runs the command, logs its output and reports PASS or FAIL.
check() {
  local name=$1 description=$2 out
  shift 2
  out="$work/$name.out"
  if "$@" >"$out" 2>&1; then
    say PASS "$name: $description"
    passed=$((passed + 1))
  else
    say FAIL "$name: $description"
    tail -n 15 "$out" | while IFS= read -r line; do say LOG "$name: $line"; done
    failed=$((failed + 1))
  fi
  { echo "== $name: $description"; cat "$out"; } >>"$log"
}

kernel_fips() {
  fips-mode-setup --check | tee /dev/stderr | grep -q 'FIPS mode is enabled' &&
    [ "$(cat /proc/sys/crypto/fips_enabled)" = 1 ] &&
    [ "$(update-crypto-policies --show)" = FIPS ]
}

real_rhel() {
  grep -E '^Red Hat Enterprise Linux release 9' /etc/redhat-release
}

ubi9_inherits() {
  [ "$(docker run --rm registry.access.redhat.com/ubi9/ubi-minimal cat /proc/sys/crypto/fips_enabled)" = 1 ]
}

java_fips() {
  local on off
  on=$(java -XshowSettings:security:providers -version 2>&1 | awk '/Provider name:/ {print $3; exit}')
  off=$(java -Dcom.redhat.fips=false -XshowSettings:security:providers -version 2>&1 |
    awk '/Provider name:/ {print $3; exit}')
  echo "First security provider: $on by default, $off with -Dcom.redhat.fips=false"
  [ "$on" = SunPKCS11-NSS-FIPS ] && [ "$off" != SunPKCS11-NSS-FIPS ]
}

compose_postgres() {
  docker compose -f "$selftest/compose.yml" up -d --wait &&
    docker compose -f "$selftest/compose.yml" exec -T postgres psql -U postgres -tAc 'select 1'
}

# Liquibase OSS needs no license. Liquibase 5 doesn't bundle JDBC drivers.
liquibase_update() {
  [ -f /etc/yum.repos.d/repo-liquibase-com.repo ] ||
    dnf config-manager --add-repo https://repo.liquibase.com/repo-liquibase-com.repo
  dnf install -y -q liquibase &&
    curl -fsSL -o "$work/postgresql.jar" \
      https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.14/postgresql-42.7.14.jar || return 1
  liquibase --version | grep -E 'Liquibase Version|Java Home'
  (
    cd "$selftest/liquibase" || exit 1
    export LIQUIBASE_COMMAND_URL=jdbc:postgresql://localhost:5432/postgres
    export LIQUIBASE_COMMAND_USERNAME=postgres
    export LIQUIBASE_COMMAND_PASSWORD=fips-vm-selftest-password
    export LIQUIBASE_COMMAND_CHANGELOG_FILE=changelog.yaml
    liquibase --classpath="$work/postgresql.jar" update &&
      liquibase --classpath="$work/postgresql.jar" validate &&
      liquibase --classpath="$work/postgresql.jar" rollback-count --count=1 &&
      liquibase --classpath="$work/postgresql.jar" update
  ) || return 1
  docker compose -f "$selftest/compose.yml" exec -T postgres psql -U postgres -tAc 'select note from fips_check' |
    grep -qx 'written by Liquibase in the FIPS VM'
}

secure_version() {
  "$secure/liquibase" --version 2>&1 | tee /dev/stderr |
    grep -qE "Liquibase Secure Version: ${FIPS_RHEL_SECURE_VERSION%%-*}"
}

# secure_run JAVA_OPTS: license status and update on the `secure` database with the CI license. Prints
# "<status> <code> <update>" and fails when update fails.
secure_run() {
  local out status code
  out=$(env JAVA_OPTS="$1" LIQUIBASE_LICENSE_FILE="$license" LIQUIBASE_ANALYTICS_ENABLED=false \
    timeout -k 10 180 "$secure/liquibase" license status 2>&1) || true
  status=$(awk '/^Status:/ {print $2; exit}' <<<"$out")
  code=$(awk '/^Code:/ {print $2; exit}' <<<"$out")
  if (
    cd "$selftest/liquibase" &&
      env JAVA_OPTS="$1" LIQUIBASE_LICENSE_FILE="$license" LIQUIBASE_ANALYTICS_ENABLED=false \
        LIQUIBASE_COMMAND_URL=jdbc:postgresql://localhost:5432/secure LIQUIBASE_COMMAND_USERNAME=postgres \
        LIQUIBASE_COMMAND_PASSWORD=fips-vm-selftest-password LIQUIBASE_COMMAND_CHANGELOG_FILE=changelog.yaml \
        timeout -k 10 180 "$secure/liquibase" update
  ) >&2; then
    echo "${status:-unknown} ${code:--} works"
  else
    echo "${status:-unknown} ${code:--} refused"
    return 1
  fi
}

secure_fips_off() { secure_run -Dcom.redhat.fips=false; }
secure_fips() { secure_run ""; }

testcontainers_postgres() {
  MAVEN_OPTS=-Dcom.redhat.fips=false mvn -B -ntp -f "$selftest/pom.xml" verify
}

maven_in_fips_mode() {
  mvn -B -ntp -q -f "$selftest/pom.xml" -Dmaven.repo.local="$work/m2-fips" -DskipTests verify
}

say STEP "Running the checks"
check fips "The kernel is in FIPS mode, with the FIPS crypto policy" kernel_fips
check rhel "The host is Red Hat Enterprise Linux 9" real_rhel
check ubi9 "A UBI 9 container inherits FIPS mode" ubi9_inherits
check java "Red Hat OpenJDK runs in FIPS mode, and -Dcom.redhat.fips=false turns it off" java_fips
check compose "docker compose starts PostgreSQL" compose_postgres
check liquibase "Liquibase updates PostgreSQL with a FIPS-mode JVM" liquibase_update

# Liquibase Secure from the release archive, when run.sh named one (secure.sh unpacked it).
if [ -x "$secure/liquibase" ]; then
  check secure-version "Liquibase Secure $FIPS_RHEL_SECURE_VERSION from the release archive starts" secure_version
  if [ -s "$license" ]; then
    docker compose -f "$selftest/compose.yml" exec -T postgres psql -U postgres -qc 'create database secure' >>"$log" 2>&1
    check secure-fips-off "Liquibase Secure: the license and update work with FIPS off for Liquibase" secure_fips_off
    if [ "${FIPS_RHEL_REQUIRE_FIPS_LICENSE:-false}" = true ]; then
      check secure-fips "Liquibase Secure: the license verifies and update works in FIPS mode" secure_fips
    else
      # Liquibase 6 can't verify license files in FIPS mode until INT-2438, so this is reported, not enforced.
      result=$(secure_fips 2>>"$log" || true)
      read -r status code update <<<"$result"
      say INFO "Liquibase Secure in FIPS mode: license $status ($code), update $update. Not enforced until license files verify in FIPS mode (INT-2438)"
    fi
  else
    say INFO "No license: the Liquibase Secure license and update checks were skipped"
  fi
fi
# The instance is discarded after the checks, so a failed teardown is reported but doesn't fail the run.
docker compose -f "$selftest/compose.yml" down >>"$log" 2>&1 ||
  say INFO "compose: docker compose down failed (see $log)"
check testcontainers "Testcontainers starts PostgreSQL and a FIPS-mode JVM connects" testcontainers_postgres
# Informational, as in the self-test: Maven itself in FIPS mode.
if maven_in_fips_mode >>"$log" 2>&1; then
  say INFO "Maven itself works in FIPS mode"
else
  say INFO "Maven itself fails in FIPS mode (informational)"
fi

# shellcheck source=/dev/null
say ENV "os: $(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)"
say ENV "$(fips-mode-setup --check 2>&1 | tail -n 1) crypto policy: $(update-crypto-policies --show)"
say ENV "java: $(java -version 2>&1 | head -n 1)"
say ENV "docker: $(docker --version)"
say ENV "liquibase: $(liquibase --version 2>/dev/null | awk '/Liquibase Version/ {print $3}')"
if [ -x "$secure/liquibase" ]; then
  say ENV "liquibase secure: $("$secure/liquibase" --version 2>/dev/null | awk '/Liquibase Secure Version/ {print $4}')"
fi

if [ "$failed" = 0 ]; then
  say END "PASS $passed checks passed"
else
  say END "FAIL $failed of $((passed + failed)) checks failed"
fi
