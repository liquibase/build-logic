#!/usr/bin/env bash
# Writes one marker line to the serial console, where run.sh reads it: "FIPSRHEL <seq> <KIND> <text>".
# KIND is STEP, PASS, FAIL, INFO, LOG, ENV or END. run.sh prints each sequence number once, and END replays
# every earlier line first, in case some scrolled out of the console output that EC2 keeps.
#
# usage: say.sh KIND TEXT...
set -euo pipefail

kind=$1
shift
state=/var/lib/fips-rhel
mkdir -p "$state"
seq=$(($(cat "$state/seq" 2>/dev/null || echo 0) + 1))
echo "$seq" >"$state/seq"
text=$(printf '%s' "$*" | tr -d '\r' | tr '\n\t' '  ' | cut -c1-300)
line=$(printf 'FIPSRHEL %04d %s %s' "$seq" "$kind" "$text")

if [ "$kind" = END ] && [ -f "$state/report.txt" ]; then
  cat "$state/report.txt" >/dev/console
fi
echo "$line" >>"$state/report.txt"
echo "$line" >/dev/console
