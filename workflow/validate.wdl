version 1.0

# ─────────────────────────────────────────────────────────────────────────────
# JSL DICOM De-Identification — Setup Validation Workflow
# AWS HealthOmics Partner Workflow
#
# Purpose:
#   Run this workflow ONCE after deploying the CloudFormation stack (infra/setup.yml)
#   and after pasting your JSL license into Secrets Manager.
#   It performs a full end-to-end test using a bundled synthetic DICOM file,
#   verifying that networking, licensing, and the de-identification pipeline all work.
#
# If this workflow completes with status PASSED, your setup is ready for production.
# If it fails, check the CloudWatch logs for the specific error.
#
# Inputs:
#   output_s3_uri   - S3 URI where the de-identified test output will be written
#   container_image - ECR URI of the JSL de-id container from AWS Marketplace
#   jsl_secret_arn  - ARN of your Secrets Manager secret (from CloudFormation Outputs)
#   instance_type   - HealthOmics instance type (default: omics.m.xlarge)
# ─────────────────────────────────────────────────────────────────────────────

import "tasks/validate.wdl" as validate_task

workflow ValidateSetup {

    input {
        String output_s3_uri
        String container_image
        String jsl_secret_arn
        String instance_type = "omics.m.xlarge"
    }

    call validate_task.RunValidation {
        input:
            output_s3_uri   = output_s3_uri,
            container_image = container_image,
            jsl_secret_arn  = jsl_secret_arn,
            instance_type   = instance_type
    }

    output {
        String validation_status = RunValidation.validation_status
        String output_path       = RunValidation.output_path
    }

    meta {
        author:      "John Snow Labs"
        description: "One-time setup validation workflow — run after CloudFormation deploy to confirm everything is working."
        version:     "1.0.0"
    }
}
