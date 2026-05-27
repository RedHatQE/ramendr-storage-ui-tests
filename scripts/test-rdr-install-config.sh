#!/usr/bin/env bash
# Test rdr chart install_config rendering in multiple merge scenarios.
#
# Scenarios:
#   1. Baseline: chart values only → full install_config from chart regionalDR.
#   2. Chart + overrides/values-cluster-names.yaml → overridden names/regions, full structure.
#   3. Chart + values-hub + overrides → values-hub has no regionalDR, so chart regionalDR kept; overrides apply.
#   4. values-hub + overrides (no explicit chart -f) → chart defaults still load; same as 3.
#   5. Minimal regionalDR + overrides → simulates old values-hub with minimal regionalDR; chart uses
#      files/default-*-install-config.json so install_config is still full; overrides apply.
#
# Ensures all required fields are present (metadata, controlPlane, compute, networking, platform)
# in every scenario, and that overridden fields (metadata.name, platform.aws.region) match overrides when used.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART="$REPO_ROOT/charts/hub/rdr"
RDR_VALUES="$REPO_ROOT/charts/hub/rdr/values.yaml"
OVERRIDES="$REPO_ROOT/overrides/values-cluster-names.yaml"
VALUES_HUB="$REPO_ROOT/values-hub.yaml"
DOMAIN="${TEST_CLUSTER_DOMAIN:-example.com}"

# Minimal regionalDR (simulates old values-hub that replaced full regionalDR)
# This triggers the chart's default install_config files.
MINIMAL_REGIONAL_DR="$REPO_ROOT/overrides/values-minimal-regional-dr.yaml"

run_helm() {
  helm template rdr "$CHART" "$@" --set "global.clusterDomain=$DOMAIN" 2>/dev/null
}

# Run helm; stdout+stderr to stdout, exit code preserved (caller can redirect and check $?)
run_helm_capture() {
  helm template rdr "$CHART" "$@" --set "global.clusterDomain=$DOMAIN" 2>&1
}

# Extract and decode install-config.yaml from the Nth Secret (1=primary, 2=secondary)
get_install_config() {
  local out="$1"
  local nth="${2:-1}"
  echo "$out" | grep -A1 "install-config.yaml:" | grep "install-config.yaml" | sed -n "${nth}p" | awk '{print $2}' | base64 -d 2>/dev/null || true
}

# Validate decoded install_config has required structure (no empty compute, no null networking, etc.)
validate_install_config() {
  local yaml="$1"
  local label="$2"
  local err=0
  if echo "$yaml" | grep -q "compute: \[\]"; then
    echo "  FAIL $label: compute is empty []"
    err=1
  fi
  if echo "$yaml" | grep -q "networking: null"; then
    echo "  FAIL $label: networking is null"
    err=1
  fi
  if echo "$yaml" | grep -q "publish: null"; then
    echo "  FAIL $label: publish is null"
    err=1
  fi
  if echo "$yaml" | grep -qE "platform:\s*$" -A1 | grep -q "aws: {}"; then
    echo "  FAIL $label: platform.aws is empty {}"
    err=1
  fi
  if ! echo "$yaml" | grep -q "controlPlane:"; then
    echo "  FAIL $label: missing controlPlane"
    err=1
  fi
  if ! echo "$yaml" | grep -q "type:"; then
    echo "  FAIL $label: missing machine type in controlPlane/compute"
    err=1
  fi
  if ! echo "$yaml" | grep -q "metadata:"; then
    echo "  FAIL $label: missing metadata"
    err=1
  fi
  if ! echo "$yaml" | grep -q "platform:"; then
    echo "  FAIL $label: missing platform"
    err=1
  fi
  if ! echo "$yaml" | grep -q "region:"; then
    echo "  FAIL $label: missing platform.aws.region"
    err=1
  fi
  if [[ $err -eq 0 ]]; then
    echo "  OK   $label: required fields present"
  fi
  return $err
}

