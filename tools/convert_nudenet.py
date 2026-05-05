#!/usr/bin/env python3
"""Convert NudeNet (notAI-tech/NudeNet) → CoreML + TFLite for the plugin.

NudeNet 640m is an ultralytics YOLOv8m-based body-part detector with
18 classes. We use ultralytics' own `model.export()` because:

  - CoreML: produces a Vision-compatible pipeline with built-in NMS,
    `image` input + `confidence`/`coordinates` outputs that
    `VNCoreMLRequest` wraps directly into `VNRecognizedObjectObservation`.
  - TFLite: produces raw YOLOv8 output `[1, 22, A]` (4 bbox + 18 classes
    × A anchors). The Android `TFLiteDetectorEngine` does NMS in Kotlin.

We don't try ONNX → coremltools (8.x removed direct ONNX support) and
we don't try ONNX → onnx2tf for TFLite (NHWC heuristic miscompiles
some NMS sub-graphs). The ultralytics path is the canonical export
recommended by the upstream maintainer.

Setup once:
    .venv/bin/pip install ultralytics coremltools

Source download (LFS, ~50 MB):
    mkdir -p models_cache/NudeNet
    gh release download v3.4-weights -R notAI-tech/NudeNet \\
        -p '640m.pt' -D models_cache/NudeNet

Run:
    .venv/bin/python tools/convert_nudenet.py

Output:
    models_cache/converted/NudeNetDetector.mlmodelc.zip   (iOS, ~46 MB)
    models_cache/converted/NudeNetDetector.tflite.zip     (Android, ~46 MB)

Upload both to:
    https://github.com/nexas105/flutter_nsfw_scaner/releases (tag: models-v1)
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = REPO_ROOT / "models_cache"
SRC_DIR = CACHE_DIR / "NudeNet"
OUTPUT_DIR = CACHE_DIR / "converted"
OUTPUT_NAME = "NudeNetDetector"
INPUT_SIZE = 640
SOURCE_PT = SRC_DIR / "640m.pt"


def _check_source() -> None:
    if not SOURCE_PT.exists():
        raise SystemExit(
            f"Source not found: {SOURCE_PT}\n"
            f"Run: gh release download v3.4-weights -R notAI-tech/NudeNet "
            f"-p '640m.pt' -D {SRC_DIR}"
        )


# ─────────────────────────────────────────────────────────────────────
# CoreML (iOS) — ultralytics export with NMS = Vision-compatible
# ─────────────────────────────────────────────────────────────────────


def convert_to_coreml() -> Path:
    from ultralytics import YOLO

    print(f"[NudeNet] Loading {SOURCE_PT}")
    yolo = YOLO(str(SOURCE_PT))

    print(f"[NudeNet] Exporting → CoreML (NMS=on, FP16, imgsz={INPUT_SIZE})")
    # ultralytics writes the .mlpackage next to the source .pt
    out_path = yolo.export(format="coreml", nms=True, imgsz=INPUT_SIZE, half=True)
    mlpackage = Path(out_path)
    if not mlpackage.exists():
        raise SystemExit(f"ultralytics returned {mlpackage} but file is missing")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"[NudeNet] Compiling → .mlmodelc via xcrun coremlc")
    proc = subprocess.run(
        ["xcrun", "coremlc", "compile", str(mlpackage), str(OUTPUT_DIR)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"coremlc failed:\n{proc.stderr}")

    # ultralytics names the output by the .pt stem ("640m.mlmodelc")
    src_mlmodelc = OUTPUT_DIR / f"{mlpackage.stem}.mlmodelc"
    dst_mlmodelc = OUTPUT_DIR / f"{OUTPUT_NAME}.mlmodelc"
    if dst_mlmodelc.exists():
        shutil.rmtree(dst_mlmodelc)
    shutil.move(str(src_mlmodelc), str(dst_mlmodelc))

    zip_path = OUTPUT_DIR / f"{OUTPUT_NAME}.mlmodelc.zip"
    if zip_path.exists():
        zip_path.unlink()
    print(f"[NudeNet] Zipping → {zip_path.name}")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for item in sorted(dst_mlmodelc.rglob("*")):
            zf.write(item, item.relative_to(OUTPUT_DIR))

    size_mb = zip_path.stat().st_size / 1_000_000
    print(f"[NudeNet] ✔ {zip_path.name} ({size_mb:.1f} MB)")
    return zip_path


# ─────────────────────────────────────────────────────────────────────
# TFLite (Android) — ultralytics raw export, FP16, no NMS
# ─────────────────────────────────────────────────────────────────────


def convert_to_tflite() -> Path:
    from ultralytics import YOLO

    yolo = YOLO(str(SOURCE_PT))
    print(f"[NudeNet] Exporting → TFLite (FP16, imgsz={INPUT_SIZE}, no NMS — Kotlin handles it)")
    out_path = yolo.export(format="tflite", imgsz=INPUT_SIZE, half=True)
    src_tflite = Path(out_path)
    if not src_tflite.exists():
        raise SystemExit(f"ultralytics returned {src_tflite} but file is missing")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    dst_tflite = OUTPUT_DIR / f"{OUTPUT_NAME}.tflite"
    shutil.copy2(src_tflite, dst_tflite)

    zip_path = OUTPUT_DIR / f"{OUTPUT_NAME}.tflite.zip"
    if zip_path.exists():
        zip_path.unlink()
    print(f"[NudeNet] Zipping → {zip_path.name}")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.write(dst_tflite, dst_tflite.name)
    size_mb = zip_path.stat().st_size / 1_000_000
    print(f"[NudeNet] ✔ {zip_path.name} ({size_mb:.1f} MB)")
    return zip_path


# ─────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    fmt = p.add_mutually_exclusive_group()
    fmt.add_argument("--coreml-only", action="store_true", help="Only iOS output")
    fmt.add_argument("--tflite-only", action="store_true", help="Only Android output")
    args = p.parse_args(argv)

    _check_source()

    if not args.tflite_only:
        if sys.platform != "darwin":
            print(
                "WARN: CoreML compile (xcrun coremlc) is macOS-only; "
                "skip with --tflite-only on non-Mac.",
                file=sys.stderr,
            )
        convert_to_coreml()

    if not args.coreml_only:
        convert_to_tflite()

    print()
    print(f"NudeNet artefacts in: {OUTPUT_DIR}")
    print("Upload to:")
    print("  https://github.com/nexas105/flutter_nsfw_scaner/releases (tag: models-v1)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
