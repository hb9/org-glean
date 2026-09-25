"""Unit tests for org_glean_download.py's file-copy idempotency.

Only exercises the pure, network-free _copy_overwriting helper (and the CA
bundle helper), not the actual huggingface_hub download - that would need
network access. This is the regression test for a real bug: re-running
org-glean-install after a first, successful download previously crashed
with PermissionError because hf_hub_download's cache copies preserve the
upstream file's (typically read-only) permissions, and shutil.copy2 opens
the destination for writing.
"""

from __future__ import annotations

import importlib.util
import os
import stat
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "semantic" / "org_glean_download.py"
SPEC = importlib.util.spec_from_file_location("org_glean_download", SCRIPT)
assert SPEC and SPEC.loader
download = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(download)


def test_copy_overwriting_replaces_a_readonly_destination(tmp_path):
    src = tmp_path / "src.bin"
    dst = tmp_path / "dst.bin"
    src.write_bytes(b"first content")
    dst.write_bytes(b"stale content")
    dst.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)  # read-only, like HF cache copies

    download._copy_overwriting(src, dst)

    assert dst.read_bytes() == b"first content"


def test_copy_overwriting_works_when_destination_is_absent(tmp_path):
    src = tmp_path / "src.bin"
    dst = tmp_path / "subdir" / "dst.bin"
    dst.parent.mkdir()
    src.write_bytes(b"content")

    download._copy_overwriting(src, dst)

    assert dst.read_bytes() == b"content"


def test_ensure_system_ca_bundle_respects_existing_ssl_cert_file(monkeypatch):
    monkeypatch.setenv("SSL_CERT_FILE", "/some/explicit/bundle.pem")
    download._ensure_system_ca_bundle_is_trusted()
    assert os.environ["SSL_CERT_FILE"] == "/some/explicit/bundle.pem"


def test_ensure_system_ca_bundle_sets_os_default_when_unset(monkeypatch):
    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    download._ensure_system_ca_bundle_is_trusted()
    # Either it found and set a real OS-reported CA file, or there genuinely
    # isn't one on this system - either way it must not have crashed, and
    # must not fabricate a nonexistent path.
    if "SSL_CERT_FILE" in os.environ:
        assert Path(os.environ["SSL_CERT_FILE"]).exists()