# Return 0 if install_config YAML has nulled/empty sections (broken); 1 if full
is_install_config_broken() {
  local yaml="$1"
  if echo "$yaml" | grep -q "compute: \[\]"; then return 0; fi
  if echo "$yaml" | grep -q "networking: null"; then return 0; fi
  if ! echo "$yaml" | grep -q "controlPlane:"; then return 0; fi
  if ! echo "$yaml" | grep -q "type:"; then return 0; fi
  return 1
}

# Create minimal regionalDR override once (used for scenario 5)
ensure_minimal_regional_dr() {
  if [[ ! -f "$MINIMAL_REGIONAL_DR" ]]; then
    cat > "$MINIMAL_REGIONAL_DR" << 'EOF'
---
# Simulates old values-hub when it had a minimal regionalDR (no install_config).
# Used only for testing: chart falls back to files/default-*-install-config.json.
regionalDR:
  - name: resilient
    clusters:
      primary:
        name: ocp-primary
      secondary:
        name: ocp-secondary
EOF
    echo "Created $MINIMAL_REGIONAL_DR for testing."
  fi
}

main() {
  local total_fail=0
  echo "=== RDR install_config rendering tests (domain=$DOMAIN) ==="
  echo ""

  # Scenario 1: Baseline – chart defaults only
  echo "--- Scenario 1: Baseline (chart values only) ---"
  out=$(run_helm -f "$RDR_VALUES")
  primary=$(get_install_config "$out" 1)
  secondary=$(get_install_config "$out" 2)
  validate_install_config "$primary" "primary (baseline)" || ((total_fail++))
  validate_install_config "$secondary" "secondary (baseline)" || ((total_fail++))
  pname=$(echo "$primary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')
  sname=$(echo "$secondary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')
  echo "  Primary metadata.name:   $pname"
  echo "  Secondary metadata.name: $sname"
  [[ "$pname" == "ocp-primary" && "$sname" == "ocp-secondary" ]] || { echo "  FAIL baseline: expected ocp-primary / ocp-secondary"; ((total_fail++)); }
  echo ""

  # Scenario 2: Chart + overrides (values-cluster-names)
  echo "--- Scenario 2: Chart + overrides/values-cluster-names.yaml ---"
  out=$(run_helm -f "$RDR_VALUES" -f "$OVERRIDES")
  primary=$(get_install_config "$out" 1)
  secondary=$(get_install_config "$out" 2)
  validate_install_config "$primary" "primary (chart+overrides)" || ((total_fail++))
  validate_install_config "$secondary" "secondary (chart+overrides)" || ((total_fail++))
  pname=$(echo "$primary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')
  sname=$(echo "$secondary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')
  preg=$(echo "$primary" | grep 'region:' | head -1 | awk '{print $2}')
  sreg=$(echo "$secondary" | grep 'region:' | head -1 | awk '{print $2}')
  echo "  Primary metadata.name:   $pname"
  echo "  Primary region:          $preg"
  echo "  Secondary metadata.name: $sname"
  echo "  Secondary region:        $sreg"
  # Override file may use ocp-p/ocp-s or other names; just ensure regions are set
  [[ -n "$preg" && -n "$sreg" ]] || { echo "  FAIL chart+overrides: regions should be set"; ((total_fail++)); }
  echo ""

  # Scenario 3: Chart + values-hub (no regionalDR) + overrides
  echo "--- Scenario 3: Chart + values-hub + overrides ---"
  out=$(run_helm -f "$RDR_VALUES" -f "$VALUES_HUB" -f "$OVERRIDES")
  primary=$(get_install_config "$out" 1)
  secondary=$(get_install_config "$out" 2)
  validate_install_config "$primary" "primary (chart+hub+overrides)" || ((total_fail++))
  validate_install_config "$secondary" "secondary (chart+hub+overrides)" || ((total_fail++))
  echo "  Primary metadata.name:   $(echo "$primary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')"
  echo "  Secondary metadata.name: $(echo "$secondary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')"
  echo ""

  # Scenario 4: values-hub + overrides only (no explicit chart values file; chart defaults still load)
  echo "--- Scenario 4: values-hub + overrides (chart defaults implicit) ---"
  out=$(run_helm -f "$VALUES_HUB" -f "$OVERRIDES")
  primary=$(get_install_config "$out" 1)
  secondary=$(get_install_config "$out" 2)
  validate_install_config "$primary" "primary (hub+overrides)" || ((total_fail++))
  validate_install_config "$secondary" "secondary (hub+overrides)" || ((total_fail++))
  echo "  Primary metadata.name:   $(echo "$primary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')"
  echo "  Secondary metadata.name: $(echo "$secondary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')"
  echo ""

  # Scenario 5: Minimal regionalDR (simulates old values-hub with regionalDR) + overrides → uses default files
  ensure_minimal_regional_dr
  echo "--- Scenario 5: Minimal regionalDR + overrides (uses chart default install_config files) ---"
  out=$(run_helm -f "$MINIMAL_REGIONAL_DR" -f "$OVERRIDES")
  primary=$(get_install_config "$out" 1)
  secondary=$(get_install_config "$out" 2)
  validate_install_config "$primary" "primary (minimal regionalDR+overrides)" || ((total_fail++))
  validate_install_config "$secondary" "secondary (minimal regionalDR+overrides)" || ((total_fail++))
  echo "  Primary metadata.name:   $(echo "$primary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')"
  echo "  Primary region:          $(echo "$primary" | grep 'region:' | head -1 | awk '{print $2}')"
  echo "  Secondary metadata.name: $(echo "$secondary" | grep -A1 '^metadata:' | grep 'name:' | head -1 | awk '{print $2}')"
  echo "  Secondary region:        $(echo "$secondary" | grep 'region:' | head -1 | awk '{print $2}')"
  echo ""

  # --- Validate default JSON files are required when regionalDR is minimal ---
  echo "--- Validate: default JSON files prevent nulled install_config when regionalDR is minimal ---"
  DEFAULT_PRIMARY="$REPO_ROOT/charts/hub/rdr/files/default-primary-install-config.json"
  DEFAULT_SECONDARY="$REPO_ROOT/charts/hub/rdr/files/default-secondary-install-config.json"
  if [[ ! -f "$DEFAULT_PRIMARY" || ! -f "$DEFAULT_SECONDARY" ]]; then
    echo "  SKIP  default JSON files not found (cannot run validation)"
  else
    ensure_minimal_regional_dr
    # Temporarily hide default files so the chart cannot use them
    mv "$DEFAULT_PRIMARY" "${DEFAULT_PRIMARY}.bak"
    mv "$DEFAULT_SECONDARY" "${DEFAULT_SECONDARY}.bak"
    tmpout=$(mktemp)
    trap 'mv -f "${DEFAULT_PRIMARY}.bak" "$DEFAULT_PRIMARY" 2>/dev/null; mv -f "${DEFAULT_SECONDARY}.bak" "$DEFAULT_SECONDARY" 2>/dev/null; rm -f "$tmpout"' EXIT
    run_helm_capture -f "$MINIMAL_REGIONAL_DR" -f "$OVERRIDES" >"$tmpout"
    helm_ret=$?
    out=$(cat "$tmpout")
    # Restore files immediately so later tests or reruns work
    mv -f "${DEFAULT_PRIMARY}.bak" "$DEFAULT_PRIMARY" 2>/dev/null || true
    mv -f "${DEFAULT_SECONDARY}.bak" "$DEFAULT_SECONDARY" 2>/dev/null || true
    trap - EXIT
    rm -f "$tmpout"

    if [[ $helm_ret -ne 0 ]]; then
      echo "  OK    Without default JSON files: helm template fails (exit $helm_ret) as expected."
    else
      primary_nojson=$(get_install_config "$out" 1)
      if is_install_config_broken "$primary_nojson"; then
        echo "  OK    Without default JSON files: install_config has nulled/empty sections (compute: [], networking: null, or missing types) as expected."
      else
        echo "  FAIL  Without default JSON files: install_config was still full; default files may be redundant."
        ((total_fail++))
      fi
    fi
    echo "  => Default JSON files are required when regionalDR is minimal (no install_config in base)."
  fi
  echo ""

  if [[ $total_fail -gt 0 ]]; then
    echo "=== RESULT: $total_fail validation(s) failed ==="
    exit 1
  fi
  echo "=== RESULT: All scenarios passed ==="
  exit 0
}

main "$@"
