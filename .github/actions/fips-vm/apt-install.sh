#!/usr/bin/env bash
# Installs Ubuntu packages quickly on a CI runner: reads only the Ubuntu archive (hosted runners carry many
# third-party repos) and skips the slow man-db and needrestart steps. Prints how long each part took.
#
# FIPS_VM_APT_CACHE, if set, is a folder that keeps the downloaded .deb files between jobs (see actions/cache in
# action.yml). Some hosted runners download from the Ubuntu mirror at a few hundred kB/s, which turns a
# 10-second install into 10 minutes.
#
# usage: apt-install.sh PACKAGE...
set -euo pipefail

opts=(-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sources=$(mktemp -d)
  cp /etc/apt/sources.list.d/ubuntu.sources "$sources/"
  opts+=(-o Dir::Etc::SourceList=/dev/null -o "Dir::Etc::SourceParts=$sources")
fi
if [ -n "${FIPS_VM_APT_CACHE:-}" ]; then
  FIPS_VM_APT_CACHE=${FIPS_VM_APT_CACHE/#\~/$HOME}
  mkdir -p "$FIPS_VM_APT_CACHE/partial"
  opts+=(-o "Dir::Cache::Archives=$FIPS_VM_APT_CACHE")
  cached=$(find "$FIPS_VM_APT_CACHE" -maxdepth 1 -name '*.deb' | wc -l)
fi
sudo rm -f /var/lib/man-db/auto-update

log=$(mktemp)
start=$SECONDS
sudo apt-get "${opts[@]}" update -qq
update=$((SECONDS - start))
start=$SECONDS
# shellcheck disable=SC2024 # the log is the runner user's file on purpose
if ! sudo NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive \
  apt-get "${opts[@]}" install -y --no-install-recommends "$@" >"$log" 2>&1; then
  cat "$log"
  exit 1
fi
fetched=$(grep -m1 '^Fetched' "$log" || echo "nothing downloaded")
echo "    apt-get update ${update}s, install $((SECONDS - start))s (${fetched}${cached:+; $cached packages were cached})"

if [ -n "${FIPS_VM_APT_CACHE:-}" ]; then
  # actions/cache saves the folder as the runner user.
  sudo rm -rf "$FIPS_VM_APT_CACHE/partial" "$FIPS_VM_APT_CACHE/lock"
  sudo chown -R "$(id -u):$(id -g)" "$FIPS_VM_APT_CACHE"
fi
