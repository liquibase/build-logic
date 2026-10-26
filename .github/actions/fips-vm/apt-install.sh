#!/usr/bin/env bash
# Installs Ubuntu packages quickly on a CI runner: reads only the Ubuntu archive (hosted runners carry many
# third-party repos) and skips the slow man-db and needrestart steps. Prints how long each part took.
#
# usage: apt-install.sh PACKAGE...
set -euo pipefail

opts=(-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sources=$(mktemp -d)
  cp /etc/apt/sources.list.d/ubuntu.sources "$sources/"
  opts+=(-o Dir::Etc::SourceList=/dev/null -o "Dir::Etc::SourceParts=$sources")
fi
sudo rm -f /var/lib/man-db/auto-update

start=$SECONDS
sudo apt-get "${opts[@]}" update -qq
update=$((SECONDS - start))
start=$SECONDS
sudo NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive \
  apt-get "${opts[@]}" install -y -qq --no-install-recommends "$@" >/dev/null
echo "    apt-get update ${update}s, install $((SECONDS - start))s"
