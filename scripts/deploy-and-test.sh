#!/usr/bin/env bash
# JSL DICOM De-Identification — Deploy & Test
# Run from AWS CloudShell:
#   curl -sSL https://raw.githubusercontent.com/shubhanshudixit/jsl-healthomics-deid/main/scripts/deploy-and-test.sh | bash
set -euo pipefail

REPO_URL="https://github.com/shubhanshudixit/jsl-healthomics-deid"
RAW_BASE="https://raw.githubusercontent.com/shubhanshudixit/jsl-healthomics-deid/main"
STACK_NAME="jsl-dicom-deid"
WORK_DIR="/tmp/jsl-deid-$$"
STATE_FILE="$HOME/jsl-deploy-state.json"

# ── colours ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
warn()  { echo -e "${YELLOW}⚠  $*${RESET}"; }
ok()    { echo -e "${GREEN}✅ $*${RESET}"; }
err()   { echo -e "${RED}❌ $*${RESET}"; exit 1; }
banner(){ echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── detect AWS environment ─────────────────────────────────────────────
banner "Detecting AWS environment"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
  || err "AWS credentials not configured. Run from AWS CloudShell or configure 'aws configure'."
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
echo "  Account : $ACCOUNT_ID"
echo "  Region  : $REGION"

# ── warn about resources already running ──────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  banner "Previous deployment detected"
  cat "$STATE_FILE"
  echo ""
  RUNNING_RUNS=$(aws omics list-runs --region "$REGION" \
    --query "items[?status=='RUNNING'].id" --output text 2>/dev/null || true)
  if [[ -n "$RUNNING_RUNS" ]]; then
    warn "HealthOmics runs still RUNNING (accruing cost): $RUNNING_RUNS"
    warn "Run the status script to investigate before proceeding."
    echo -e "  ${BOLD}curl -sSL ${RAW_BASE}/scripts/status.sh | bash${RESET}"
    read -p "Continue anyway? [y/N] " -r CONT
    [[ "${CONT:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi
fi

# ── inputs ─────────────────────────────────────────────────────────────
banner "Configuration"
read -p "  Marketplace container image URI: " CONTAINER_IMAGE
[[ -z "$CONTAINER_IMAGE" ]] && err "Container image URI is required"
read -p "  JSL secret name [jsl-dicom-deid-license]: " SECRET_NAME
SECRET_NAME="${SECRET_NAME:-jsl-dicom-deid-license}"
echo ""
echo "  Stack name     : $STACK_NAME"
echo "  Container image: $CONTAINER_IMAGE"
echo "  Secret name    : $SECRET_NAME"
echo "  Instance type  : omics.m.xlarge (4 vCPU / 16 GB — cheapest available)"

# ── clone repo ─────────────────────────────────────────────────────────
banner "Cloning repo"
git clone --quiet --depth 1 "$REPO_URL" "$WORK_DIR"
trap "rm -rf '$WORK_DIR' /tmp/workflow-validate.zip /tmp/workflow-prod.zip /tmp/validate-params.json" EXIT

# ── deploy CloudFormation ──────────────────────────────────────────────
banner "Deploying CloudFormation stack: $STACK_NAME"
echo "  This creates VPC, NAT Gateway, IAM role, Secrets Manager secret."
echo "  ⚠  NAT Gateway will accrue ~\$0.045/hr until you run cleanup.sh"
echo ""
aws cloudformation deploy \
  --template-file "$WORK_DIR/infra/setup.yml" \
  --stack-name   "$STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides JslSecretName="$SECRET_NAME" \
  --region "$REGION"
ok "Stack deployed"

# ── read stack outputs ─────────────────────────────────────────────────
_out() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}
BUCKET=$(_out S3BucketName)
SECRET_ARN=$(_out JslSecretArn)
RUN_ROLE_ARN=$(_out OmicsRunRoleArn)
VPC_CONFIG=$(_out OmicsVpcConfigName)

echo "  Bucket      : $BUCKET"
echo "  Secret ARN  : $SECRET_ARN"
echo "  Run Role    : $RUN_ROLE_ARN"
echo "  VPC Config  : $VPC_CONFIG"

# ── register HealthOmics workflows ─────────────────────────────────────
banner "Registering HealthOmics workflows"

# Zip from within the workflow dir so relative import paths are preserved
pushd "$WORK_DIR/workflow" > /dev/null

zip -q /tmp/workflow-validate.zip validate.wdl tasks/validate.wdl
VALIDATE_WF_ID=$(aws omics create-workflow \
  --name   "jsl-dicom-deid-validate" \
  --engine WDL \
  --main   validate.wdl \
  --definition-zip fileb:///tmp/workflow-validate.zip \
  --region "$REGION" \
  --query  id --output text)
ok "Validate workflow: $VALIDATE_WF_ID"

zip -q /tmp/workflow-prod.zip main.wdl tasks/deidentify.wdl
PROD_WF_ID=$(aws omics create-workflow \
  --name   "jsl-dicom-deid" \
  --engine WDL \
  --main   main.wdl \
  --definition-zip fileb:///tmp/workflow-prod.zip \
  --region "$REGION" \
  --query  id --output text)
ok "Production workflow: $PROD_WF_ID"

popd > /dev/null

# Wait for both workflows to become ACTIVE before starting a run
banner "Waiting for workflows to become ACTIVE"
for WF_ID in "$VALIDATE_WF_ID" "$PROD_WF_ID"; do
  WF_STATUS="CREATING"
  for i in $(seq 1 24); do
    WF_STATUS=$(aws omics get-workflow --id "$WF_ID" --region "$REGION" --query status --output text)
    [[ "$WF_STATUS" == "ACTIVE" ]] && break
    echo "  Workflow $WF_ID: $WF_STATUS — waiting 15s..."
    sleep 15
  done
  [[ "$WF_STATUS" == "ACTIVE" ]] || err "Workflow $WF_ID never became ACTIVE (last status: $WF_STATUS)"
  ok "Workflow $WF_ID is ACTIVE"
done

# ── run validation workflow ────────────────────────────────────────────
banner "Starting validation run"
echo "  Hardware : omics.m.xlarge (4 vCPU, 16 GB) — cheapest available"
echo "  Est. cost: ~\$2–5"
echo "  Est. time: ~10 minutes"
echo ""

cat > /tmp/validate-params.json <<EOF
{
  "output_s3_uri":   "s3://${BUCKET}/validation-output/",
  "container_image": "${CONTAINER_IMAGE}",
  "jsl_secret_arn":  "${SECRET_ARN}",
  "instance_type":   "omics.m.xlarge"
}
EOF

RUN_ID=$(aws omics start-run \
  --workflow-id        "$VALIDATE_WF_ID" \
  --role-arn           "$RUN_ROLE_ARN" \
  --output-uri         "s3://$BUCKET/omics-output/" \
  --networking-mode    VPC \
  --configuration-name "$VPC_CONFIG" \
  --parameters         file:///tmp/validate-params.json \
  --region             "$REGION" \
  --query id --output text)
ok "Run started: $RUN_ID"

# ── save state to disk ─────────────────────────────────────────────────
cat > "$STATE_FILE" <<EOF
{
  "stack_name":           "$STACK_NAME",
  "region":               "$REGION",
  "account_id":           "$ACCOUNT_ID",
  "bucket":               "$BUCKET",
  "validate_workflow_id": "$VALIDATE_WF_ID",
  "prod_workflow_id":     "$PROD_WF_ID",
  "last_run_id":          "$RUN_ID",
  "deployed_at":          "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo "  State saved to $STATE_FILE"

# ── poll for validation result ─────────────────────────────────────────
banner "Polling validation run"
FINAL_STATUS="UNKNOWN"
for i in $(seq 1 40); do
  STATUS=$(aws omics get-run --id "$RUN_ID" --region "$REGION" --query status --output text)
  echo "  [$(date +%H:%M:%S)] Run $RUN_ID → $STATUS"
  case "$STATUS" in
    COMPLETED) FINAL_STATUS="COMPLETED"; break ;;
    FAILED|CANCELLED) FINAL_STATUS="$STATUS"; break ;;
  esac
  sleep 30
done

echo ""
if [[ "$FINAL_STATUS" == "COMPLETED" ]]; then
  ok "VALIDATION PASSED — setup is ready for production use"
  echo "  De-identified test output: s3://$BUCKET/validation-output/"
else
  warn "VALIDATION $FINAL_STATUS"
  echo "  Fetch logs:"
  echo "    aws logs tail /aws/omics/runs --since 1h --region $REGION"
fi

# ── resource cost warning (always shown) ──────────────────────────────
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ⚠  RESOURCES LEFT RUNNING — ONGOING COSTS"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Resource      Cost            Detail"
echo -e "  NAT Gateway   \$0.045/hr       (~\$1.08/day, ~\$32/month)"
echo -e "  S3 bucket     \$0.023/GB-mo    (negligible for test data)"
echo -e "  Secrets Mgr   \$0.40/secret-mo (negligible)"
echo -e ""
echo -e "  Stack : $STACK_NAME  |  Region : $REGION"
echo -e "  Run   : $RUN_ID  |  Status : $FINAL_STATUS"
echo -e ""
echo -e "  Check status : curl -sSL ${RAW_BASE}/scripts/status.sh | bash"
echo -e "  Tear down    : curl -sSL ${RAW_BASE}/scripts/cleanup.sh | bash"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
