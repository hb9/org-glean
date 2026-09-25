#!/usr/bin/env python3
"""Download one model preset's tokenizer and ONNX files into a target directory.

Usage: org_glean_download.py PRESET TARGET_DIR

Run inside the org-glean-managed venv (huggingface_hub is a requirements.txt
dependency; onnxruntime/tokenizers are not needed just to download). This is
the only network-touching step in org-glean-install, and org-glean-install
only calls it after an explicit, one-time user consent prompt naming the
model and its approximate size - never implicitly from ordinary search.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

PRESETS_PATH = Path(__file__).resolve().parent / "presets.json"

# Tokenizer-side files are small and preset-independent; the model file is
# the one whose absence/size matters to a consenting user.
TOKENIZER_FILES = [
    "tokenizer.json",
    "tokenizer_config.json",
    "special_tokens_map.json",
    "sentencepiece.bpe.model",
]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: org_glean_download.py PRESET TARGET_DIR", file=sys.stderr)
        return 2
    preset_name, target_dir = sys.argv[1], Path(sys.argv[2])
    presets = json.loads(PRESETS_PATH.read_text(encoding="utf-8"))
    if preset_name not in presets:
        print(f"unknown preset: {preset_name}", file=sys.stderr)
        return 2
    preset = presets[preset_name]

    from huggingface_hub import hf_hub_download

    target_dir.mkdir(parents=True, exist_ok=True)
    model_id = preset["model_id"]

    for filename in TOKENIZER_FILES:
        try:
            downloaded = hf_hub_download(repo_id=model_id, filename=filename)
        except Exception:
            continue  # not every model ships every tokenizer-side file
        shutil.copy2(downloaded, target_dir / filename)

    onnx_file = preset["onnx_file"]
    downloaded_onnx = hf_hub_download(repo_id=model_id, filename=onnx_file)
    onnx_target = target_dir / onnx_file
    onnx_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(downloaded_onnx, onnx_target)

    if not (target_dir / "tokenizer.json").exists():
        print(f"error: {model_id} has no tokenizer.json; unsupported for now", file=sys.stderr)
        return 1
    print(f"downloaded {model_id} into {target_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
