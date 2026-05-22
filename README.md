# JSL DICOM De-Identification on AWS HealthOmics

Removes Protected Health Information (PHI) from DICOM medical images — both metadata tags and pixel data — using [John Snow Labs Visual NLP](https://www.johnsnowlabs.com/), running serverlessly on [AWS HealthOmics](https://aws.amazon.com/healthomics/).

[![Static Checks](https://github.com/shubhanshudixit/jsl-healthomics-deid/actions/workflows/ci.yml/badge.svg)](https://github.com/shubhanshudixit/jsl-healthomics-deid/actions/workflows/ci.yml)

---

## Deploy in one command (AWS CloudShell)

Open [AWS CloudShell](https://console.aws.amazon.com/cloudshell) and run:

```bash
curl -sSL https://raw.githubusercontent.com/shubhanshudixit/jsl-healthomics-deid/main/scripts/deploy-and-test.sh | bash
```

This single command:
1. Creates the full VPC + networking stack via CloudFormation
2. Registers both the validation and production HealthOmics workflows
3. Runs an end-to-end validation using a bundled test DICOM
4. Reports cost and any resources left running

**Prerequisites:**
- An AWS account with permissions to create VPCs, IAM roles, and HealthOmics workflows
- A JSL license (contact [John Snow Labs](https://www.johnsnowlabs.com/))
- The AWS Marketplace container image URI (provided after subscribing)

---

## Manage running resources

```bash
# Check what's deployed and if any runs are active (and costing money)
curl -sSL https://raw.githubusercontent.com/shubhanshudixit/jsl-healthomics-deid/main/scripts/status.sh | bash

# Tear everything down (stops all charges; S3 data is kept)
curl -sSL https://raw.githubusercontent.com/shubhanshudixit/jsl-healthomics-deid/main/scripts/cleanup.sh | bash
```

---

## Repository structure

```
├── build/                  Docker image (app.py, Dockerfile, installer.py, test_file.dcm)
├── workflow/
│   ├── main.wdl            Production de-identification workflow
│   ├── validate.wdl        Setup validation workflow (uses bundled test DICOM)
│   └── tasks/              Individual WDL task definitions
├── infra/
│   └── setup.yml           Single CloudFormation stack (VPC, IAM, Secrets Manager, HealthOmics config)
├── scripts/
│   ├── deploy-and-test.sh  One-command deploy + validate from CloudShell
│   ├── status.sh           Check deployed resources and running costs
│   └── cleanup.sh          Tear down all infrastructure
└── docs/
    └── CUSTOMER_ONBOARDING.md  Step-by-step guide for non-technical users
```

---

## How it works

```
CloudShell one-liner
    └─► CloudFormation stack
             ├── VPC (private subnet + NAT Gateway)
             ├── Secrets Manager VPC endpoint
             ├── IAM run role
             ├── S3 bucket (your DICOMs)
             └── HealthOmics VPC configuration
                      └─► HealthOmics workflow run
                               └─► JSL container
                                        ├── Fetches license from Secrets Manager
                                        ├── Calls licensecheck.johnsnowlabs.com (via NAT)
                                        ├── Loads de-id model from /opt/ml/model
                                        └─► De-identified DICOMs → S3
```

---

## Hardware options

Set `instance_type` in your params file. All instances use the `omics.m` (memory-optimized) family — JSL Visual NLP is Spark-based and memory-intensive.

| Instance | vCPU | Memory | Use case |
|---|---|---|---|
| `omics.m.xlarge` | 4 | 16 GB | Default — small batches / validation |
| `omics.m.2xlarge` | 8 | 32 GB | Medium batches (20–100 DICOMs) |
| `omics.m.4xlarge` | 16 | 64 GB | Large batches (100–500 DICOMs) |
| `omics.m.8xlarge` | 32 | 128 GB | High-volume workloads |

---

## CI

Every push and pull request runs static checks automatically:
- **cfn-lint** on `infra/setup.yml`
- **Python syntax** on `build/app.py` and `build/installer.py`
- **miniwdl check** on all WDL workflows
- **JSON validation** on params templates
- **Hardcoded account ID scan**

Live AWS tests (CloudFormation deploy + HealthOmics run) are triggered manually from CloudShell using the one-liner above.

---

## License & support

- **JSL license issues:** Contact your John Snow Labs representative
- **AWS infrastructure issues:** AWS Support
- **Workflow logs:** CloudWatch → `/aws/omics/runs/RUN-ID`
