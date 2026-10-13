#!/usr/bin/env bash
# Regression tests for scripts/dr-validation/lib.sh's mssql-hammerdb credential
# parsing (load_mssql_credentials via values_secret_field / secret_block).
#
# Background: values-secret.yaml commonly stores mssql-hammerdb in
# ExternalSecrets-style nested list form:
#   - name: mssql-hammerdb
#     vaultPrefixes:
#       - global
#     fields:
#       - name: sa_password
#         value: ...
#       - name: user
#         value: hammerdb
#       - name: password
#         value: ...
#
# secret_block()'s boundary regex used to accept "0 or 2 leading spaces" as
# the indentation of the *next* "- name:"/"- fields:" entry, regardless of
# the current secret's own indentation. Both PyYAML's default dumper (used
# when redeploy.sh merges spoke kubeconfigs into .work/values-secret.yaml)
# and hand-written values-secret.yaml files render nested "fields:" list
# items at only 2 spaces deeper than the secret's own "- name:" line, so
# that fixed "0 or 2" boundary pattern could match a *nested* field entry
# (e.g. "  - name: sa_password") and truncate the block right after
# "fields:", before any field values were captured - even though the
# secret data itself was complete and correctly structured.
#
# These tests use synthetic (non-secret, dummy) values-secret.yaml fixtures
# to confirm the parser now correctly extracts all 3 fields regardless of
# indentation style, and does not swallow neighboring secrets.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

TOTAL_FAIL=0

reset_env() {
  unset DR_VALIDATION_MSSQL_SA_PASSWORD DR_VALIDATION_MSSQL_USER DR_VALIDATION_MSSQL_PASSWORD 2>/dev/null || true
}

assert_success() {
  local label="$1" expected_sa="$2" expected_user="$3" expected_pw="$4"
  if [[ "${DR_VALIDATION_MSSQL_SA_PASSWORD:-}" == "$expected_sa" \
    && "${DR_VALIDATION_MSSQL_USER:-}" == "$expected_user" \
    && "${DR_VALIDATION_MSSQL_PASSWORD:-}" == "$expected_pw" ]]; then
    echo "  OK   $label: sa_password/user/password extracted correctly"
  else
    echo "  FAIL $label: expected ($expected_sa/$expected_user/$expected_pw)," \
      "got (${DR_VALIDATION_MSSQL_SA_PASSWORD:-<empty>}/${DR_VALIDATION_MSSQL_USER:-<empty>}/${DR_VALIDATION_MSSQL_PASSWORD:-<empty>})"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
}

