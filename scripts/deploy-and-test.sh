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

err() { echo "❌ $*"; exit 1; }
ok()  { echo "✅ $*"; }

# ── credentials ──────────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "No AWS credentials. Run this from AWS CloudShell."
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
echo "Account: $ACCOUNT_ID  Region: $REGION"

# ── collect inputs ───────────────────────────────────────────────────
echo ""
echo "Prerequisites:"
echo "  1. A Secrets Manager secret with your JSL license JSON"
echo "  2. An S3 input bucket  (your DICOM files)"
echo "  3. An S3 output bucket (de-identified results)"
echo ""

read -p "JSL Secret ARN: " JSL_SECRET_ARN
[[ -z "$JSL_SECRET_ARN" ]] && err "Secret ARN required."

read -p "Input S3 bucket name:  " INPUT_BUCKET
[[ -z "$INPUT_BUCKET" ]] && err "Input bucket required."

read -p "Output S3 bucket name: " OUTPUT_BUCKET
[[ -z "$OUTPUT_BUCKET" ]] && err "Output bucket required."

echo ""
read -p "Proceed? [y/N] " -r GO
[[ "${GO:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── deploy stack ─────────────────────────────────────────────────────
echo ""
echo "Deploying infrastructure..."
git clone --quiet --depth 1 "$REPO_URL" "$WORK_DIR"
trap "rm -rf '$WORK_DIR' /tmp/wf-validate.zip /tmp/wf-prod.zip /tmp/run-params.json" EXIT

aws cloudformation deploy \
  --template-file "$WORK_DIR/infra/setup.yml" \
  --stack-name    "$STACK_NAME" \
  --capabilities  CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    JslSecretArn="$JSL_SECRET_ARN" \
    InputBucketName="$INPUT_BUCKET" \
    OutputBucketName="$OUTPUT_BUCKET" \
  --region "$REGION"

_out() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
RUN_ROLE_ARN=$(_out OmicsRunRoleArn)
VPC_CONFIG=$(_out OmicsVpcConfigName)
ok "Stack deployed  |  role: $RUN_ROLE_ARN  |  vpc-config: $VPC_CONFIG"

# ── register workflows ────────────────────────────────────────────────
echo ""
echo "Registering workflows..."
pushd "$WORK_DIR/workflow" > /dev/null

zip -q /tmp/wf-validate.zip validate.wdl tasks/validate.wdl
VALIDATE_WF_ID=$(aws omics create-workflow \
  --name "jsl-dicom-deid-validate" --engine WDL --main validate.wdl \
  --definition-zip fileb:///tmp/wf-validate.zip \
  --region "$REGION" --query id --output text)

zip -q /tmp/wf-prod.zip main.wdl tasks/deidentify.wdl
PROD_WF_ID=$(aws omics create-workflow \
  --name "jsl-dicom-deid" --engine WDL --main main.wdl \
  --definition-zip fileb:///tmp/wf-prod.zip \
  --region "$REGION" --query id --output text)

popd > /dev/null

for WF_ID in "$VALIDATE_WF_ID" "$PROD_WF_ID"; do
  until [[ $(aws omics get-workflow --id "$WF_ID" --region "$REGION" --query status --output text) == "ACTIVE" ]]; do
    echo "  Workflow $WF_ID: waiting..."
    sleep 15
  done
  ok "Workflow $WF_ID active"
done

# ── run test de-identification ────────────────────────────────────────
echo ""
echo "The validation run de-identifies a bundled test DICOM."
echo "It tests the full path: ECR pull → license check → Secrets Manager → S3 write."
echo "Hardware: omics.m.xlarge (~\$2–5, ~10 min)"
echo ""
read -p "Marketplace container image URI: " CONTAINER_IMAGE
[[ -z "$CONTAINER_IMAGE" ]] && err "Container image URI required."

cat > /tmp/run-params.json <<EOF
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
  --parameters         file:///tmp/run-params.json \
  --region             "$REGION" \
  --query id --output text)
ok "Run started: $RUN_ID"

# save state
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

# ── poll ──────────────────────────────────────────────────────────────
echo "Polling every 30s..."
for i in $(seq 1 40); do
  STATUS=$(aws omics get-run --id "$RUN_ID" --region "$REGION" --query status --output text)
  echo "  [$(date +%H:%M:%S)] $STATUS"
  case "$STATUS" in
    COMPLETED) ok "Validation passed — output: s3://$OUTPUT_BUCKET/validation-output/"; break ;;
    FAILED|CANCELLED)
      echo "❌ Run $FINAL_STATUS"
      echo "   Logs: aws logs tail /aws/omics/runs --since 1h --region $REGION"
      break ;;
  esac
  sleep 30
done

echo ""
echo "⚠  NAT Gateway running at ~\$0.045/hr until cleanup."
echo "   Cleanup: curl -sSL ${RAW_BASE}/scripts/cleanup.sh | bash"
