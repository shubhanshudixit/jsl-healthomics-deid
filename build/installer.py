import os
import shutil
from johnsnowlabs import nlp

HARDWARE_TARGET = os.environ.get("HARDWARE_TARGET", "cpu")
model_ref = os.environ.get("MODEL_TO_LOAD", None)

nlp.install(
    json_license_path="/run/secrets/license",
    browser_login=False,
    force_browser=False,
    hardware_platform=HARDWARE_TARGET,
    visual=True,
    refresh_install=True,
)

spark = nlp.start(model_cache_folder="/app/model_cache", visual=True)
spark.sparkContext.setLogLevel("ERROR")

if model_ref:

    from sparkocr.pretrained import PretrainedPipeline

    pipe = PretrainedPipeline(model_ref, "en", "clinical/ocr")
    pipe.model.save("/opt/ml/model")
    shutil.rmtree("/app/model_cache")