main() {
  echo "=== dr-validation/lib.sh mssql-hammerdb credential parsing tests ==="
  echo ""

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # --- Scenario 1: PyYAML-style / hand-written nested list, 2-space indent,
  #     mssql-hammerdb followed by another secret (the real-world shape seen
  #     in both ~/values-secret.yaml and the .work/ BYOC-merged copy). ---
  echo "--- Scenario 1: nested list, 2-space indent, secret NOT last in file ---"
  cat >"$tmpdir/case1.yaml" <<'EOF'
version: 2.0
secrets:
- name: some-other-secret
  fields:
  - name: token
    value: unrelated-token-should-not-leak
- name: mssql-hammerdb
  vaultPrefixes:
  - global
  fields:
  - name: sa_password
    value: TestSaPass123
  - name: user
    value: hammerdb
  - name: password
    value: TestHdbPass456
- name: yet-another-secret
  fields:
  - name: apiKey
    value: unrelated-key-should-not-leak
EOF
  reset_env
  VALUES_SECRET="$tmpdir/case1.yaml" load_mssql_credentials || true
  assert_success "Scenario 1" "TestSaPass123" "hammerdb" "TestHdbPass456"
  echo ""

  # --- Scenario 2: same shape, but mssql-hammerdb is the LAST secret (no
  #     trailing sibling entry to bound the block; exercises the
  #     end-of-text fallback path). ---
  echo "--- Scenario 2: nested list, 2-space indent, secret IS last in file ---"
  cat >"$tmpdir/case2.yaml" <<'EOF'
version: 2.0
secrets:
- name: some-other-secret
  fields:
  - name: token
    value: unrelated-token-should-not-leak
- name: mssql-hammerdb
  vaultPrefixes:
  - global
  fields:
  - name: sa_password
    value: LastSaPass789
  - name: user
    value: hammerdb
  - name: password
    value: LastHdbPass012
EOF
  reset_env
  VALUES_SECRET="$tmpdir/case2.yaml" load_mssql_credentials || true
  assert_success "Scenario 2" "LastSaPass789" "hammerdb" "LastHdbPass012"
  echo ""

  # --- Scenario 3: deeper (4-space) nested indent style, as shared by Elsa
  #     for her working values-secret.yaml. ---
  echo "--- Scenario 3: nested list, 4-space indent (Elsa's shared shape) ---"
  cat >"$tmpdir/case3.yaml" <<'EOF'
- name: mssql-hammerdb
  vaultPrefixes:
    - global
  fields:
    - name: sa_password
      value: DeepSaPass111
    - name: user
      value: hammerdb
    - name: password
      value: DeepHdbPass222
- name: another-secret
  fields:
    - name: token
      value: unrelated-should-not-leak
EOF
  reset_env
  VALUES_SECRET="$tmpdir/case3.yaml" load_mssql_credentials || true
  assert_success "Scenario 3" "DeepSaPass111" "hammerdb" "DeepHdbPass222"
  echo ""

  # --- Scenario 4: secrets list itself nested under a parent key, so the
  #     secret's own "- name:" line is indented 2 spaces (not 0), and its
  #     nested fields land at 4 spaces. Exercises the general "match the
  #     anchor's own indentation" fix rather than a hardcoded "0 or 2". ---
  echo "--- Scenario 4: secrets list nested under parent key (anchor at 2-space indent) ---"
  cat >"$tmpdir/case4.yaml" <<'EOF'
clusterGroup:
  secrets:
  - name: mssql-hammerdb
    vaultPrefixes:
    - global
    fields:
    - name: sa_password
      value: NestedSaPass333
    - name: user
      value: hammerdb
    - name: password
      value: NestedHdbPass444
  - name: sibling-secret
    fields:
    - name: token
      value: unrelated-should-not-leak
EOF
  reset_env
  VALUES_SECRET="$tmpdir/case4.yaml" load_mssql_credentials || true
  assert_success "Scenario 4" "NestedSaPass333" "hammerdb" "NestedHdbPass444"
  echo ""

  # --- Scenario 5: negative case - a field is genuinely missing. Must fail
  #     (non-zero return, no partial credential set), not silently succeed
  #     with 2 of 3 fields. ---
  echo "--- Scenario 5: negative case, password field genuinely missing ---"
  cat >"$tmpdir/case5.yaml" <<'EOF'
- name: mssql-hammerdb
  fields:
  - name: sa_password
    value: OnlyTwoFields1
  - name: user
    value: hammerdb
- name: another-secret
  fields:
  - name: token
    value: unrelated
EOF
  reset_env
  if VALUES_SECRET="$tmpdir/case5.yaml" load_mssql_credentials; then
    echo "  FAIL Scenario 5: expected failure (missing password field) but load_mssql_credentials returned 0"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  elif [[ -n "${DR_VALIDATION_MSSQL_SA_PASSWORD:-}" || -n "${DR_VALIDATION_MSSQL_PASSWORD:-}" ]]; then
    echo "  FAIL Scenario 5: expected no partial credentials set, but some were populated"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  else
    echo "  OK   Scenario 5: correctly failed with no partial credentials on missing field"
  fi
  echo ""

  # --- Scenario 6: negative case - mssql-hammerdb (nested 2 spaces under
  #     clusterGroup.secrets) is genuinely missing its password field, and
  #     is immediately followed by an UNRELATED, LOWER-indentation (root
  #     level) secret list whose own nested fields use standard (+2 deeper
  #     than their "fields:" key, not the "compact" same-column style)
  #     indentation, so NONE of its lines land at exactly mssql-hammerdb's
  #     own 2-space anchor indentation. A boundary that only recognizes a
  #     SAME-indentation sibling (never "indentation decreased") finds no
  #     match anywhere in the rest of the file and falls back to "block
  #     extends to end of file" -- silently combining mssql-hammerdb's
  #     fields with the unrelated root-level secret's "password". Must fail
  #     cleanly instead (and never combine fields across the boundary). ---
  echo "--- Scenario 6: negative case, password missing + lower-indentation secret supplies one ---"
  cat >"$tmpdir/case6.yaml" <<'EOF'
clusterGroup:
  secrets:
  - name: mssql-hammerdb
    fields:
      - name: sa_password
        value: BrokenSaPass555
      - name: user
        value: hammerdb
- name: root-level-secret
  fields:
    - name: password
      value: ShouldNotLeakPass666
EOF
  reset_env
  if VALUES_SECRET="$tmpdir/case6.yaml" load_mssql_credentials; then
    echo "  FAIL Scenario 6: expected failure (missing password field) but load_mssql_credentials returned 0"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  elif [[ "${DR_VALIDATION_MSSQL_PASSWORD:-}" == "ShouldNotLeakPass666" ]]; then
    echo "  FAIL Scenario 6: leaked root-level-secret's password across the mssql-hammerdb block boundary"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  elif [[ -n "${DR_VALIDATION_MSSQL_SA_PASSWORD:-}" || -n "${DR_VALIDATION_MSSQL_PASSWORD:-}" ]]; then
    echo "  FAIL Scenario 6: expected no partial credentials set, but some were populated"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  else
    echo "  OK   Scenario 6: correctly failed without combining fields across the lower-indentation boundary"
  fi
  echo ""

  if [[ $TOTAL_FAIL -gt 0 ]]; then
    echo "=== RESULT: $TOTAL_FAIL scenario(s) failed ==="
    exit 1
  fi
  echo "=== RESULT: All scenarios passed ==="
  exit 0
}

main "$@"
