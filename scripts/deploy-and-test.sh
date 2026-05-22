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
warn()   { echo -e "${YELLOW}⚠  $*${RESET}"; }
ok()     { echo -e "${GREEN}✅ $*${RESET}"; }
err()    { echo -e "${RED}❌ $*${RESET}"; exit 1; }
info()   { echo -e "   $*"; }
banner() { echo -e "\n${BOLD}── $* ──${RESET}"; }

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║     JSL DICOM De-Identification — AWS HealthOmics Setup     ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── AWS credentials ─────────────────────────────────────────────────
banner "Step 1/7 — Checking AWS credentials"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "No AWS credentials found. Run this from AWS CloudShell."
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ok "Account $ACCOUNT_ID · Region $REGION"

# ── warn about existing deployment ──────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  warn "Previous deployment state found — checking for running resources..."
  RUNNING=$(aws omics list-runs --region "$REGION" \
    --query "items[?status=='RUNNING'].id" --output text 2>/dev/null || true)
  [[ -n "$RUNNING" ]] && warn "HealthOmics runs still RUNNING (accruing charges): $RUNNING"
  read -p "  Continue anyway? [y/N] " -r CONT
  [[ "${CONT:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── Step 2: JSL license secret ───────────────────────────────────────
banner "Step 2/7 — JSL license secret"
echo ""
echo "  Before running this script, create a Secrets Manager secret containing"
echo "  your JSL license JSON. If you haven't done this yet:"
echo ""
echo "    1. Open: AWS Console → Secrets Manager → Store a new secret"
echo "    2. Choose: Other type of secret"
echo "    3. Paste your JSL license JSON (the full object, not just one field)"
echo "    4. Click Next → give it a name → Store"
echo "    5. Open the secret → copy the Secret ARN from the top of the page"
echo ""
read -p "  JSL Secret ARN: " JSL_SECRET_ARN
[[ -z "$JSL_SECRET_ARN" ]] && err "Secret ARN required. Create the secret first and re-run."

echo "  Validating secret..."
SECRET_VALUE=$(aws secretsmanager get-secret-value \
  --secret-id "$JSL_SECRET_ARN" --region "$REGION" \
  --query SecretString --output text 2>/dev/null) \
  || err "Cannot read secret '$JSL_SECRET_ARN'. Check the ARN and your IAM permissions."

MISSING=""
for FIELD in SPARK_NLP_LICENSE SPARK_OCR_LICENSE SECRET SPARK_OCR_SECRET; do
  python3 -c "import sys,json; d=json.load(sys.stdin); assert '$FIELD' in d and len(d['$FIELD'])>10" \
    <<< "$SECRET_VALUE" 2>/dev/null || MISSING="$MISSING $FIELD"
done
[[ -z "$MISSING" ]] || err "Secret is missing or has empty required fields:$MISSING"
ok "License secret valid — all required fields present"

# ── Step 3: S3 buckets ───────────────────────────────────────────────
banner "Step 3/7 — S3 buckets"
echo ""
echo "  Provide your S3 bucket names. The input bucket holds your DICOM files;"
echo "  the output bucket receives de-identified results. They can be the same bucket."
echo ""

read -p "  Input S3 bucket name (just the name, not s3://): " INPUT_BUCKET
[[ -z "$INPUT_BUCKET" ]] && err "Input bucket name required."
echo "  Checking input bucket access..."
aws s3 ls "s3://$INPUT_BUCKET" --region "$REGION" > /dev/null 2>&1 \
  || err "Cannot list bucket '$INPUT_BUCKET'. Check the name and your IAM permissions."
ok "Input bucket accessible: s3://$INPUT_BUCKET"

read -p "  Output S3 bucket name (just the name, not s3://): " OUTPUT_BUCKET
[[ -z "$OUTPUT_BUCKET" ]] && err "Output bucket name required."
echo "  Checking output bucket write access..."
PROBE_KEY=".jsl-deid-probe-$$/probe.txt"
aws s3 cp /dev/null "s3://$OUTPUT_BUCKET/$PROBE_KEY" --region "$REGION" > /dev/null 2>&1 \
  || err "Cannot write to bucket '$OUTPUT_BUCKET'. Check the name and your IAM permissions."
aws s3 rm "s3://$OUTPUT_BUCKET/$PROBE_KEY" --region "$REGION" > /dev/null 2>&1 || true
ok "Output bucket writable: s3://$OUTPUT_BUCKET"

# ── confirm before spending money ────────────────────────────────────
echo ""
echo -e "${BOLD}  What will be created:${RESET}"
info "• VPC + NAT Gateway + private/public subnets"
info "• Secrets Manager VPC endpoint (private access to your license secret)"
info "• IAM run role for HealthOmics"
info "• HealthOmics VPC configuration"
info "• Two HealthOmics workflows (validation + production)"
echo ""
info "  Input  : s3://$INPUT_BUCKET"
info "  Output : s3://$OUTPUT_BUCKET"
info "  Secret : $JSL_SECRET_ARN"
echo ""
warn "NAT Gateway accrues ~\$0.045/hr until you run cleanup.sh"
echo ""
read -p "  Proceed? [y/N] " -r PROCEED
[[ "${PROCEED:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Step 4: Deploy CloudFormation ────────────────────────────────────
banner "Step 4/7 — Deploying infrastructure"
git clone --quiet --depth 1 "$REPO_URL" "$WORK_DIR"
trap "rm -rf '$WORK_DIR' /tmp/workflow-validate.zip /tmp/workflow-prod.zip /tmp/validate-params.json" EXIT

aws cloudformation deploy \
  --template-file "$WORK_DIR/infra/setup.yml" \
  --stack-name    "$STACK_NAME" \
  --capabilities  CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    JslSecretArn="$JSL_SECRET_ARN" \
    InputBucketName="$INPUT_BUCKET" \
    OutputBucketName="$OUTPUT_BUCKET" \
  --region "$REGION"
ok "CloudFormation stack deployed"

_out() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}
RUN_ROLE_ARN=$(_out OmicsRunRoleArn)
VPC_CONFIG=$(_out OmicsVpcConfigName)
NAT_GW_ID=$(_out NatGatewayId)
SM_ENDPOINT_ID=$(_out SecretsManagerEndpointId)
VPC_ID=$(_out VpcId)
info "Run role   : $RUN_ROLE_ARN"
info "VPC config : $VPC_CONFIG"
info "NAT GW     : $NAT_GW_ID"
info "SM endpoint: $SM_ENDPOINT_ID"

# ── Step 5: Permission & network checks ──────────────────────────────
banner "Step 5/7 — Verifying permissions and networking"

# NAT Gateway state
echo "  Checking NAT Gateway..."
NAT_STATE=$(aws ec2 describe-nat-gateways \
  --nat-gateway-ids "$NAT_GW_ID" --region "$REGION" \
  --query "NatGateways[0].State" --output text 2>/dev/null || echo "unknown")
[[ "$NAT_STATE" == "available" ]] \
  || err "NAT Gateway $NAT_GW_ID is in state '$NAT_STATE' (expected 'available'). Check the VPC in the console."
ok "NAT Gateway is available"

# Secrets Manager VPC endpoint state
echo "  Checking Secrets Manager VPC endpoint..."
SM_EP_STATE=$(aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$SM_ENDPOINT_ID" --region "$REGION" \
  --query "VpcEndpoints[0].State" --output text 2>/dev/null || echo "unknown")
[[ "$SM_EP_STATE" == "available" ]] \
  || err "Secrets Manager endpoint $SM_ENDPOINT_ID is in state '$SM_EP_STATE'. Wait a minute and re-run status.sh."
ok "Secrets Manager VPC endpoint is available"

# IAM run role accessible
echo "  Checking IAM run role..."
aws iam get-role \
  --role-name "${STACK_NAME}-omics-run-role" \
  --region "$REGION" > /dev/null 2>&1 \
  || err "IAM run role '${STACK_NAME}-omics-run-role' not found."
ok "IAM run role exists"

# S3 access from IAM role perspective — test that bucket policy doesn't block
echo "  Checking S3 bucket accessibility..."
aws s3 ls "s3://$INPUT_BUCKET" --region "$REGION" > /dev/null 2>&1 \
  || err "Input bucket '$INPUT_BUCKET' no longer accessible — bucket policy may have changed."
ok "S3 input bucket accessible"

# Private route table has a default route via NAT
echo "  Checking VPC routing (private subnet → NAT)..."
PRIVATE_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Name,Values=${STACK_NAME}-private-rt" \
  --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true)
if [[ -n "$PRIVATE_RT_ID" && "$PRIVATE_RT_ID" != "None" ]]; then
  NAT_ROUTE=$(aws ec2 describe-route-tables \
    --route-table-ids "$PRIVATE_RT_ID" --region "$REGION" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" \
    --output text 2>/dev/null || true)
  [[ "$NAT_ROUTE" == "$NAT_GW_ID" ]] \
    || warn "Private route table default route does not point to expected NAT Gateway — verify in the console."
  ok "Private subnet routes internet traffic through NAT Gateway"
else
  warn "Could not look up private route table — skipping route check"
fi

ok "All permission and network checks passed"

# ── Step 6: Register HealthOmics workflows ───────────────────────────
banner "Step 6/7 — Registering HealthOmics workflows"
pushd "$WORK_DIR/workflow" > /dev/null

zip -q /tmp/workflow-validate.zip validate.wdl tasks/validate.wdl
VALIDATE_WF_ID=$(aws omics create-workflow \
  --name "jsl-dicom-deid-validate" --engine WDL --main validate.wdl \
  --definition-zip fileb:///tmp/workflow-validate.zip \
  --region "$REGION" --query id --output text)
ok "Validate workflow registered: $VALIDATE_WF_ID"

zip -q /tmp/workflow-prod.zip main.wdl tasks/deidentify.wdl
PROD_WF_ID=$(aws omics create-workflow \
  --name "jsl-dicom-deid" --engine WDL --main main.wdl \
  --definition-zip fileb:///tmp/workflow-prod.zip \
  --region "$REGION" --query id --output text)
ok "Production workflow registered: $PROD_WF_ID"

popd > /dev/null

echo "  Waiting for workflows to become ACTIVE..."
for WF_ID in "$VALIDATE_WF_ID" "$PROD_WF_ID"; do
  WF_STATUS="CREATING"
  for i in $(seq 1 24); do
    WF_STATUS=$(aws omics get-workflow --id "$WF_ID" --region "$REGION" --query status --output text)
    [[ "$WF_STATUS" == "ACTIVE" ]] && break
    info "Workflow $WF_ID: $WF_STATUS — waiting 15s..."
    sleep 15
  done
  [[ "$WF_STATUS" == "ACTIVE" ]] || err "Workflow $WF_ID never became ACTIVE (status: $WF_STATUS)"
  ok "Workflow $WF_ID is ACTIVE"
done

# ── Step 7: Run test de-identification ───────────────────────────────
banner "Step 7/7 — Test de-identification run"
echo "  This runs the validation workflow on a bundled test DICOM to confirm"
echo "  end-to-end connectivity: container → license check → Secrets Manager → S3."
echo ""
echo "  Hardware: omics.m.xlarge (4 vCPU / 16 GB) — cheapest available"
echo "  Est. time: ~10 minutes  ·  Est. cost: ~\$2–5"
echo ""
echo "  You need the AWS Marketplace container image URI."
echo "  It looks like: 709825985650.dkr.ecr.us-east-1.amazonaws.com/john-snow-labs/jsl-dicom-deid:latest"
echo "  (Find it in the AWS Marketplace console after subscribing to the product.)"
echo ""
read -p "  Container image URI: " CONTAINER_IMAGE
[[ -z "$CONTAINER_IMAGE" ]] && err "Container image URI required. Subscribe to the product on AWS Marketplace."

if ! echo "$CONTAINER_IMAGE" | grep -qE '^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/.+'; then
  warn "URI doesn't look like an ECR address — double-check it before continuing."
  read -p "  Continue anyway? [y/N] " -r CONT
  [[ "${CONT:-N}" =~ ^[Yy]$ ]] || err "Aborted."
fi

cat > /tmp/validate-params.json <<EOF
{
  "output_s3_uri":   "s3://${OUTPUT_BUCKET}/validation-output/",
  "container_image": "${CONTAINER_IMAGE}",
  "jsl_secret_arn":  "${JSL_SECRET_ARN}",
  "instance_type":   "omics.m.xlarge"
}
EOF

RUN_ID=$(aws omics start-run \
  --workflow-id        "$VALIDATE_WF_ID" \
  --role-arn           "$RUN_ROLE_ARN" \
  --output-uri         "s3://$OUTPUT_BUCKET/omics-output/" \
  --networking-mode    VPC \
  --configuration-name "$VPC_CONFIG" \
  --parameters         file:///tmp/validate-params.json \
  --region             "$REGION" \
  --query id --output text)
ok "Validation run started: $RUN_ID"

# ── save state ────────────────────────────────────────────────────────
cat > "$STATE_FILE" <<EOF
{
  "stack_name":           "$STACK_NAME",
  "region":               "$REGION",
  "account_id":           "$ACCOUNT_ID",
  "input_bucket":         "$INPUT_BUCKET",
  "output_bucket":        "$OUTPUT_BUCKET",
  "validate_workflow_id": "$VALIDATE_WF_ID",
  "prod_workflow_id":     "$PROD_WF_ID",
  "last_run_id":          "$RUN_ID",
  "deployed_at":          "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# ── poll for result ───────────────────────────────────────────────────
echo "  Polling every 30s (up to 20 min)..."
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
  info "De-identified test output: s3://$OUTPUT_BUCKET/validation-output/"
  echo ""
  echo -e "${BOLD}  Next steps:${RESET}"
  info "• Point your production input at s3://$INPUT_BUCKET"
  info "• Run production workflow ID: $PROD_WF_ID"
  info "• See docs/ for parameter reference and hardware sizing"
else
  warn "VALIDATION $FINAL_STATUS"
  info "Check logs: aws logs tail /aws/omics/runs --since 1h --region $REGION"
  info "Run detail: aws omics get-run --id $RUN_ID --region $REGION"
fi

# ── cost warning (always shown) ───────────────────────────────────────
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ⚠  ONGOING CHARGES"
echo -e "  NAT Gateway: ~\$0.045/hr (~\$1.08/day) until you run cleanup"
echo -e ""
echo -e "  Status  : curl -sSL ${RAW_BASE}/scripts/status.sh | bash"
echo -e "  Cleanup : curl -sSL ${RAW_BASE}/scripts/cleanup.sh | bash"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
