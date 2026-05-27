#!/usr/bin/env bash
# upload_asset.sh — upload every JAR Maven produced for this version, plus the POM.
#
# Discovery shape: glob target/${ASSET_NAME_PREFIX}${VERSION}*.jar, then exclude
# Maven byproducts. The same exclusion patterns are mirrored in the Sign step of
# extension-attach-artifact-release.yml; keep both in sync if you add an entry here.

set -euo pipefail

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Set the GITHUB_TOKEN env variable."
  exit 1
fi

if [[ -z "${ASSET_NAME_PREFIX:-}" ]]; then
  echo "Set the ASSET_NAME_PREFIX env variable."
  exit 1
fi

if [[ -z "${ASSET_DIR:-}" ]]; then
  echo "Set the ASSET_DIR env variable."
  exit 1
fi

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Set the VERSION parameter."
  exit 1
fi

_DIR=$(dirname "$0")
UPLOAD_URL=$($_DIR/get_draft_release.sh UPLOAD_URL)

echo "UPLOAD_URL: $UPLOAD_URL"

# Upload a single file. Tolerant of missing sidecars (returns 0); fails hard on
# zero-byte files (corrupted artifact = broken release).
upload_one() {
  local file="$1"
  [[ ! -f "$file" ]] && return 0   # missing sidecar is acceptable
  local size
  size=$(wc -c < "$file" | tr -d ' ')
  if [[ "$size" -eq 0 ]]; then
    echo "::error::$(basename "$file") is empty — aborting upload."
    exit 1
  fi
  local mime
  mime=$(file -b --mime-type "$file")
  curl -fsS \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Length: $size" \
    -H "Content-Type: $mime" \
    --data-binary @"$file" \
    "$UPLOAD_URL?name=$(basename "$file")"
}

# Returns 0 (true) if the basename matches a Maven byproduct that must NOT be
# published to a GitHub release.
is_excluded() {
  local name="$1"
  case "$name" in
    *-tests.jar)       return 0 ;;  # Maven Failsafe/Surefire test-jar
    *-test-sources.jar) return 0 ;; # Maven test source jar
    original-*.jar)    return 0 ;;  # Maven Shade pre-shading leftover
    *.jar.original)    return 0 ;;  # Maven Shade alternate extension for same leftover
  esac
  return 1
}

# Sidecars that accompany every JAR (uploaded only when present).
SIDECARS=(".asc" ".md5" ".sha1")

# Discover every JAR Maven produced for this version. nullglob ensures an
# empty match expands to zero elements instead of a literal pattern string.
shopt -s nullglob
JARS=("$ASSET_DIR/${ASSET_NAME_PREFIX}${VERSION}"*.jar)
shopt -u nullglob

# Regression guard: a Maven build failure leaves target/ empty. Catch it here
# rather than silently producing a release with no JARs attached.
# Use array-length check (not bare expansion) to stay safe under set -u.
if [[ ${#JARS[@]} -eq 0 ]]; then
  echo "::error::No JARs matched ${ASSET_NAME_PREFIX}${VERSION}*.jar in ${ASSET_DIR} — aborting."
  exit 1
fi

# Upload each discovered JAR (skip Maven byproducts) and its sidecars.
for jar in "${JARS[@]}"; do
  base=$(basename "$jar")
  if is_excluded "$base"; then
    echo "Skipping excluded artifact: $base"
    continue
  fi
  upload_one "$jar"
  for ext in "${SIDECARS[@]}"; do
    upload_one "${jar}${ext}"
  done
done

# Upload the POM and its sidecars explicitly — POM lives alongside JARs but is
# not itself a *.jar, so it is handled separately.
POM="$ASSET_DIR/${ASSET_NAME_PREFIX}${VERSION}.pom"
upload_one "$POM"
for ext in "${SIDECARS[@]}"; do
  upload_one "${POM}${ext}"
done
