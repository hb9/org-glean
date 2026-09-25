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
import os
import shutil
import ssl
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


def _ensure_system_ca_bundle_is_trusted() -> None:
    """Make huggingface_hub's HTTP client trust the OS CA bundle.

    huggingface_hub (via httpx) verifies TLS against the bundled `certifi`
    root list by default rather than the OS trust store, unlike `curl` and
    a plain `ssl.create_default_context()`. On a machine where outbound
    HTTPS is intercepted by a corporate or sandbox proxy - common in CI and
    dev-container setups - the proxy's root certificate is only in the OS
    store, so certifi-only verification fails with CERTIFICATE_VERIFY_FAILED
    even though the connection is otherwise fine. Respect any CA bundle the
    user has already configured (SSL_CERT_FILE); only fall back to the
    OS-reported default when nothing is set.
    """
    if os.environ.get("SSL_CERT_FILE"):
        return
    cafile = ssl.get_default_verify_paths().cafile
    if cafile and Path(cafile).exists():
        os.environ["SSL_CERT_FILE"] = cafile


def _copy_overwriting(src: Path, dst: Path) -> None:
    """Copy SRC to DST, overwriting DST even if a previous run left it
    read-only. hf_hub_download's cache copies preserve the upstream file's
    permissions, which are typically read-only; shutil.copy2 opens DST for
    writing and fails on a stale read-only file from an earlier attempt
    (e.g. one that got this far and then failed on a later step), so this
    makes re-running org-glean-install after a partial failure idempotent
    instead of requiring the user to manually clear the model directory."""
    if dst.exists():
        dst.unlink()
    shutil.copy2(src, dst)


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

    _ensure_system_ca_bundle_is_trusted()
    from huggingface_hub import hf_hub_download

    target_dir.mkdir(parents=True, exist_ok=True)
    model_id = preset["model_id"]

    for filename in TOKENIZER_FILES:
        try:
            downloaded = hf_hub_download(repo_id=model_id, filename=filename)
        except Exception:
            continue  # not every model ships every tokenizer-side file
        _copy_overwriting(Path(downloaded), target_dir / filename)

    onnx_file = preset["onnx_file"]
    downloaded_onnx = hf_hub_download(repo_id=model_id, filename=onnx_file)
    onnx_target = target_dir / onnx_file
    onnx_target.parent.mkdir(parents=True, exist_ok=True)
    _copy_overwriting(Path(downloaded_onnx), onnx_target)

    if not (target_dir / "tokenizer.json").exists():
        print(f"error: {model_id} has no tokenizer.json; unsupported for now", file=sys.stderr)
        return 1
    print(f"downloaded {model_id} into {target_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
