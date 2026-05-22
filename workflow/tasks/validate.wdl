version 1.0

# ─────────────────────────────────────────────────────────────────────────────
# Task: RunValidation
#
# End-to-end smoke test for a new customer setup.
# Uses the test_file.dcm bundled in the container at /opt/ml/test/test_file.dcm.
#
# What it validates:
#   1. Network — can the container reach licensecheck.johnsnowlabs.com and
#      the Secrets Manager VPC endpoint?
#   2. License — can it fetch and parse the JSL license from Secrets Manager?
#   3. Model — does the pre-baked model load successfully?
#   4. Pipeline — does a real DICOM file get de-identified and written to S3?
#
# A PASSED result means the customer's full setup is working and they are
# ready to run production workflows.
# ─────────────────────────────────────────────────────────────────────────────

task RunValidation {

    input {
        String output_s3_uri
        String container_image
        String jsl_secret_arn
        String instance_type
    }

    command <<<
        set -euo pipefail

        echo "================================================"
        echo " JSL DICOM De-Identification — Setup Validation"
        echo " Container: ~{container_image}"
        echo " Output:    ~{output_s3_uri}"
        echo "================================================"
        echo ""

        export JSL_SECRET_ARN="~{jsl_secret_arn}"

        python3 /app/app.py \
            --test \
            --output ~{output_s3_uri}

        echo ""
        echo "================================================"
        echo " VALIDATION PASSED"
        echo " Your setup is ready for production use."
        echo " De-identified test output is at: ~{output_s3_uri}"
        echo "================================================"

        echo "PASSED" > /tmp/validation_status.txt
    >>>

    output {
        String validation_status = read_string("/tmp/validation_status.txt")
        String output_path       = output_s3_uri
    }

    runtime {
        docker:            container_image
        memory:            "28 GB"
        cpu:               8
        omicsInstanceType: instance_type
        maxRetries:        0   # Do not retry on failure — surface the error immediately
    }

    meta {
        description: "End-to-end setup validation using the bundled test DICOM. Run this once after deploying the CloudFormation stack."
    }

    parameter_meta {
        output_s3_uri:   { description: "S3 URI where the de-identified test output will be written (e.g. s3://your-bucket/validation-output/)", category: "required" }
        container_image: { description: "ECR URI of the JSL de-id Docker image from AWS Marketplace",                                            category: "required" }
        jsl_secret_arn:  { description: "ARN of the Secrets Manager secret containing your JSL license JSON",                                    category: "required" }
        instance_type:   { description: "HealthOmics compute instance type",                                                                     category: "optional" }
    }
}
