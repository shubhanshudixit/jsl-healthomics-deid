version 1.0

# ─────────────────────────────────────────────────────────────────────────────
# JSL DICOM De-Identification Workflow
# AWS HealthOmics Partner Workflow
#
# Description:
#   De-identifies DICOM files stored in S3 using John Snow Labs Visual NLP.
#   Removes PHI from both DICOM metadata tags and pixel data.
#
# Prerequisites:
#   - VPC with private subnet routing through a NAT gateway to the internet
#   - HealthOmics VPC configuration pointing to the private subnet
#   - Secrets Manager secret containing the JSL license JSON
#   - IAM run role with S3, ECR, and Secrets Manager permissions
#
# Inputs:
#   input_s3_uri    - S3 URI of folder containing input DICOM files
#   output_s3_uri   - S3 URI of folder where de-identified files will be written
#   container_image - ECR URI of the JSL de-id container
#   jsl_secret_arn  - ARN of Secrets Manager secret containing JSL license JSON
#   instance_type   - HealthOmics instance type (default: omics.m.xlarge)
# ─────────────────────────────────────────────────────────────────────────────

import "tasks/deidentify.wdl" as deid_task

workflow DicomDeId {

    input {
        String input_s3_uri
        String output_s3_uri
        String container_image
        String jsl_secret_arn
        String instance_type = "omics.m.xlarge"
    }

    call deid_task.RunDeId {
        input:
            input_s3_uri    = input_s3_uri,
            output_s3_uri   = output_s3_uri,
            container_image = container_image,
            jsl_secret_arn  = jsl_secret_arn,
            instance_type   = instance_type
    }

    output {
        String job_status  = RunDeId.job_status
        String output_path = RunDeId.output_path
    }

    meta {
        author:      "John Snow Labs"
        description: "DICOM de-identification using JSL Visual NLP — removes PHI from metadata tags and pixel data"
        version:     "2.0.0"
    }
}
