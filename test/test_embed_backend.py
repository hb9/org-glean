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


def test_search_result_carries_score_cosine_and_z(backend):
    embedded = backend.call("embed", texts=["apple banana cherry"], kind="passage")["result"]["vectors"]
    backend.call("load", items=[{"digest": "d0", "vector": embedded[0]}])
    result = backend.call("search", query="apple banana", k=1)["result"]["results"][0]
    assert set(result) == {"digest", "score", "cosine", "z"}
    # A single-candidate pool has zero spread, so z is defined as 0 rather
    # than a division-by-zero error.
    assert result["z"] == 0.0


def test_min_z_filters_out_below_threshold_candidates(backend):
    # Five distinct-but-related passages plus one that shares no tokens
    # with the query at all: the outlier's z, relative to the other five,
    # should be clearly negative, and a high min_z should exclude it while
    # an absent min_z keeps it. min_pool_for_z is lowered to below this
    # pool's size (6) so the filter itself is under test here, not the
    # separate small-pool guard covered by
    # test_min_z_is_not_applied_below_min_pool_for_z.
    passages = [
        "apple banana cherry",
        "apple banana date",
        "apple banana fig",
        "apple banana grape",
        "apple banana kiwi",
        "zzz completely unrelated qqq",
    ]
    embedded = backend.call("embed", texts=passages, kind="passage")["result"]["vectors"]
    items = [{"digest": f"d{i}", "vector": v} for i, v in enumerate(embedded)]
    backend.call("load", items=items)

    unfiltered = backend.call("search", query="apple banana", k=10)["result"]["results"]
    assert len(unfiltered) == 6

    filtered = backend.call("search", query="apple banana", k=10, min_z=0.5,
                            min_pool_for_z=2)["result"]["results"]
    digests = {r["digest"] for r in filtered}
    assert "d5" not in digests
    assert digests <= {"d0", "d1", "d2", "d3", "d4"}


def test_min_z_is_not_applied_below_min_pool_for_z(backend):
    # A z-score threshold is not statistically meaningful with only a
    # handful of candidates: with the default min_pool_for_z (10), a
    # 6-candidate pool must get its min_z ignored entirely rather than
    # silently returning nothing just because the pool was too small for
    # any z to reach the threshold.
    passages = [
        "apple banana cherry", "apple banana date", "apple banana fig",
        "apple banana grape", "apple banana kiwi",
        "zzz completely unrelated qqq",
    ]
    embedded = backend.call("embed", texts=passages, kind="passage")["result"]["vectors"]
    items = [{"digest": f"d{i}", "vector": v} for i, v in enumerate(embedded)]
    backend.call("load", items=items)

    # An unreasonably high min_z would normally exclude everything; with
    # too few candidates for the guard's floor, it must be ignored instead.
    result = backend.call("search", query="apple banana", k=10, min_z=100.0)["result"]
    assert len(result["results"]) == 6


def test_hub_correction_subtracts_more_from_a_broadly_similar_passage(backend):
    # d_hub shares some vocabulary with every one of five distinct "topic"
    # passages (a stand-in for a chunk like a link dump or sitemap that
    # partially overlaps everything); d_isolated shares nothing with any
    # of them. Both are then scored against a query that touches all of
    # them equally. The hub-like passage's mean similarity to its nearest
    # neighbours must be higher than the isolated passage's, so the hub
    # correction subtracts noticeably more from its score than from the
    # isolated passage's - which is the property that demotes real hub
    # chunks without needing to hand-tune a specific end-to-end ranking.
    topics = [
        "cats meow whiskers purr feline",
        "dogs bark tail fetch canine",
        "cars engine wheels drive vehicle",
        "trees leaves branches roots forest",
        "music guitar piano melody song",
    ]
    hub_passage = "keyword cats dogs cars trees music portal directory index"
    isolated_passage = "keyword niche distinctive specialized narrow uncommon"
    passages = topics + [hub_passage, isolated_passage]
    embedded = backend.call("embed", texts=passages, kind="passage")["result"]["vectors"]
    items = [{"digest": f"topic{i}", "vector": v} for i, v in enumerate(embedded[:5])]
    items.append({"digest": "hub", "vector": embedded[5]})
    items.append({"digest": "isolated", "vector": embedded[6]})
    backend.call("load", items=items)

    with_hub = {r["digest"]: r for r in
                backend.call("search", query="keyword", k=10, hub_lambda=0.5)["result"]["results"]}
    without_hub = {r["digest"]: r for r in
                   backend.call("search", query="keyword", k=10, hub_lambda=0.0)["result"]["results"]}

    hub_penalty = without_hub["hub"]["cosine"] - with_hub["hub"]["score"]
    isolated_penalty = without_hub["isolated"]["cosine"] - with_hub["isolated"]["score"]
    assert hub_penalty > isolated_penalty


def test_search_on_empty_backend_returns_no_results(backend):
    assert backend.call("search", query="anything", k=10)["result"]["results"] == []


def test_search_min_z_with_no_candidates_in_digest_filter_is_empty(backend):
    embedded = backend.call("embed", texts=["alpha"], kind="passage")["result"]["vectors"]
    backend.call("load", items=[{"digest": "only", "vector": embedded[0]}])
    result = backend.call("search", query="alpha", k=10, digests=["not-loaded"])["result"]
    assert result["results"] == []


def test_min_z_is_applied_once_pool_meets_min_pool_for_z(backend):
    # The mirror image of test_min_z_is_not_applied_below_min_pool_for_z:
    # once the pool reaches the floor, an unreasonably high min_z must
    # filter down to nothing, same as it would with no guard at all.
    passages = [f"apple banana topic{i}" for i in range(9)] + ["zzz unrelated qqq"]
    embedded = backend.call("embed", texts=passages, kind="passage")["result"]["vectors"]
    items = [{"digest": f"d{i}", "vector": v} for i, v in enumerate(embedded)]
    backend.call("load", items=items)

    result = backend.call("search", query="apple banana", k=20, min_z=100.0)["result"]
    assert result["results"] == []

