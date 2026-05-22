import os
import json
import boto3
import logging
import sys
import shutil
import tempfile
import socket
from urllib.parse import urlparse

# ── Network connectivity check ─────────────────────────────────────────────
def check_network():
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    targets = [
        ("licensecheck.johnsnowlabs.com", 443),
        (f"secretsmanager.{region}.amazonaws.com", 443),
    ]
    for host, port in targets:
        try:
            ip = socket.gethostbyname(host)
            sock = socket.create_connection((host, port), timeout=5)
            sock.close()
            print(f"INFO network ✅ {host} ({ip}):{port} reachable")
        except socket.gaierror as e:
            print(f"ERROR network ❌ {host} DNS resolution failed: {e}")
        except Exception as e:
            print(f"ERROR network ❌ {host}:{port} unreachable: {e}")

# ── Load license from Secrets Manager at runtime ──────────────────────────
def load_jsl_license():
    # JSL_SECRET_ARN must be set by the customer — no default account ID
    secret_arn = os.environ.get("JSL_SECRET_ARN")
    if not secret_arn:
        raise ValueError("JSL_SECRET_ARN environment variable is required. "
                         "Set it to the ARN of your Secrets Manager secret "
                         "containing the JSL license JSON.")

    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    print(f"INFO loading JSL license from Secrets Manager: {secret_arn}")

    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_arn)
    license_data = json.loads(response["SecretString"])
    print("INFO license fetched from Secrets Manager ✅")

    # Set only the JWT license env vars — do NOT set AWS STS tokens.
    # JSL will call licensecheck.johnsnowlabs.com to get fresh STS tokens itself.
    os.environ["SPARK_NLP_LICENSE"] = license_data["SPARK_NLP_LICENSE"]
    os.environ["SPARK_OCR_LICENSE"] = license_data["SPARK_OCR_LICENSE"]
    os.environ["SECRET"]            = license_data["SECRET"]
    os.environ["SPARK_OCR_SECRET"]  = license_data["SPARK_OCR_SECRET"]
    os.environ["JSL_VERSION"]       = license_data.get("JSL_VERSION", "6.4.0")
    os.environ["OCR_VERSION"]       = license_data.get("OCR_VERSION", "6.4.0")
    os.environ["PUBLIC_VERSION"]    = license_data.get("PUBLIC_VERSION", "6.4.0")
    print("INFO JSL license env vars set ✅")


# ── Startup sequence ───────────────────────────────────────────────────────
print("INFO checking network connectivity...")
check_network()

print("INFO loading JSL license...")
load_jsl_license()

print("INFO starting Spark + JSL...")
from johnsnowlabs import nlp
from pyspark.ml import PipelineModel
from pyspark.sql.functions import col, udf
from pyspark.sql.types import StringType

spark = nlp.start(visual=True)
spark.sparkContext.setLogLevel("ERROR")
print("INFO nlp.start() succeeded ✅")


# ── Model ──────────────────────────────────────────────────────────────────
class Model():
    def __init__(self, spark_pipeline):
        self.pipeline = spark_pipeline

    def process(self, input_file, output_folder):
        def get_name(path, keep_subfolder_level=0):
            return path.split("/")[-1] + "_deid"

        print(f"INFO processing: {input_file}")
        tmp_out = tempfile.mkdtemp()

        dicom_df = spark.read.format("binaryFile").load(input_file)
        result_df = self.pipeline.transform(dicom_df)

        result_df.withColumn("fileName", udf(get_name, StringType())(col("path"))) \
            .write \
            .format("binaryFormat") \
            .option("type", "dicom") \
            .option("field", "dicom_cleaned") \
            .option("prefix", "ocr_") \
            .option("nameField", "fileName") \
            .mode("overwrite") \
            .save(tmp_out)

        os.makedirs(output_folder, exist_ok=True)
        for f in os.listdir(tmp_out):
            shutil.copy2(os.path.join(tmp_out, f), os.path.join(output_folder, f))
        shutil.rmtree(tmp_out)

        output_file = "ocr_" + input_file.split("/")[-1] + "_deid.dcm"
        return os.path.join(output_folder, output_file)


def load_model():
    model_path = os.environ.get("MODEL_PATH", "/opt/ml/model")
    print(f"INFO loading model from {model_path}...")
    pipeline = PipelineModel.load(model_path)
    print("INFO model loaded ✅")
    return Model(pipeline)


