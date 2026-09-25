"""Direct-import tests for the numpy-accelerated hub-neighbour computation
in org_glean_embed.Backend, specifically that computing it in row-blocks
(DEFAULT_HUB_BLOCK_SIZE / hub_block_size) gives identical results to
computing the full n x n similarity matrix at once.

These import the module directly rather than going through the JSON-Lines
subprocess protocol other tests use (see test_embed_backend.py), because
the fake embedder always takes the pure-Python fallback path for hub
scoring - numpy is only ever reached via the real OnnxEmbedder, which
needs a downloaded model. Here, a fake-mode Backend's vectors are used
directly with `backend._np` monkeypatched to real numpy after
construction, which exercises the exact same code path a real installed
model would use, without needing one.

Skipped entirely if numpy is not installed in whatever environment runs
pytest - this is deliberately optional. Fake-mode tests being importable
and runnable with only the standard library (see test_embed_backend.py's
own docstring) is the property that must hold regardless; this file tests
an accelerator path, not that guarantee.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

numpy = pytest.importorskip("numpy")

SCRIPT = Path(__file__).parents[1] / "semantic" / "org_glean_embed.py"
_spec = importlib.util.spec_from_file_location("org_glean_embed", SCRIPT)
org_glean_embed = importlib.util.module_from_spec(_spec)
sys.modules.setdefault("org_glean_embed", org_glean_embed)
_spec.loader.exec_module(org_glean_embed)


def _make_backend(hub_block_size: int) -> "org_glean_embed.Backend":
    """A fake-mode Backend with its embedder swapped for real numpy, so the
    numpy branch of _centered_matrix runs against FakeEmbedder-produced
    vectors without needing a real downloaded model."""
    presets = org_glean_embed.load_presets()
    backend = org_glean_embed.Backend(
        "e5-small", presets, None, fake=True, hub_block_size=hub_block_size,
    )
    backend._np = numpy
    return backend


def _load_fixed_vectors(backend, count: int) -> list[str]:
    """Load COUNT distinct fake-embedded passages and return their digests."""
    texts = [f"topic{i} shared word{i % 3} extra{i * 7 % 5}" for i in range(count)]
    embedded = backend.embed(texts, "passage")["vectors"]
    digests = [f"d{i}" for i in range(count)]
    backend.load([{"digest": d, "vector": v} for d, v in zip(digests, embedded)])
    return digests


def test_blocked_hub_matches_single_block_for_various_block_sizes():
    reference = _make_backend(hub_block_size=10_000)
    digests = _load_fixed_vectors(reference, count=23)
    _, _, _, reference_hub = reference._centered_matrix()

    for block_size in (1, 2, 3, 7, 23, 1000):
        candidate = _make_backend(hub_block_size=block_size)
        candidate.vectors = dict(reference.vectors)
        candidate._matrix_cache = None
        candidate_digests, _, _, candidate_hub = candidate._centered_matrix()
        assert candidate_digests == digests
        assert candidate_hub == pytest.approx(reference_hub, abs=1e-5), (
            f"hub scores differ at block_size={block_size}"
        )


def test_blocked_hub_matches_pure_python_fallback():
    numpy_backend = _make_backend(hub_block_size=4)
    digests = _load_fixed_vectors(numpy_backend, count=11)
    _, _, _, numpy_hub = numpy_backend._centered_matrix()

    pure_python_backend = _make_backend(hub_block_size=4)
    pure_python_backend._np = None
    pure_python_backend.vectors = dict(numpy_backend.vectors)
    pure_python_backend._matrix_cache = None
    pure_python_digests, _, _, pure_python_hub = pure_python_backend._centered_matrix()

    assert pure_python_digests == digests
    assert numpy_hub == pytest.approx(pure_python_hub, abs=1e-4)


def test_search_results_are_identical_regardless_of_block_size():
    """The end-to-end search() output - not just the internal hub array -
    must not depend on hub_block_size; it is purely a memory/performance
    knob.

    Compares per-digest scores rather than result ORDER: float32 matmul
    accumulation is not perfectly associative, so different block sizes
    can (and did, before this was written this way) produce ULP-level
    differences that flip the order of two nearly-tied candidates without
    either computation being wrong - the exact-hub-array comparison above
    is the real correctness proof; this test only additionally confirms
    that runs through search() end-to-end for every digest still. Uses
    fully distinct per-index vocabulary (no shared tokens across indices)
    so the fake bag-of-hash embedder produces no *exact* ties, only the
    near-ties floating point arithmetic can't avoid."""
    small_blocks = _make_backend(hub_block_size=2)
    words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf",
             "hotel", "india", "juliet", "kilo", "lima", "mike", "november",
             "oscar", "papa", "quebec"]
    texts = [f"{word} unique{i} distinct{i}" for i, word in enumerate(words)]
    embedded = small_blocks.embed(texts, "passage")["vectors"]
    digests = [f"d{i}" for i in range(len(words))]
    small_blocks.load([{"digest": d, "vector": v} for d, v in zip(digests, embedded)])
    large_blocks = _make_backend(hub_block_size=10_000)
    large_blocks.vectors = dict(small_blocks.vectors)

    query = "golf hotel india"
    small_result = small_blocks.search(query, k=len(words), digests=None, min_z=None,
                                       hub_lambda=0.5, min_pool_for_z=1)
    large_result = large_blocks.search(query, k=len(words), digests=None, min_z=None,
                                       hub_lambda=0.5, min_pool_for_z=1)
    small_by_digest = {r["digest"]: r for r in small_result["results"]}
    large_by_digest = {r["digest"]: r for r in large_result["results"]}
    assert set(small_by_digest) == set(large_by_digest) == set(digests)
    for digest in digests:
        assert small_by_digest[digest]["score"] == pytest.approx(
            large_by_digest[digest]["score"], abs=1e-4
        ), f"score differs for {digest}"
        assert small_by_digest[digest]["z"] == pytest.approx(
            large_by_digest[digest]["z"], abs=1e-3
        ), f"z differs for {digest}"
    # The single clearest, highest-margin result must still agree exactly -
    # this is the one rank the fake-tie sensitivity above cannot plausibly
    # explain away.
    assert small_result["results"][0]["digest"] == large_result["results"][0]["digest"]
