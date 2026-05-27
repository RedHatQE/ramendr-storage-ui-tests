#!/usr/bin/env bash
set -euo pipefail

# Investigate AWS spend attribution and untagged EC2 usage.
# This script focuses on the same signals that commonly cause shared-account bill spikes:
#   1) EC2 compute cost grouped by owner tag
#   2) EC2 compute cost without owner tag
#   3) Running instances missing owner tag (optionally filtered by launchedBy tag)

OWNER_TAG_KEY="${OWNER_TAG_KEY:-owner}"
LAUNCHED_BY_TAG_KEY="${LAUNCHED_BY_TAG_KEY:-launchedBy}"
LAUNCHED_BY_FILTER="${LAUNCHED_BY_FILTER:-}"
START_DATE="${START_DATE:-$(date -u +%Y-%m-01)}"

# Cost Explorer end date is exclusive.
if [[ -z "${END_DATE:-}" ]]; then
  if END_DATE="$(date -u -v+1d +%Y-%m-%d 2>/dev/null)"; then
    :
  else
    END_DATE="$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d"))
PY
)"
  fi
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_cmd aws
require_cmd python3

echo "=== AWS Cost/Tag Audit ==="
echo "Date range: ${START_DATE} -> ${END_DATE} (end exclusive)"
echo "Owner tag key: ${OWNER_TAG_KEY}"
if [[ -n "$LAUNCHED_BY_FILTER" ]]; then
  echo "Instance filter: ${LAUNCHED_BY_TAG_KEY}=${LAUNCHED_BY_FILTER}"
fi
echo ""

echo "## 1) EC2 compute cost grouped by owner tag"
_ce_out1=$(aws ce get-cost-and-usage \
  --time-period "Start=${START_DATE},End=${END_DATE}" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by "Type=TAG,Key=${OWNER_TAG_KEY}" \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Compute Cloud - Compute"]}}' \
  --output json)
echo "$_ce_out1" | python3 <(cat <<'PY'
import json
import sys

doc = json.load(sys.stdin)
results = doc.get("ResultsByTime", [])
if not results:
    print("No Cost Explorer data returned.")
    sys.exit(0)

groups = results[0].get("Groups", [])
if not groups:
    print("No grouped EC2 compute cost found.")
    sys.exit(0)

for g in groups:
    key = g.get("Keys", ["(no-key)"])[0]
    amount = g.get("Metrics", {}).get("UnblendedCost", {}).get("Amount", "0")
    unit = g.get("Metrics", {}).get("UnblendedCost", {}).get("Unit", "USD")
    print(f"{key}: {amount} {unit}")
PY
)

echo ""
echo "## 2) EC2 compute cost where owner tag is missing"
_ce_out2=$(aws ce get-cost-and-usage \
  --time-period "Start=${START_DATE},End=${END_DATE}" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter "$(cat <<EOF
{
  "And": [
    {"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Elastic Compute Cloud - Compute"]}},
    {"Tags": {"Key": "${OWNER_TAG_KEY}", "MatchOptions": ["ABSENT"]}}
  ]
}
EOF
)" \
  --output json)
echo "$_ce_out2" | python3 <(cat <<'PY'
import json
import sys

doc = json.load(sys.stdin)
results = doc.get("ResultsByTime", [])
if not results:
    print("No Cost Explorer data returned.")
    sys.exit(0)

total = results[0].get("Total", {}).get("UnblendedCost", {})
amount = total.get("Amount", "0")
unit = total.get("Unit", "USD")
print(f"untagged-owner EC2 compute: {amount} {unit}")
PY
)

echo ""
echo "## 3) Running instances missing owner tag"
regions="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)"

for region in $regions; do
  _ec2_out=$(aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --output json)
  echo "$_ec2_out" | python3 <(cat <<'PY'
import json
import sys

region = sys.argv[1]
owner_key = sys.argv[2]
launched_by_key = sys.argv[3]
launched_by_filter = sys.argv[4]
doc = json.load(sys.stdin)

matches = []
for reservation in doc.get("Reservations", []):
    for instance in reservation.get("Instances", []):
        tags = {t.get("Key"): t.get("Value", "") for t in instance.get("Tags", [])}
        if owner_key in tags and tags[owner_key]:
            continue
        if launched_by_filter and tags.get(launched_by_key) != launched_by_filter:
            continue
        matches.append(
            (
                instance.get("InstanceId", "-"),
                instance.get("State", {}).get("Name", "-"),
                instance.get("InstanceType", "-"),
                instance.get("Placement", {}).get("AvailabilityZone", "-"),
                tags.get(launched_by_key, "-"),
            )
        )

if not matches:
    sys.exit(0)

print(f"[{region}]")
for iid, state, itype, az, launched_by in matches:
    print(f"  {iid}  state={state} type={itype} az={az} {launched_by_key}={launched_by}")
PY
  ) "$region" "$OWNER_TAG_KEY" "$LAUNCHED_BY_TAG_KEY" "$LAUNCHED_BY_FILTER"
done

echo ""
echo "Audit complete."