# Initialize logging
def get_logger(logger_name):
    log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
    logger = logging.getLogger(logger_name)
    logger.setLevel(log_level)
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(log_level)
    handler.setFormatter(logging.Formatter("%(name)s [%(asctime)s] [%(levelname)s] %(message)s"))
    logger.addHandler(handler)
    return logger

logger = get_logger("jsl-dicom-deid")

# ── Helpers ────────────────────────────────────────────────────────────────
def parse_s3_uri(uri):
    parsed = urlparse(uri)
    return parsed.netloc, parsed.path.lstrip("/")

def list_s3_files(s3, bucket, prefix):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith("/"):
                yield key

def main_local(input_dir, output_dir):
    """HealthOmics /mnt mode — reads/writes local mounted paths"""
    print(f"INFO main_local: input={input_dir}, output={output_dir}")
    os.makedirs(output_dir, exist_ok=True)
    model = load_model()

    dcm_files = [f for f in os.listdir(input_dir) if f.endswith(".dcm")]
    print(f"INFO found {len(dcm_files)} .dcm files")

    for filename in dcm_files:
        local_path = os.path.join(input_dir, filename)
        print(f"INFO processing {filename}...")
        output_local = model.process(local_path, output_dir)
        print(f"INFO done → {output_local}")

    print("INFO all files processed ✅")

def main_s3(input_s3, output_s3):
    """S3 direct mode — downloads from S3, processes, uploads back"""
    print(f"INFO main_s3: input={input_s3}, output={output_s3}")
    s3 = boto3.client("s3")
    in_bucket, in_prefix = parse_s3_uri(input_s3)
    out_bucket, out_prefix = parse_s3_uri(output_s3)
    model = load_model()

    with tempfile.TemporaryDirectory() as tmpdir:
        output_folder = tempfile.mkdtemp()
        for key in list_s3_files(s3, in_bucket, in_prefix):
            filename = os.path.basename(key)
            local_path = os.path.join(tmpdir, filename)

            print(f"INFO downloading {key}...")
            s3.download_file(in_bucket, key, local_path)

            print(f"INFO processing {filename}...")
            output_local = model.process(local_path, output_folder)

            out_key = os.path.join(out_prefix, filename + "_deid")
            print(f"INFO uploading to s3://{out_bucket}/{out_key}...")
            s3.upload_file(output_local, out_bucket, out_key)

            os.remove(local_path)
            os.remove(output_local)

        shutil.rmtree(output_folder)

    print("INFO all files processed ✅")

def main_test(output_s3):
    """Validation mode — de-identifies the bundled test_file.dcm and uploads result to S3.
    Used by the validate.wdl workflow to confirm the full setup is working."""
    test_file = "/opt/ml/test/test_file.dcm"

    if not os.path.exists(test_file):
        raise FileNotFoundError(
            f"Bundled test file not found at {test_file}. "
            "This indicates a container build issue — please contact JSL support."
        )

    print(f"INFO test mode: using bundled {test_file}")
    print(f"INFO test output target: {output_s3}")

    s3 = boto3.client("s3")
    out_bucket, out_prefix = parse_s3_uri(output_s3)
    model = load_model()

    with tempfile.TemporaryDirectory() as tmpdir:
        output_local = model.process(test_file, tmpdir)
        filename = os.path.basename(output_local)
        out_key = (out_prefix.rstrip("/") + "/" + filename).lstrip("/")

        print(f"INFO uploading test output to s3://{out_bucket}/{out_key}...")
        s3.upload_file(output_local, out_bucket, out_key)

    print(f"INFO test output written to s3://{out_bucket}/{out_key} ✅")
    print("INFO setup validation complete ✅")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="JSL DICOM De-Identification")
    parser.add_argument("--input_dir",    help="Local input directory (HealthOmics /mnt mode)")
    parser.add_argument("--output_dir",   help="Local output directory (HealthOmics /mnt mode)")
    parser.add_argument("--input",        help="S3 URI of input folder (S3 direct mode)")
    parser.add_argument("--output",       help="S3 URI of output folder (S3 direct mode)")
    parser.add_argument("--test",         action="store_true",
                                          help="Validation mode: de-identify bundled test_file.dcm and upload to --output")
    parser.add_argument("--license_path", help="Unused — kept for compatibility")
    args = parser.parse_args()

    if args.test and args.output:
        main_test(args.output)
    elif args.input_dir and args.output_dir:
        main_local(args.input_dir, args.output_dir)
    elif args.input and args.output:
        main_s3(args.input, args.output)
    else:
        parser.error("Provide either --test --output S3_URI, "
                     "--input_dir/--output_dir, or --input/--output")
