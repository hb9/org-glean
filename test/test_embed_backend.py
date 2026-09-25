"""Protocol tests for the embedding backend, run against the real subprocess
in fake-embedder mode (ORG_GLEAN_FAKE_EMBED=1).

These spawn the actual org_glean_embed.py process and talk JSON Lines to it
over its real stdin/stdout - the same boundary Emacs will drive. Fake mode
uses only the standard library, so this suite has no third-party
dependencies and needs no installed model. Real-model relevance is a
separate, opt-in suite (see ROADMAP.md phase 1, `make test-model`).
"""

from __future__ import annotations

import base64
import json
import math
import os
import struct
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parents[1] / "semantic" / "org_glean_embed.py"


class Backend:
    """Thin JSON-Lines client driving a real org_glean_embed.py subprocess."""

    def __init__(self, preset="e5-small"):
        env = os.environ.copy()
        env["ORG_GLEAN_FAKE_EMBED"] = "1"
        self.process = subprocess.Popen(
            [sys.executable, str(SCRIPT), preset],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=env, bufsize=1,
        )
        self._next_id = 0

    def call(self, op, **fields):
        self._next_id += 1
        request = {"id": self._next_id, "op": op, **fields}
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        assert self.process.stdout is not None
        line = self.process.stdout.readline()
        if not line:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise RuntimeError(f"backend produced no output; stderr: {stderr}")
        response = json.loads(line)
        assert response["id"] == request["id"]
        return response

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        self.process.wait(timeout=5)


@pytest.fixture()
def backend():
    b = Backend()
    yield b
    b.close()


def decode(vector_b64: str) -> list[float]:
    raw = base64.b64decode(vector_b64)
    n = len(raw) // 4
    return list(struct.unpack(f"<{n}f", raw))


def test_hello_reports_preset_metadata(backend):
    response = backend.call("hello")
    result = response["result"]
    assert result["model_id"] == "intfloat/multilingual-e5-small"
    assert result["dimension"] == 384
    assert result["query_prefix"] == "query: "
    assert result["passage_prefix"] == "passage: "


def test_embed_returns_normalized_vectors_of_expected_dimension(backend):
    response = backend.call("embed", texts=["hello world", "goodbye world"], kind="passage")
    vectors = [decode(v) for v in response["result"]["vectors"]]
    assert len(vectors) == 2
    for vector in vectors:
        assert len(vector) == 384
        norm = math.sqrt(sum(v * v for v in vector))
        assert abs(norm - 1.0) < 1e-4


def test_identical_text_yields_identical_vector(backend):
    response = backend.call("embed", texts=["same text", "same text"], kind="passage")
    a, b = response["result"]["vectors"]
    assert a == b


def test_load_then_search_ranks_by_similarity(backend):
    embedded = backend.call("embed", texts=["apple banana", "apple banana cherry", "car engine oil"],
                            kind="passage")["result"]["vectors"]
    items = [{"digest": f"d{i}", "vector": v} for i, v in enumerate(embedded)]
    loaded = backend.call("load", items=items)
    assert loaded["result"]["loaded"] == 3

    result = backend.call("search", query="apple banana", k=2)["result"]
    ranked = [r["digest"] for r in result["results"]]
    assert ranked[0] == "d0" or ranked[0] == "d1"
    assert "d2" not in ranked[:1]  # the unrelated passage should not rank first
    assert len(result["results"]) == 2


def test_search_respects_digest_restriction(backend):
    embedded = backend.call("embed", texts=["one", "two", "three"], kind="passage")["result"]["vectors"]
    items = [{"digest": f"x{i}", "vector": v} for i, v in enumerate(embedded)]
    backend.call("load", items=items)

    result = backend.call("search", query="one", k=10, digests=["x1", "x2"])["result"]
    ranked = {r["digest"] for r in result["results"]}
    assert ranked <= {"x1", "x2"}
    assert "x0" not in ranked


def test_unload_removes_vector_from_future_searches(backend):
    embedded = backend.call("embed", texts=["alpha"], kind="passage")["result"]["vectors"]
    backend.call("load", items=[{"digest": "only", "vector": embedded[0]}])
    assert backend.call("search", query="alpha", k=10)["result"]["results"]
    backend.call("unload", digests=["only"])
    assert backend.call("search", query="alpha", k=10)["result"]["results"] == []


def test_unknown_op_reports_error_without_crashing_backend(backend):
    response = backend.call("not-a-real-op")
    assert "error" in response
    # The backend must still be alive and usable after a bad request.
    assert backend.call("hello")["result"]["dimension"] == 384


def test_query_and_passage_prefixes_differ(backend):
    query_vec = decode(backend.call("embed", texts=["weld"], kind="query")["result"]["vectors"][0])
    passage_vec = decode(backend.call("embed", texts=["weld"], kind="passage")["result"]["vectors"][0])
    # query: and passage: prefixes are different tokens in the fake bag-of-hashes
    # embedder, so the same body text must not embed identically for both kinds.
    assert query_vec != passage_vec
