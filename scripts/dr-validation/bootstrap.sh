#!/usr/bin/env bash
set -euo pipefail

# Wait for edge VMs + routes, install timestamp writers, verify they are recording.
# Invoked automatically from scripts/redeploy.sh unless SKIP_DR_VALIDATION=1.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# After redeploy: wait for gitops edge VMs on the DR primary, then install writers.
wait_for_primary_vms_healthy

if [[ "${DR_VALIDATION_INCLUSTER_INSTALL:-1}" == "1" ]]; then
  # Spokes use NodePort on private workers; install from a pod on the primary spoke.
  wait_for_edge_vms
  "$SCRIPT_DIR/install-writer-incluster.sh"
else
  wait_for_edge_vms
  "$SCRIPT_DIR/install-writer.sh"
  sleep 5
  verify_writers_recording
fi
