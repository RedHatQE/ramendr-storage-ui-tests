#!/usr/bin/env bash
# Stop HammerDB autopilot + audit writers on all edge VMs (in-cluster SSH Job).
# Linux units are also disabled so a VM reboot does not resume OLTP.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/control-hammerdb-load-incluster.sh" stop
