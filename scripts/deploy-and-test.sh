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

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
warn()  { echo -e "${YELLOW}⚠  $*${RESET}"; }
ok()    { echo -e "${GREEN}✅ $*${RESET}"; }
err()   { echo -e "${RED}❌ $*${RESET}"; exit 1; }
banner(){ echo -e "\n${BOLD}── $* ──${RESET}"; }

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║     JSL DICOM De-Identification — AWS HealthOmics Setup     ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── prereq 1: AWS credentials (automatic) ─────────────────────────────
banner "Step 1/5 — Checking AWS credentials"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "No AWS credentials found. Run this from AWS CloudShell."
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ok "Account $ACCOUNT_ID · Region $REGION"

# ── prereq 2: JSL license secret (customer created this beforehand) ────
banner "Step 2/5 — JSL license secret"
echo "  You need a Secrets Manager secret containing your JSL license."
echo "  If you haven't created it yet, open a new browser tab and do this first:"
echo ""
echo "    AWS Console → Secrets Manager → Store a new secret"
echo "    → Other type of secret → paste your JSL license JSON → save"
echo "    → copy the secret ARN from the detail page"
echo ""
read -p "  Secret ARN: " JSL_SECRET_ARN
[[ -z "$JSL_SECRET_ARN" ]] && err "Secret ARN required. Create the secret in Secrets Manager and re-run."

echo "  Validating..."
SECRET_VALUE=$(aws secretsmanager get-secret-value \
  --secret-id "$JSL_SECRET_ARN" --region "$REGION" \
  --query SecretString --output text 2>/dev/null) \
  || err "Cannot read secret. Check the ARN and your IAM permissions."

MISSING=""
for FIELD in SPARK_NLP_LICENSE SPARK_OCR_LICENSE SECRET SPARK_OCR_SECRET; do
  python3 -c "import sys,json; d=json.load(sys.stdin); assert '$FIELD' in d and len(d['$FIELD'])>10" \
    <<< "$SECRET_VALUE" 2>/dev/null || MISSING="$MISSING $FIELD"
done
[[ -z "$MISSING" ]] || err "Secret is missing required fields:$MISSING"
ok "License secret valid"

