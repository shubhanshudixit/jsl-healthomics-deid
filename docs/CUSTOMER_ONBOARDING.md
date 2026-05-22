# JSL DICOM De-Identification — Customer Onboarding Guide

> **Time to complete:** ~15 minutes (plus ~10 minutes for the validation workflow to run).
> No AWS expertise required — the CloudFormation stack handles all infrastructure.

---

## What You Get

A fully-managed pipeline that takes DICOM medical images from your S3 bucket,
removes all Protected Health Information (PHI) from both the DICOM metadata tags
and the pixel data, and writes the clean files back to S3.

**Technology:** John Snow Labs Visual NLP, running on AWS HealthOmics.

---

## Prerequisites

Before you start, make sure you have:

- [ ] An **AWS account** with permissions to create CloudFormation stacks, VPCs, IAM roles, and Secrets Manager secrets.
- [ ] A **JSL license JSON** from John Snow Labs (contact your JSL account representative if you don't have one).
- [ ] The **AWS Marketplace container image URI** provided by JSL after subscribing.

---

## Step 1 — Deploy the CloudFormation Stack

This single stack creates everything: the VPC, networking, IAM role, S3 bucket, and HealthOmics configuration.

**Option A — AWS Console (recommended for non-technical users)**

1. Open the AWS CloudFormation console in your target region.
2. Click **Create stack → With new resources**.
3. Upload the file `infra/setup.yml`.
4. Fill in the parameters:
   - **JslSecretName** — leave as default (`jsl-dicom-deid-license`) unless you have a naming convention.
   - **VpcCidr** — leave as default (`10.0.0.0/16`) unless it conflicts with an existing VPC.
   - **OmicsVpcConfigName** — leave as default (`jsl-deid-vpc-config`).
5. Click through the remaining screens and check **"I acknowledge that AWS CloudFormation might create IAM resources"**.
6. Click **Create stack**.

> **Deploy time:** 5–10 minutes. Wait until the stack status shows `CREATE_COMPLETE`.

**Option B — AWS CLI**

```bash
aws cloudformation deploy \
  --template-file infra/setup.yml \
  --stack-name jsl-dicom-deid \
  --capabilities CAPABILITY_NAMED_IAM \
  --region YOUR-REGION
```

---

## Step 2 — Note Your Stack Outputs

Once the stack is `CREATE_COMPLETE`, open the **Outputs** tab. You will need these values:

| Output Key | What It Is |
|---|---|
| `S3BucketName` | Your S3 bucket — upload input DICOMs here |
| `JslSecretArn` | ARN of the Secrets Manager secret |
| `OmicsRunRoleArn` | IAM role ARN for running workflows |
| `OmicsVpcConfigName` | HealthOmics VPC configuration name |
| `NextStep` | Direct link to the Secrets Manager console |

---

## Step 3 — Add Your JSL License

The CloudFormation stack creates a placeholder secret. You need to replace it with your real JSL license.

1. Click the **NextStep** link from the stack outputs (or navigate to Secrets Manager in the AWS Console).
2. Find the secret named `jsl-dicom-deid-license`.
3. Click **Retrieve secret value** → **Edit**.
4. Replace the placeholder JSON with your JSL license JSON. It should look like this:

```json
{
    "SPARK_NLP_LICENSE":    "eyJhbGci...",
    "SPARK_OCR_LICENSE":    "eyJhbGci...",
    "SECRET":               "6.4.x-xxxxx",
    "SPARK_OCR_SECRET":     "6.4.x-xxxxx",
    "JSL_VERSION":          "6.4.0",
    "OCR_VERSION":          "6.4.0",
    "PUBLIC_VERSION":       "6.4.0"
}
```

> **Important:** Do NOT include `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or `AWS_SESSION_TOKEN` fields.
> The container fetches fresh credentials automatically — stale STS tokens in the secret cause failures.

5. Click **Save**.

---

## Step 4 — Register the Workflows in HealthOmics

You need to register both the validation workflow and the production workflow.

```bash
# Register the validation workflow
aws omics create-workflow \
  --name jsl-dicom-deid-validate \
  --definition-zip fileb://workflow-validate.zip \
  --region YOUR-REGION

# Register the production workflow
aws omics create-workflow \
  --name jsl-dicom-deid \
  --definition-zip fileb://workflow-production.zip \
  --region YOUR-REGION
```

To create the zip files:

```bash
# Validation workflow zip (contains validate.wdl and tasks/validate.wdl)
cd workflow
zip -r ../workflow-validate.zip validate.wdl tasks/validate.wdl

# Production workflow zip (contains main.wdl and tasks/deidentify.wdl)
zip -r ../workflow-production.zip main.wdl tasks/deidentify.wdl
cd ..
```

Note the **Workflow IDs** returned — you'll need them in the next steps.

---

## Step 5 — Choose Your Hardware

The `instance_type` parameter controls how much CPU and memory HealthOmics allocates per run.
A larger instance processes more files in parallel but costs more per run-minute.

**JSL DICOM de-identification is CPU-based (no GPU required).** Use the `omics.m` (memory-optimized)
family — Spark and the JSL Visual NLP model are memory-hungry.

| Instance | vCPU | Memory | Recommended for |
|---|---|---|---|
| `omics.m.xlarge` | 4 | 16 GB | **Default** — single files or small batches (< 20 DICOMs) |
| `omics.m.2xlarge` | 8 | 32 GB | Medium batches (20–100 DICOMs), faster turnaround |
| `omics.m.4xlarge` | 16 | 64 GB | Large batches (100–500 DICOMs) |
| `omics.m.8xlarge` | 32 | 128 GB | High-volume / time-sensitive workloads (500+ DICOMs) |

> **Tip:** `omics.m.xlarge` is sufficient for the validation workflow. Scale up only for production
> runs where throughput matters. HealthOmics bills per vCPU-minute, so right-sizing saves cost.

Set your chosen instance type in the parameters file for each workflow run.
You can change it run-by-run — no infrastructure changes are needed.

---

## Step 6 — Run the Validation Workflow

Before processing any real data, run the validation workflow to confirm everything is working.
It uses a bundled synthetic DICOM file — no real patient data is involved.

Copy `workflow/validate_params_template.json` to `validate_params.json` and fill in your values:

```json
{
    "output_s3_uri":   "s3://YOUR-BUCKET-NAME/validation-output/",
    "container_image": "MARKETPLACE-ECR-URI",
    "jsl_secret_arn":  "arn:aws:secretsmanager:YOUR-REGION:ACCOUNT-ID:secret:jsl-dicom-deid-license-XXXXXX",
    "instance_type":   "omics.m.xlarge"
}
```

All values (bucket name, secret ARN) are in the CloudFormation Outputs.

```bash
aws omics start-run \
  --workflow-id VALIDATE-WORKFLOW-ID \
  --role-arn arn:aws:iam::ACCOUNT-ID:role/jsl-dicom-deid-omics-run-role \
  --output-uri s3://YOUR-BUCKET/omics-output/ \
  --networking-mode VPC \
  --configuration-name jsl-deid-vpc-config \
  --parameters file://validate_params.json \
  --region YOUR-REGION
```

**Expected result:** The run completes with status `COMPLETED` and you see a de-identified DICOM in
`s3://YOUR-BUCKET/validation-output/`. The run logs in CloudWatch will show `VALIDATION PASSED`.

> **Runtime:** ~10 minutes (model load + Spark startup + de-identification).

**If the validation fails,** check the CloudWatch logs for the run. Common issues:

| Error | Cause | Fix |
|---|---|---|
| `DNS resolution failed: licensecheck.johnsnowlabs.com` | NAT gateway not routing correctly | Verify the private subnet route table points to the NAT gateway |
| `GetSecretValue access denied` | IAM role missing Secrets Manager permission | Check the run role policy in IAM |
| `SPARK_NLP_LICENSE env var not set` | License JSON has wrong field names | Check Step 3 — field names are case-sensitive |
| `ResourceNotFoundException` | Secret ARN is wrong | Copy the exact ARN from CloudFormation Outputs |
| `VPC config not found` | HealthOmics VPC configuration wasn't created | Re-deploy the CloudFormation stack |

---

## Step 7 — Run Production Workflows

Once validation passes, you're ready to process real DICOM data.

1. Upload your DICOM files to the S3 bucket (from the CloudFormation Outputs):
   ```bash
   aws s3 cp /local/path/to/dicoms/ s3://YOUR-BUCKET/input/ --recursive
   ```

2. Copy `workflow/params_template.json` to `params.json` and fill in your values:
   ```json
   {
       "input_s3_uri":    "s3://YOUR-BUCKET/input/",
       "output_s3_uri":   "s3://YOUR-BUCKET/output/",
       "container_image": "MARKETPLACE-ECR-URI",
       "jsl_secret_arn":  "arn:aws:secretsmanager:...",
       "instance_type":   "omics.m.xlarge"
   }
   ```

3. Start the run:
   ```bash
   aws omics start-run \
     --workflow-id PRODUCTION-WORKFLOW-ID \
     --role-arn arn:aws:iam::ACCOUNT-ID:role/jsl-dicom-deid-omics-run-role \
     --output-uri s3://YOUR-BUCKET/omics-output/ \
     --networking-mode VPC \
     --configuration-name jsl-deid-vpc-config \
     --parameters file://params.json \
     --region YOUR-REGION
   ```

4. Monitor progress:
   ```bash
   aws omics get-run --id RUN-ID --region YOUR-REGION
   ```

---

## License Renewal

Your JSL license contains JWT tokens that expire on a fixed date (your JSL representative will notify you).
When your license expires:

1. Obtain a new license JSON from JSL.
2. Go to Secrets Manager → your secret → **Edit**.
3. Paste the new license JSON and save.

No infrastructure changes are needed — the container fetches the license fresh at startup.

---

## Infrastructure Reference

| Resource | Created By | Purpose |
|---|---|---|
| VPC `10.0.0.0/16` | CloudFormation | Isolated network for HealthOmics tasks |
| Public subnet `10.0.0.0/24` | CloudFormation | Hosts the NAT gateway |
| Private subnet `10.0.1.0/24` | CloudFormation | HealthOmics ENI placement |
| NAT Gateway | CloudFormation | Internet access for `licensecheck.johnsnowlabs.com` |
| Secrets Manager VPC endpoint | CloudFormation | Private access to secrets (no NAT for license fetch) |
| S3 gateway endpoint | CloudFormation | Free private S3 access (no NAT charges for DICOM transfer) |
| IAM run role | CloudFormation | HealthOmics task permissions |
| S3 bucket | CloudFormation | DICOM input/output storage |
| HealthOmics VPC config | CloudFormation | Ties VPC/subnet/SG to HealthOmics runs |

---

## Support

- **JSL license issues:** Contact your John Snow Labs account representative.
- **AWS infrastructure issues:** Open a ticket with AWS Support.
- **Workflow/pipeline issues:** Check CloudWatch Logs at `/aws/omics/runs/RUN-ID`.
