version 1.0

# ─────────────────────────────────────────────────────────────────────────────
# Task: RunDeId
#
# Runs the JSL DICOM de-identification container.
# Reads directly from S3 input URI and writes back to S3 output URI.
# Fetches JSL license from Secrets Manager at runtime via JSL_SECRET_ARN.
# ─────────────────────────────────────────────────────────────────────────────

task RunDeId {

    input {
        String input_s3_uri
        String output_s3_uri
        String container_image
        String jsl_secret_arn
        String instance_type
    }

    command <<<
        set -euo pipefail

        echo "=========================================="
        echo " JSL DICOM De-Identification"
        echo " Input:  ~{input_s3_uri}"
        echo " Output: ~{output_s3_uri}"
        echo "=========================================="

        export JSL_SECRET_ARN="~{jsl_secret_arn}"

        python3 /app/app.py \
            --input  ~{input_s3_uri} \
            --output ~{output_s3_uri}

        echo "De-identification complete."
        echo "SUCCESS" > /tmp/job_status.txt
    >>>

    output {
        String job_status  = read_string("/tmp/job_status.txt")
        String output_path = output_s3_uri
    }

    runtime {
        docker:            container_image
        memory:            "28 GB"
        cpu:               8
        omicsInstanceType: instance_type
        maxRetries:        1
    }

    meta {
        description: "Runs JSL DICOM de-id pipeline — reads from S3 input URI, writes to S3 output URI"
    }

    parameter_meta {
        input_s3_uri:    { description: "S3 URI of input DICOM folder",                          category: "required" }
        output_s3_uri:   { description: "S3 URI where de-identified files land",                 category: "required" }
        container_image: { description: "ECR URI of the JSL de-id Docker image",                 category: "required" }
        jsl_secret_arn:  { description: "ARN of Secrets Manager secret with JSL license JSON",   category: "required" }
        instance_type:   { description: "HealthOmics compute instance type",                     category: "optional" }
    }
}
