#!/usr/bin/env bash
# JSL HealthOmics — Tear Down All Resources
# Run from AWS CloudShell:
#   curl -sSL https://raw.githubusercontent.com/shubhanshudixit/jsl-healthomics-deid/main/scripts/cleanup.sh | bash
#
# What this deletes:
#   - CloudFormation stack (VPC, NAT Gateway, IAM role, Secrets Manager secret config)
#   - Registered HealthOmics workflows
#   - Cancels any in-progress runs
#
# What this does NOT delete (data you own):
#   - S3 bucket and its contents (DeletionPolicy: Retain)
#   - Secrets Manager secret value (so you don't lose your license)
set -euo pipefail

STATE_FILE="$HOME/jsl-deploy-state.json"
YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
warn() { echo -e "${YELLOW}⚠  $*${RESET}"; }
ok()   { echo -e "${GREEN}✅ $*${RESET}"; }

echo -e "${BOLD}JSL HealthOmics — Cleanup${RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "This will delete the CloudFormation stack and HealthOmics workflows."
warn "Your S3 bucket and its data will NOT be deleted."
echo ""
read -p "Proceed? [y/N] " -r CONFIRM
[[ "${CONFIRM:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# ── read state ─────────────────────────────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  REGION=$(python3 -c "import json,sys; print(json.load(sys.stdin)['region'])" < "$STATE_FILE")
  STACK_NAME=$(python3 -c "import json,sys; print(json.load(sys.stdin)['stack_name'])" < "$STATE_FILE")
  VALIDATE_WF_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('validate_workflow_id',''))" < "$STATE_FILE")
  PROD_WF_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('prod_workflow_id',''))" < "$STATE_FILE")
else
  warn "No state file found — using defaults"
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
  STACK_NAME="jsl-dicom-deid"
  VALIDATE_WF_ID=""
  PROD_WF_ID=""
fi

# ── cancel running HealthOmics runs ────────────────────────────────────
echo "Checking for running HealthOmics runs..."
RUNNING=$(aws omics list-runs --region "$REGION" \
  --query "items[?status=='RUNNING'].id" --output text 2>/dev/null || true)
if [[ -n "$RUNNING" ]]; then
  for RUN_ID in $RUNNING; do
    echo "  Cancelling run $RUN_ID..."
    aws omics cancel-run --id "$RUN_ID" --region "$REGION" 2>/dev/null || true
    ok "Cancelled $RUN_ID"
  done
else
  ok "No running runs"
fi

# ── delete HealthOmics workflows ───────────────────────────────────────
echo ""
echo "Deleting HealthOmics workflows..."
for WF_ID in $VALIDATE_WF_ID $PROD_WF_ID; do
  [[ -z "$WF_ID" ]] && continue
  aws omics delete-workflow --id "$WF_ID" --region "$REGION" 2>/dev/null \
    && ok "Deleted workflow $WF_ID" \
    || warn "Could not delete workflow $WF_ID (may already be deleted)"
done

# ── delete CloudFormation stack ────────────────────────────────────────
echo ""
echo "Deleting CloudFormation stack: $STACK_NAME..."
echo "  (NAT Gateway, VPC, IAM role, and Secrets Manager config will be removed)"
echo "  (S3 bucket is retained — your data is safe)"
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

echo "  Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION" \
  && ok "Stack deleted — all ongoing charges stopped" \
  || warn "Stack deletion may still be in progress — check the CloudFormation console"

# ── clear state file ───────────────────────────────────────────────────
rm -f "$STATE_FILE"
ok "State file cleared"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Cleanup complete. No ongoing charges."
echo -e "  Your DICOM data in S3 has been kept."
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
