#!/usr/bin/env python3
"""Convert HuggingFace NSFW classifiers to on-device formats.

Reads PyTorch checkpoints from models_cache/<repo>/ (downloaded via
`hf download <hf-id> --local-dir models_cache/<repo>/`) and produces
both CoreML (iOS) and TFLite (Android) artefacts ready for upload to
GitHub Releases.

Output:
    models_cache/converted/AdamCoddNSFW.mlmodelc.zip       (iOS)
    models_cache/converted/FalconsaiNSFW.mlmodelc.zip      (iOS)
    models_cache/converted/AdamCoddNSFW.tflite.zip         (Android)
    models_cache/converted/FalconsaiNSFW.tflite.zip        (Android)

Upload destination:
    https://github.com/nexas105/flutter_nsfw_scaner/releases  (tag: models-v1)

PREPROCESSING — baked into both formats so the on-device code stays simple:

  CoreML: ImageType(scale=1/127.5, bias=-1) — Vision framework applies it
          to the CVPixelBuffer before the model sees it. Plus
          ClassifierConfig adds softmax + class labels automatically.

  TFLite: A WrappedViT module wraps normalisation `(2x - 1)` and softmax
          INSIDE the graph, so the Android TFLiteEngine can pass raw
          [0, 1] floats (which it already does) and receive [0, 1]
          probabilities directly — symmetric to iOS.

Both yield equivalent output ranges and label semantics on iOS and Android.

Usage:
    python -m venv .venv && source .venv/bin/activate
    pip install -r tools/requirements.txt

    python tools/convert_models.py --all                  # both formats, both models
    python tools/convert_models.py --model adamcodd       # both formats, one model
    python tools/convert_models.py --all --coreml-only    # only iOS artefacts
    python tools/convert_models.py --all --tflite-only    # only Android artefacts
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


# ─────────────────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────────────────


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
    """Trace HF model to TorchScript with logits-only output (for CoreML)."""
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


def _build_wrapped_for_tflite(spec: ModelSpec, model):
    """Build a torch.nn.Module that takes [0, 1] floats and returns softmax probs.

    Bakes ViT normalisation `(2x - 1)` + softmax into the graph so the Android
    runtime can pass [0, 1] floats and receive probabilities — symmetric to
    what CoreML's Vision + ClassifierConfig do automatically on iOS.
    """
    import torch

    class WrappedViT(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, x):
            # x: [B, 3, H, W] in [0, 1] (matches Kotlin's `pixel / 255f`).
            x = x * 2.0 - 1.0  # → [-1, 1] (mean=0.5, std=0.5)
            logits = self.m(pixel_values=x).logits
            return torch.softmax(logits, dim=-1)

    return WrappedViT(model).eval()


# ─────────────────────────────────────────────────────────────────────
# CoreML path (iOS)
# ─────────────────────────────────────────────────────────────────────


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


# ─────────────────────────────────────────────────────────────────────
# TFLite path (Android)
# ─────────────────────────────────────────────────────────────────────


def convert_to_tflite(spec: ModelSpec, prefer_onnx2tf: bool = False) -> Path:
    """PyTorch (with baked normalisation + softmax) → TFLite (FP16).

    Tries ai-edge-torch first (Google's official PyTorch→TFLite path),
    falls back to ONNX → onnx2tf if that fails or `prefer_onnx2tf=True`.
    """
    import torch

    model, _class_labels = _load_hf_model(spec)
    wrapped = _build_wrapped_for_tflite(spec, model)
    size = spec.input_size
    example = torch.zeros(1, 3, size, size, dtype=torch.float32)  # [0, 1] range

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    tflite_path = OUTPUT_DIR / f"{spec.output_name}.tflite"
    if tflite_path.exists():
        tflite_path.unlink()

    if not prefer_onnx2tf:
        try:
            _convert_via_ai_edge_torch(spec, wrapped, example, tflite_path)
        except Exception as e:
            print(
                f"[{spec.output_name}] ai-edge-torch failed: {e}\n"
                f"[{spec.output_name}] Falling back to ONNX → onnx2tf path",
                file=sys.stderr,
            )
            _convert_via_onnx2tf(spec, wrapped, example, tflite_path)
    else:
        _convert_via_onnx2tf(spec, wrapped, example, tflite_path)

    if not tflite_path.exists():
        raise SystemExit(f"TFLite conversion produced no output at {tflite_path}")

    return _zip_tflite(tflite_path)


def _convert_via_ai_edge_torch(spec: ModelSpec, wrapped, example, tflite_path: Path) -> None:
    """Primary path: ai_edge_torch.convert(...). FP16 via converter flags."""
    import ai_edge_torch
    import tensorflow as tf

    print(f"[{spec.output_name}] Converting → TFLite via ai-edge-torch (FP16)")
    edge_model = ai_edge_torch.convert(
        wrapped,
        (example,),
        _ai_edge_converter_flags={
            "optimizations": [tf.lite.Optimize.DEFAULT],
            "target_spec.supported_types": [tf.float16],
        },
    )
    edge_model.export(str(tflite_path))
    print(f"[{spec.output_name}] Wrote {tflite_path}")


def _convert_via_onnx2tf(spec: ModelSpec, wrapped, example, tflite_path: Path) -> None:
    """Fallback path: PyTorch → ONNX → onnx2tf → TFLite."""
    import torch
    import onnx2tf

    onnx_path = OUTPUT_DIR / f"{spec.output_name}.onnx"
    work_dir = OUTPUT_DIR / f"{spec.output_name}_tflite_work"
    if work_dir.exists():
        shutil.rmtree(work_dir)

    print(f"[{spec.output_name}] Exporting → ONNX (opset 17)")
    torch.onnx.export(
        wrapped,
        example,
        str(onnx_path),
        input_names=["image"],
        output_names=["probs"],
        dynamic_axes=None,
        opset_version=17,
        do_constant_folding=True,
    )

    print(f"[{spec.output_name}] Converting → TFLite via onnx2tf (FP16)")
    onnx2tf.convert(
        input_onnx_file_path=str(onnx_path),
        output_folder_path=str(work_dir),
        output_signaturedefs=True,
        non_verbose=True,
        # FP16 quantisation
        output_h5=False,
        output_keras_v3=False,
    )

    # onnx2tf produces multiple variants; pick the FP16 one if available.
    candidates = sorted(work_dir.glob("*float16*.tflite")) + sorted(work_dir.glob("*.tflite"))
    if not candidates:
        raise SystemExit(f"onnx2tf produced no .tflite in {work_dir}")
    shutil.copy2(candidates[0], tflite_path)
    print(f"[{spec.output_name}] Wrote {tflite_path} (from {candidates[0].name})")


def _zip_tflite(tflite_path: Path) -> Path:
    zip_path = tflite_path.with_suffix(".tflite.zip")
    if zip_path.exists():
        zip_path.unlink()
    print(f"[{tflite_path.name}] Zipping → {zip_path.name}")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.write(tflite_path, tflite_path.name)
    size_mb = zip_path.stat().st_size / 1_000_000
    print(f"[{tflite_path.name}] ✔ {zip_path.name} ({size_mb:.1f} MB)")
    return zip_path


# ─────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--model", choices=list(MODELS.keys()), help="Convert one model")
    p.add_argument("--all", action="store_true", help="Convert all known models")

    fmt = p.add_mutually_exclusive_group()
    fmt.add_argument("--coreml-only", action="store_true", help="Only iOS CoreML output")
    fmt.add_argument("--tflite-only", action="store_true", help="Only Android TFLite output")

    p.add_argument(
        "--use-onnx2tf",
        action="store_true",
        help="Force ONNX→TFLite path (skips ai-edge-torch). Useful if ai-edge-torch stumbles on transformer ops.",
    )
    args = p.parse_args(argv)

    if args.all:
        selected = list(MODELS.values())
    elif args.model:
        selected = [MODELS[args.model]]
    else:
        p.error("Specify --model <name> or --all")

    do_coreml = not args.tflite_only
    do_tflite = not args.coreml_only

    if do_coreml and sys.platform != "darwin":
        print(
            "WARN: CoreML compile (xcrun coremlc) is macOS-only. "
            "Use --tflite-only on non-Mac.",
            file=sys.stderr,
        )

    for spec in selected:
        if do_coreml:
            mlpackage = convert_to_coreml(spec)
            compile_and_zip_coreml(mlpackage)
        if do_tflite:
            convert_to_tflite(spec, prefer_onnx2tf=args.use_onnx2tf)

    print()
    print(f"All converted artefacts are in: {OUTPUT_DIR}")
    print("Upload them to:")
    print("  https://github.com/nexas105/flutter_nsfw_scaner/releases (tag: models-v1)")
    print()
    print("Filenames must match the URLs in:")
    print("  ios/Classes/ml/ModelRegistry.swift                 (iOS)")
    print("  android/src/main/kotlin/.../ml/ModelRegistry.kt    (Android)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
