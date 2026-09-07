#!/usr/bin/env bash
# Start HammerDB autopilot + audit writers on all edge VMs (in-cluster SSH Job).
# Linux units are enabled (WantedBy) and Windows tasks get an AtStartup trigger so
# both writers resume together after a DR failover reboot; stop undoes that.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/control-hammerdb-load-incluster.sh" start
