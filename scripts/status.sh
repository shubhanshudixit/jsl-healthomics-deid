#!/usr/bin/env bash
# JSL HealthOmics — Resource Status Check
# Run from AWS CloudShell:
#   curl -sSL https://raw.githubusercontent.com/shubhanshudixit/jsl-healthomics-deid/main/scripts/status.sh | bash
set -euo pipefail

STATE_FILE="$HOME/jsl-deploy-state.json"
YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

warn() { echo -e "${YELLOW}⚠  $*${RESET}"; }
ok()   { echo -e "${GREEN}✅ $*${RESET}"; }
err()  { echo -e "${RED}❌ $*${RESET}"; }

echo -e "${BOLD}JSL HealthOmics — Resource Status${RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── read saved state ───────────────────────────────────────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  warn "No state file found at $STATE_FILE — has deploy-and-test.sh been run?"
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
  STACK_NAME="jsl-dicom-deid"
else
  REGION=$(python3 -c "import json,sys; print(json.load(sys.stdin)['region'])" < "$STATE_FILE")
  STACK_NAME=$(python3 -c "import json,sys; print(json.load(sys.stdin)['stack_name'])" < "$STATE_FILE")
  DEPLOYED_AT=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('deployed_at','unknown'))" < "$STATE_FILE")
  LAST_RUN=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('last_run_id','none'))" < "$STATE_FILE")
  echo "  Deployed at  : $DEPLOYED_AT"
  echo "  Last run     : $LAST_RUN"
  echo ""
fi

# ── CloudFormation stack ───────────────────────────────────────────────
echo -e "${BOLD}CloudFormation Stack${RESET}"
CF_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")
echo "  $STACK_NAME : $CF_STATUS"
if [[ "$CF_STATUS" == "CREATE_COMPLETE" || "$CF_STATUS" == "UPDATE_COMPLETE" ]]; then
  ok "Stack healthy"
  warn "NAT Gateway is running — ~\$0.045/hr ongoing cost"
elif [[ "$CF_STATUS" == "NOT_FOUND" ]]; then
  ok "Stack not deployed (no ongoing cost)"
else
  warn "Stack in unexpected state: $CF_STATUS"
fi
echo ""

# ── HealthOmics runs ───────────────────────────────────────────────────
echo -e "${BOLD}HealthOmics Runs (last 10)${RESET}"
RUNS=$(aws omics list-runs --region "$REGION" \
  --query "items[0:10].{id:id,status:status,name:name,startTime:startTime}" \
  --output table 2>/dev/null || echo "  (none found)")
echo "$RUNS"
echo ""

RUNNING=$(aws omics list-runs --region "$REGION" \
  --query "items[?status=='RUNNING'].id" --output text 2>/dev/null || true)
if [[ -n "$RUNNING" ]]; then
  warn "RUNNING runs (accruing cost): $RUNNING"
  warn "Cancel them with: aws omics cancel-run --id RUN_ID --region $REGION"
else
  ok "No runs currently RUNNING"
fi
echo ""

# ── HealthOmics workflows ──────────────────────────────────────────────
echo -e "${BOLD}Registered Workflows${RESET}"
aws omics list-workflows --region "$REGION" \
  --query "items[].{id:id,name:name,status:status}" \
  --output table 2>/dev/null || echo "  (none found)"
echo ""

# ── cost summary ──────────────────────────────────────────────────────
echo -e "${BOLD}Estimated Ongoing Cost${RESET}"
if [[ "$CF_STATUS" == "CREATE_COMPLETE" || "$CF_STATUS" == "UPDATE_COMPLETE" ]]; then
  echo "  NAT Gateway  : ~\$0.045/hr  (~\$1.08/day)"
  echo "  S3 + Secrets : ~\$0.50/mo (negligible)"
  warn "Run cleanup.sh to stop all charges if you are done testing"
else
  ok "No ongoing charges from this deployment"
fi
echo ""
echo -e "  Tear down: curl -sSL https://raw.githubusercontent.com/shubhanshudixit/jsl-healthomics-deid/main/scripts/cleanup.sh | bash"
