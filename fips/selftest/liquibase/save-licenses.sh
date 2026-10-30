#!/usr/bin/env bash
# Saves licenses from a vault secret to files for try-licenses.sh, masked in the log. Only the keys named, instead
# of exporting the whole secret into the environment (and the VM). Runs on the runner, after
# aws-actions/configure-aws-credentials; a key the secret doesn't have is skipped.
#
# usage: save-licenses.sh SECRET_ID DIR KEY...
set -euo pipefail

secret_id=${1:?usage: save-licenses.sh SECRET_ID DIR KEY...}
dir=${2:?usage: save-licenses.sh SECRET_ID DIR KEY...}
shift 2

json=$(aws secretsmanager get-secret-value --secret-id "$secret_id" --query SecretString --output text)
mkdir -p "$dir" && chmod 700 "$dir"
for key in "$@"; do
  value=$(jq -r --arg key "$key" '.[$key] // ""' <<<"$json")
  [ -n "$value" ] || continue
  while IFS= read -r line; do
    [ -n "$line" ] && echo "::add-mask::$line"
  done <<<"$value"
  printf '%s' "$value" > "$dir/$key"
  chmod 600 "$dir/$key"
done
