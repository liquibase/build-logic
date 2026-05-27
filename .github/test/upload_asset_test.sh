#!/usr/bin/env bash
# upload_asset_test.sh — regression test for upload_asset.sh discovery logic.
#
# Run manually:  bash .github/test/upload_asset_test.sh
# Expected exit: 0 (all cases pass)
#
# No network calls are made. curl is overridden to record uploaded filenames
# instead of contacting the GitHub API.
#
# Scenarios covered (mirrors spec acceptance scenarios 1-6):
#   CASE 1 — standard extension: base + javadoc + sources + pom uploaded
#   CASE 2 — opensearch-style: -fat.jar also uploaded
#   CASE 3 — neo4j-style: -full.jar also uploaded
#   CASE 4 — exclusion: -tests.jar and original-*.jar are NOT uploaded
#   CASE 5 — zero-JAR guard: empty fixture dir exits 1
#   CASE 6 — zero-byte guard: corrupted JAR exits 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GITHUB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/target"

PASS=0
FAIL=0

# Prepare a sandboxed copy of upload_asset.sh alongside a stub
# get_draft_release.sh. upload_asset.sh uses dirname "$0" to locate its
# sibling scripts, so both must live in the same directory.
make_sandbox() {
  local sandbox
  sandbox=$(mktemp -d)
  cp "$GITHUB_DIR/upload_asset.sh" "$sandbox/"

  # Stub: always returns the test upload URL.
  cat > "$sandbox/get_draft_release.sh" <<'STUB'
#!/usr/bin/env bash
echo "https://stub.github.test/upload"
STUB
  chmod +x "$sandbox/get_draft_release.sh"

  echo "$sandbox"
}

# Runs upload_asset.sh in the sandbox with a curl stub that records uploaded
# filenames. Outputs the list of uploaded basenames to stdout.
run_upload() {
  local asset_dir="$1"
  local version="$2"
  local uploaded_file="$3"

  local sandbox
  sandbox=$(make_sandbox)

  # Override curl inside the subshell: extract ?name=<value> and record it.
  # Pass the recording path via UPLOAD_RECORD_FILE so set -u in upload_asset.sh
  # does not treat the captured closure variable as unbound.
  (
    UPLOAD_RECORD_FILE="$uploaded_file"
    export UPLOAD_RECORD_FILE
    curl() {
      local last_arg=""
      for arg in "$@"; do last_arg="$arg"; done
      echo "${last_arg##*name=}" >> "$UPLOAD_RECORD_FILE"
    }
    export -f curl

    GITHUB_TOKEN="stub" \
    ASSET_NAME_PREFIX="ext-" \
    ASSET_DIR="$asset_dir" \
      bash "$sandbox/upload_asset.sh" "$version" 2>&1 || true
  )

  rm -rf "$sandbox"
}

# Runs upload_asset.sh and captures its exit code without aborting the suite.
run_upload_exit_code() {
  local asset_dir="$1"
  local version="$2"

  local sandbox
  sandbox=$(make_sandbox)

  local exit_code=0
  (
    curl() { :; }
    export -f curl

    GITHUB_TOKEN="stub" \
    ASSET_NAME_PREFIX="ext-" \
    ASSET_DIR="$asset_dir" \
      bash "$sandbox/upload_asset.sh" "$version" >/dev/null 2>&1
  ) || exit_code=$?

  rm -rf "$sandbox"
  echo "$exit_code"
}

assert_contains() {
  local case_name="$1"
  local uploaded_file="$2"
  local expected="$3"
  if grep -qF "$expected" "$uploaded_file"; then
    echo "  PASS: $case_name — found '$expected'"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $case_name — expected '$expected' not in uploaded list"
    echo "  Uploaded: $(tr '\n' ' ' < "$uploaded_file")"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local case_name="$1"
  local uploaded_file="$2"
  local unexpected="$3"
  if grep -qF "$unexpected" "$uploaded_file"; then
    echo "  FAIL: $case_name — found unexpected '$unexpected' in uploaded list"
    echo "  Uploaded: $(tr '\n' ' ' < "$uploaded_file")"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $case_name — correctly absent '$unexpected'"
    PASS=$((PASS + 1))
  fi
}

assert_exit_code() {
  local case_name="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $case_name — exit code $actual"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $case_name — expected exit $expected, got $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo ""
echo "=== CASE 1: standard artifacts uploaded ==="
uploaded=$(mktemp)
run_upload "$FIXTURE_DIR" "1.0.0" "$uploaded"
assert_contains "base jar"    "$uploaded" "ext-1.0.0.jar"
assert_contains "javadoc jar" "$uploaded" "ext-1.0.0-javadoc.jar"
assert_contains "sources jar" "$uploaded" "ext-1.0.0-sources.jar"
assert_contains "pom"         "$uploaded" "ext-1.0.0.pom"
rm -f "$uploaded"

# ---------------------------------------------------------------------------
echo ""
echo "=== CASE 2: opensearch-style -fat.jar uploaded ==="
uploaded=$(mktemp)
run_upload "$FIXTURE_DIR" "1.0.0" "$uploaded"
assert_contains "fat jar"     "$uploaded" "ext-1.0.0-fat.jar"
assert_contains "fat jar asc" "$uploaded" "ext-1.0.0-fat.jar.asc"
rm -f "$uploaded"

# ---------------------------------------------------------------------------
echo ""
echo "=== CASE 3: neo4j-style -full.jar uploaded ==="
uploaded=$(mktemp)
run_upload "$FIXTURE_DIR" "1.0.0" "$uploaded"
assert_contains "full jar" "$uploaded" "ext-1.0.0-full.jar"
rm -f "$uploaded"

# ---------------------------------------------------------------------------
echo ""
echo "=== CASE 4: excluded artifacts absent ==="
uploaded=$(mktemp)
run_upload "$FIXTURE_DIR" "1.0.0" "$uploaded"
assert_not_contains "tests jar excluded"    "$uploaded" "ext-1.0.0-tests.jar"
assert_not_contains "original jar excluded" "$uploaded" "original-ext-1.0.0.jar"
rm -f "$uploaded"

# ---------------------------------------------------------------------------
echo ""
echo "=== CASE 5: zero-JAR guard (empty target dir exits 1) ==="
empty_dir=$(mktemp -d)
exit_code=$(run_upload_exit_code "$empty_dir" "9.9.9")
assert_exit_code "zero-JAR guard" "$exit_code" "1"
rm -rf "$empty_dir"

# ---------------------------------------------------------------------------
echo ""
echo "=== CASE 6: zero-byte JAR guard (exits 1) ==="
zero_dir=$(mktemp -d)
touch "$zero_dir/ext-9.9.9.jar"   # zero bytes — simulates corrupted artifact
echo "fixture" > "$zero_dir/ext-9.9.9.pom"
exit_code=$(run_upload_exit_code "$zero_dir" "9.9.9")
assert_exit_code "zero-byte guard" "$exit_code" "1"
rm -rf "$zero_dir"

# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
