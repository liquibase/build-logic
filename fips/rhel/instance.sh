#!/usr/bin/env bash
# Runs on every boot of the RHEL 9 instance that run.sh starts, as root, from cloud-init's per-boot scripts.
#
# First boot: installs everything with fips/provision.sh, which turns FIPS mode on from the next boot. Then
# cloud-init reboots (power_state in run.sh's user data). Next boot, in FIPS mode: runs checks.sh once.
# Progress goes to the serial console as marker lines (say.sh); command output goes to /var/log/fips-rhel/.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fips=$(dirname "$here")
log=/var/log/fips-rhel/provision.log
mkdir -p /var/log/fips-rhel /var/lib/fips-rhel

say() { "$here/say.sh" "$@"; }

if [ "$(cat /proc/sys/crypto/fips_enabled)" = 1 ]; then
  [ -f /var/lib/fips-rhel/checked ] && exit 0
  touch /var/lib/fips-rhel/checked
  say STEP "Booted in FIPS mode"
  exec "$here/checks.sh" "$fips/selftest"
fi

if [ -f /var/lib/fips-vm/provisioned ]; then
  say END "FAIL The instance rebooted after provisioning, but FIPS mode is still off"
  exit 1
fi

say STEP "Installing Docker, Java and Maven, and turning FIPS mode on (fips/provision.sh)"
if bash "$fips/provision.sh" >"$log" 2>&1; then
  say STEP "Installed. Rebooting into FIPS mode"
else
  say FAIL "provision: fips/provision.sh failed"
  tail -n 20 "$log" | while IFS= read -r line; do say LOG "provision: $line"; done
  say END "FAIL Installing the software failed"
  exit 1
fi