# ── warn if resources already running from a previous deploy ───────────
if [[ -f "$STATE_FILE" ]]; then
  warn "Previous deployment state found — checking for running resources..."
  RUNNING=$(aws omics list-runs --region "$REGION" \
    --query "items[?status=='RUNNING'].id" --output text 2>/dev/null || true)
  [[ -n "$RUNNING" ]] && warn "HealthOmics runs still RUNNING (costing money): $RUNNING"
  read -p "  Continue anyway? [y/N] " -r CONT
  [[ "${CONT:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── confirm before spending money ─────────────────────────────────────
echo ""
echo -e "${BOLD}  What will be created:${RESET}"
echo "  • VPC + NAT Gateway + private/public subnets"
echo "  • Secrets Manager VPC endpoint (private access to your secret)"
echo "  • S3 bucket: jsl-dicom-deid-${ACCOUNT_ID}-${REGION}"
echo "  • IAM run role for HealthOmics"
echo "  • HealthOmics VPC configuration"
echo "  • Two HealthOmics workflows (validate + production)"
echo ""
echo "  ⚠  NAT Gateway accrues ~\$0.045/hr until you run cleanup.sh"
echo ""
read -p "  Proceed? [y/N] " -r PROCEED
[[ "${PROCEED:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── clone repo ─────────────────────────────────────────────────────────
banner "Step 3/5 — Deploying infrastructure"
git clone --quiet --depth 1 "$REPO_URL" "$WORK_DIR"
trap "rm -rf '$WORK_DIR' /tmp/workflow-validate.zip /tmp/workflow-prod.zip /tmp/validate-params.json" EXIT

aws cloudformation deploy \
  --template-file "$WORK_DIR/infra/setup.yml" \
  --stack-name    "$STACK_NAME" \
  --capabilities  CAPABILITY_NAMED_IAM \
  --parameter-overrides JslSecretArn="$JSL_SECRET_ARN" \
  --region "$REGION"
ok "Stack deployed"

_out() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}
BUCKET=$(_out S3BucketName)
RUN_ROLE_ARN=$(_out OmicsRunRoleArn)
VPC_CONFIG=$(_out OmicsVpcConfigName)
echo "  S3 bucket  : $BUCKET"
echo "  Run role   : $RUN_ROLE_ARN"
echo "  VPC config : $VPC_CONFIG"

# ── register workflows ─────────────────────────────────────────────────
banner "Step 4/5 — Registering HealthOmics workflows"
pushd "$WORK_DIR/workflow" > /dev/null

zip -q /tmp/workflow-validate.zip validate.wdl tasks/validate.wdl
VALIDATE_WF_ID=$(aws omics create-workflow \
  --name "jsl-dicom-deid-validate" --engine WDL --main validate.wdl \
  --definition-zip fileb:///tmp/workflow-validate.zip \
  --region "$REGION" --query id --output text)
ok "Validate workflow: $VALIDATE_WF_ID"

zip -q /tmp/workflow-prod.zip main.wdl tasks/deidentify.wdl
PROD_WF_ID=$(aws omics create-workflow \
  --name "jsl-dicom-deid" --engine WDL --main main.wdl \
  --definition-zip fileb:///tmp/workflow-prod.zip \
  --region "$REGION" --query id --output text)
ok "Production workflow: $PROD_WF_ID"

popd > /dev/null

for WF_ID in "$VALIDATE_WF_ID" "$PROD_WF_ID"; do
  WF_STATUS="CREATING"
  for i in $(seq 1 24); do
    WF_STATUS=$(aws omics get-workflow --id "$WF_ID" --region "$REGION" --query status --output text)
    [[ "$WF_STATUS" == "ACTIVE" ]] && break
    echo "  Workflow $WF_ID: $WF_STATUS — waiting 15s..."
    sleep 15
  done
  [[ "$WF_STATUS" == "ACTIVE" ]] || err "Workflow $WF_ID never became ACTIVE (status: $WF_STATUS)"
  ok "Workflow $WF_ID is ACTIVE"
done

# ── validation run ─────────────────────────────────────────────────────
banner "Step 5/5 — Validation run"
echo "  This runs the pipeline on a bundled test DICOM to confirm everything works."
echo "  Hardware: omics.m.xlarge (4 vCPU / 16 GB) — cheapest available"
echo "  Est. time: ~10 minutes · Est. cost: ~\$2–5"
echo ""
echo "  You need your AWS Marketplace container image URI to start the run."
echo "  It looks like: 709825985650.dkr.ecr.us-east-1.amazonaws.com/john-snow-labs/jsl-dicom-deid:latest"
echo ""
read -p "  Container image URI: " CONTAINER_IMAGE
[[ -z "$CONTAINER_IMAGE" ]] && err "Container image URI required. Subscribe to the product on AWS Marketplace."

if ! echo "$CONTAINER_IMAGE" | grep -qE '^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/.+'; then
  warn "URI doesn't look like an ECR address — double-check it."
  read -p "  Continue anyway? [y/N] " -r CONT
  [[ "${CONT:-N}" =~ ^[Yy]$ ]] || err "Aborted."
fi

cat > /tmp/validate-params.json <<EOF
{
  "output_s3_uri":   "s3://${BUCKET}/validation-output/",
  "container_image": "${CONTAINER_IMAGE}",
  "jsl_secret_arn":  "${JSL_SECRET_ARN}",
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

# ── save state ─────────────────────────────────────────────────────────
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

# ── poll ───────────────────────────────────────────────────────────────
echo "  Polling every 30s..."
FINAL_STATUS="UNKNOWN"
for i in $(seq 1 40); do
  STATUS=$(aws omics get-run --id "$RUN_ID" --region "$REGION" --query status --output text)
  echo "  [$(date +%H:%M:%S)] $STATUS"
  case "$STATUS" in
    COMPLETED) FINAL_STATUS="COMPLETED"; break ;;
    FAILED|CANCELLED) FINAL_STATUS="$STATUS"; break ;;
  esac
  sleep 30
done

echo ""
if [[ "$FINAL_STATUS" == "COMPLETED" ]]; then
  ok "VALIDATION PASSED — ready for production use"
  echo "  Output: s3://$BUCKET/validation-output/"
else
  warn "VALIDATION $FINAL_STATUS"
  echo "  Logs: aws logs tail /aws/omics/runs --since 1h --region $REGION"
fi

# ── cost warning (always shown) ────────────────────────────────────────
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ⚠  RESOURCES STILL RUNNING"
echo -e "  NAT Gateway ~\$0.045/hr (~\$1.08/day) until you run cleanup"
echo -e ""
echo -e "  Status  : curl -sSL ${RAW_BASE}/scripts/status.sh | bash"
echo -e "  Cleanup : curl -sSL ${RAW_BASE}/scripts/cleanup.sh | bash"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
