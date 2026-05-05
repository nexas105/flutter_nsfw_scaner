#!/usr/bin/env python3
"""Convert HuggingFace ViT NSFW classifiers to TFLite for Android.

This script lives in its own dependency stack — it MUST run in
``.venv-tflite`` (not the CoreML venv) because litert-torch pulls jax
which conflicts with tensorflow's LLVM CLI flag registration.

Setup once:
    python3 -m venv .venv-tflite
    .venv-tflite/bin/pip install -r tools/requirements-tflite.txt

Run (per model or all):
    .venv-tflite/bin/python tools/convert_tflite.py --model adamcodd
    .venv-tflite/bin/python tools/convert_tflite.py --model falconsai
    .venv-tflite/bin/python tools/convert_tflite.py --all

Pipeline per model:
    1. Load HF PyTorch checkpoint
    2. Wrap in WrappedViT (bakes (2x - 1) normalisation + softmax into graph)
    3. Convert PyTorch → TFLite via litert-torch (FP32, ~330 MB)
    4. Post-quantise to INT8 weight-only via ai-edge-quantizer (~85 MB)
    5. Zip → models_cache/converted/<Name>NSFW.tflite.zip

Upload the zips to:
    https://github.com/nexas105/flutter_nsfw_scaner/releases (tag: models-v1)

The Kotlin TFLiteEngine passes raw [0, 1] float pixels and reads back
[0, 1] probabilities directly — no Kotlin-side normalisation or softmax
needed.
"""

from __future__ import annotations

import argparse
import os
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

# Quiet TF + jax initial chatter (cosmetic).
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
os.environ.setdefault("JAX_PLATFORMS", "cpu")

import torch  # noqa: E402
from transformers import AutoModelForImageClassification  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = REPO_ROOT / "models_cache"
OUTPUT_DIR = CACHE_DIR / "converted"


@dataclass(frozen=True)
class ModelSpec:
    key: str
    hf_id: str
    local_dir: str
    output_name: str
    input_size: int


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


class WrappedViT(torch.nn.Module):
    """Bakes ViT normalisation (2x - 1) and softmax into the graph.

    Lets the Android Kotlin runtime stay simple: pass [0, 1] floats
    (already what `pixel / 255f` produces) and read [0, 1] probabilities
    straight out — symmetric to iOS where Vision + ClassifierConfig
    handle the same job automatically.
    """

    def __init__(self, m: torch.nn.Module) -> None:
        super().__init__()
        self.m = m

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x * 2.0 - 1.0
        logits = self.m(pixel_values=x).logits
        return torch.softmax(logits, dim=-1)


def convert_one(spec: ModelSpec) -> Path:
    src = CACHE_DIR / spec.local_dir
    if not src.exists():
        raise SystemExit(
            f"Source not found: {src}\n"
            f"Run: hf download {spec.hf_id} --local-dir {src}"
        )

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    tflite_path = OUTPUT_DIR / f"{spec.output_name}.tflite"

    # ── 1. Load + wrap ─────────────────────────────────────────────
    print(f"[{spec.output_name}] Loading PyTorch model from {src}", flush=True)
    model = AutoModelForImageClassification.from_pretrained(src).eval()
    wrapped = WrappedViT(model).eval()
    example = torch.zeros(1, 3, spec.input_size, spec.input_size, dtype=torch.float32)

    # ── 2. Convert PyTorch → TFLite (FP32) via litert-torch ────────
    print(f"[{spec.output_name}] Converting PyTorch → TFLite (FP32)", flush=True)
    try:
        import litert_torch as _ledge  # type: ignore[import-not-found]
    except ImportError:
        import ai_edge_torch as _ledge  # type: ignore[import-not-found]
    edge_model = _ledge.convert(wrapped, (example,))
    edge_model.export(str(tflite_path))
    fp32_mb = tflite_path.stat().st_size / 1_000_000
    print(f"[{spec.output_name}]   FP32 size: {fp32_mb:.1f} MB", flush=True)

    # ── 3. Post-quantise to INT8 weight-only ───────────────────────
    print(f"[{spec.output_name}] Quantising → INT8 weight-only", flush=True)
    from ai_edge_quantizer import Quantizer, recipe
    q = Quantizer(float_model=str(tflite_path))
    q.load_quantization_recipe(recipe.weight_only_wi8_afp32())
    q_result = q.quantize()
    int8_path = OUTPUT_DIR / f"{spec.output_name}.int8.tflite"
    q_result.export_model(str(int8_path), overwrite=True)
    os.replace(int8_path, tflite_path)
    int8_mb = tflite_path.stat().st_size / 1_000_000
    print(f"[{spec.output_name}]   INT8 size: {int8_mb:.1f} MB ({int8_mb/fp32_mb:.1%})", flush=True)

    # ── 4. Zip ─────────────────────────────────────────────────────
    zip_path = OUTPUT_DIR / f"{spec.output_name}.tflite.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.write(tflite_path, tflite_path.name)
    zip_mb = zip_path.stat().st_size / 1_000_000
    print(f"[{spec.output_name}] ✔ {zip_path.name} ({zip_mb:.1f} MB)", flush=True)
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

    for spec in selected:
        convert_one(spec)

    print()
    print(f"Output directory: {OUTPUT_DIR}")
    print("Upload the .tflite.zip files to:")
    print("  https://github.com/nexas105/flutter_nsfw_scaner/releases (tag: models-v1)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
