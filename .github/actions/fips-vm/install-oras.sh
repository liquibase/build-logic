#!/usr/bin/env bash
# Installs a pinned oras CLI, which pulls and pushes the FIPS VM image on GHCR, and checks its SHA-256.
# The org's Actions policy doesn't allow oras-project/setup-oras, so this downloads the release directly.
set -euo pipefail

version=1.3.6
sha256=66fb0ad7206f3f6fa77ed5b552049d364ccf4b50b1684554f731f76302b52ca0

if command -v oras >/dev/null && oras version | grep -q "^Version: *$version\$"; then
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/oras.tar.gz" \
  "https://github.com/oras-project/oras/releases/download/v${version}/oras_${version}_linux_amd64.tar.gz"
echo "$sha256  $tmp/oras.tar.gz" | sha256sum -c - >/dev/null
tar -xzf "$tmp/oras.tar.gz" -C "$tmp" oras
sudo install -m 0755 "$tmp/oras" /usr/local/bin/oras
