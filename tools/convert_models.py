#!/usr/bin/env python3
"""Convert HuggingFace NSFW classifiers to CoreML for iOS.

Reads PyTorch checkpoints from models_cache/<repo>/ (downloaded via
`hf download <hf-id> --local-dir models_cache/<repo>/`) and produces
CoreML .mlmodelc.zip artefacts ready for upload to GitHub Releases.

For Android TFLite artefacts, see ``tools/convert_tflite.py`` — it
runs in a separate venv (``.venv-tflite``) because litert-torch and
tensorflow conflict on shared LLVM CLI flags inside one process.

Output:
    models_cache/converted/AdamCoddNSFW.mlmodelc.zip
    models_cache/converted/FalconsaiNSFW.mlmodelc.zip

Upload destination:
    https://github.com/nexas105/flutter_nsfw_scaner/releases  (tag: models-v1)

Preprocessing is BAKED INTO the CoreML model via ImageType(scale, bias),
mirroring the ViT preprocessor_config.json: (x/255 - 0.5) / 0.5 = x/127.5 - 1.
The plugin's CoreMLEngine passes raw 0-255 RGB CVPixelBuffers; Vision applies
the bias/scale automatically. Do NOT add manual normalisation on the Swift side.

Class labels are embedded so the model emits VNClassificationObservation,
which CoreMLEngine handles via Case 1 in classify(pixelBuffer:).

Usage:
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r tools/requirements.txt

    python tools/convert_models.py --all                  # both models
    python tools/convert_models.py --model adamcodd       # single model
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = REPO_ROOT / "models_cache"
OUTPUT_DIR = CACHE_DIR / "converted"


@dataclass
class ModelSpec:
    key: str
    hf_id: str
    local_dir: str
    output_name: str
    input_size: int  # square ViT input

    @property
    def src_path(self) -> Path:
        return CACHE_DIR / self.local_dir


MODELS: dict[str, ModelSpec] = {
    "adamcodd": ModelSpec(
        key="adamcodd",
        hf_id="AdamCodd/vit-base-nsfw-detector",
        local_dir="AdamCodd_vit-base-nsfw-detector",
        output_name="AdamCoddNSFW",
        input_size=384,
    ),
    "falconsai": ModelSpec(
        key="falconsai",
        hf_id="Falconsai/nsfw_image_detection",
        local_dir="Falconsai_nsfw_image_detection",
        output_name="FalconsaiNSFW",
        input_size=224,
    ),
}


def _load_hf_model(spec: ModelSpec):
    """Load HF checkpoint and return (model, class_labels)."""
    from transformers import AutoModelForImageClassification

    if not spec.src_path.exists():
        raise SystemExit(
            f"Source not found: {spec.src_path}\n"
            f"Run: hf download {spec.hf_id} --local-dir {spec.src_path}"
        )

    print(f"[{spec.output_name}] Loading PyTorch model from {spec.src_path}")
    model = AutoModelForImageClassification.from_pretrained(spec.src_path)
    model.eval()

    id2label = model.config.id2label
    class_labels = [id2label[i] for i in sorted(id2label.keys())]
    print(f"[{spec.output_name}] Class labels: {class_labels}")
    return model, class_labels


def _trace_logits_only(spec: ModelSpec, model):
    """Trace HF model to TorchScript with logits-only output."""
    import torch

    class LogitsOnly(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, x):
            return self.m(pixel_values=x).logits

    size = spec.input_size
    example = torch.rand(1, 3, size, size) * 2 - 1  # already in [-1, 1]
    print(f"[{spec.output_name}] Tracing for CoreML (input {size}x{size})")
    return torch.jit.trace(LogitsOnly(model), example, strict=False)


def convert_to_coreml(spec: ModelSpec) -> Path:
    """PyTorch → traced TorchScript → CoreML .mlpackage with baked preprocessing."""
    import coremltools as ct

    model, class_labels = _load_hf_model(spec)
    traced = _trace_logits_only(spec, model)
    size = spec.input_size

    # ViT normalisation: scaled = raw_pixel * (1/127.5) + (-1) = raw/127.5 - 1
    # ⇔ (raw/255 - 0.5) / 0.5  ✔ matches preprocessor_config.json {mean=0.5, std=0.5}
    print(f"[{spec.output_name}] Converting → CoreML (FP16, ImageType, classifier)")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, size, size),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        classifier_config=ct.ClassifierConfig(class_labels=class_labels),
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
    )

    mlmodel.author = f"nsfw_detect — converted from {spec.hf_id}"
    mlmodel.short_description = f"NSFW classifier (ViT-{size}) — labels: {class_labels}"
    mlmodel.version = "1.0"

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    mlpackage = OUTPUT_DIR / f"{spec.output_name}.mlpackage"
    if mlpackage.exists():
        shutil.rmtree(mlpackage)
    mlmodel.save(str(mlpackage))
    print(f"[{spec.output_name}] Wrote {mlpackage}")
    return mlpackage


def compile_and_zip_coreml(mlpackage: Path) -> Path:
    """Compile .mlpackage → .mlmodelc and zip for distribution. macOS-only."""
    out_dir = mlpackage.parent
    print(f"[{mlpackage.name}] Compiling → .mlmodelc via xcrun coremlc")

    proc = subprocess.run(
        ["xcrun", "coremlc", "compile", str(mlpackage), str(out_dir)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"coremlc failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")

    mlmodelc = out_dir / f"{mlpackage.stem}.mlmodelc"
    if not mlmodelc.exists():
        raise SystemExit(f"Expected {mlmodelc} after compile — got nothing")

    zip_path = out_dir / f"{mlpackage.stem}.mlmodelc.zip"
    if zip_path.exists():
        zip_path.unlink()
    print(f"[{mlpackage.name}] Zipping → {zip_path.name}")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for item in sorted(mlmodelc.rglob("*")):
            zf.write(item, item.relative_to(out_dir))

    size_mb = zip_path.stat().st_size / 1_000_000
    print(f"[{mlpackage.name}] ✔ {zip_path.name} ({size_mb:.1f} MB)")
    return zip_path


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--model", choices=list(MODELS.keys()), help="Convert one model")
    p.add_argument("--all", action="store_true", help="Convert all known models")
    args = p.parse_args(argv)

    if args.all:
        selected = list(MODELS.values())
    elif args.model:
        selected = [MODELS[args.model]]
    else:
        p.error("Specify --model <name> or --all")

    if sys.platform != "darwin":
        print(
            "WARN: xcrun coremlc is macOS-only. "
            "On non-Mac, only the .mlpackage is produced; the .mlmodelc.zip step will fail.",
            file=sys.stderr,
        )

    for spec in selected:
        mlpackage = convert_to_coreml(spec)
        compile_and_zip_coreml(mlpackage)

    print()
    print(f"CoreML artefacts are in: {OUTPUT_DIR}")
    print("For Android TFLite, run: .venv-tflite/bin/python tools/convert_tflite.py --all")
    print()
    print("Upload all .mlmodelc.zip / .tflite.zip files to:")
    print("  https://github.com/nexas105/flutter_nsfw_scaner/releases (tag: models-v1)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
