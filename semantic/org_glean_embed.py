#!/usr/bin/env python3
"""Stateless embedding backend for Org Glean, speaking JSON Lines over stdio.

Protocol (one JSON object per line in, one per line out, correlated by "id"):

    {"id": 1, "op": "hello"}
    -> {"id": 1, "result": {"model_id", "dimension", "max_tokens",
                             "query_prefix", "passage_prefix"}}

    {"id": 2, "op": "embed", "texts": [...], "kind": "query"|"passage"}
    -> {"id": 2, "result": {"vectors": [BASE64-FLOAT32, ...], "truncated": N}}

    {"id": 3, "op": "load", "items": [{"digest": "...", "vector": BASE64}]}
    -> {"id": 3, "result": {"loaded": N}}

    {"id": 4, "op": "unload", "digests": ["..."]}
    -> {"id": 4, "result": {"unloaded": N}}

    {"id": 5, "op": "search", "query": "...", "k": 10, "digests": [...]?,
     "min_z": 3.0?, "hub_lambda": 0.5?}
    -> {"id": 5, "result": {"results": [{"digest": "...", "score": 0.02,
                                          "cosine": 0.84, "z": 5.8}, ...]}}

Any failure is returned as {"id": ..., "error": {"type": "...", "message": "..."}}
rather than crashing the process, so one bad request does not take down a
warm backend holding thousands of loaded vectors.

This module is deliberately import-light at module scope: the fake-embedder
path (ORG_GLEAN_FAKE_EMBED=1) uses only the standard library, so the fast
protocol/fusion test suite never needs onnxruntime/tokenizers/numpy
installed. Those are imported lazily, only when a real preset is actually
used to embed text. See ROADMAP.md phase 1 and DESIGN.md for the rationale:
Emacs holds no model-shaped state at all, and this backend holds no
Org-shaped state at all (no generations, no manifests, no staleness
policy) - it is a pure, restartable scoring cache over content-addressed
vectors that Emacs already knows how to rebuild via `load`.

Scoring is not a bare dot product. Measured against a real, mixed-content
corpus (work notes, hours, a recipe): multilingual-e5-small crowds nearly
every chunk into cosine 0.77-0.85 against almost any query, so the best
match and the 500th are barely distinguishable, and a handful of "hub"
chunks (a login-flow dump, a training-portal link) score in the top 5 for
completely unrelated queries. Two corrections, applied together (neither
alone was sufficient in that measurement):

  1. Mean-centering: subtract the corpus's mean vector from every vector
     (query included) before comparing. Standard correction for this kind
     of embedding anisotropy; costs one extra vector, recomputed whenever
     the loaded vector set changes.
  2. A CSLS-style hub penalty: subtract each candidate's own average
     similarity to its 10 nearest neighbours. This is what actually
     demotes the hub chunks - centering alone left them in the top 5.

Scores are then reported as a z-value relative to the median/spread of
the current candidate pool (after any `digests` prefilter), so a caller
can apply a threshold that means "notably better than typical for this
query" rather than an absolute cosine cutoff, which measurement showed
does not transfer across queries.
"""

from __future__ import annotations

import base64
import json
import math
import os
import statistics
import struct
import sys
from pathlib import Path
from typing import Any

PRESETS_PATH = Path(__file__).resolve().parent / "presets.json"
DEFAULT_HUB_LAMBDA = 0.5
DEFAULT_HUB_NEIGHBORS = 10
DEFAULT_MIN_POOL_FOR_Z = 10


def load_presets() -> dict[str, dict[str, Any]]:
    return json.loads(PRESETS_PATH.read_text(encoding="utf-8"))


def encode_vector(values: list[float]) -> str:
    return base64.b64encode(struct.pack(f"<{len(values)}f", *values)).decode("ascii")


def decode_vector(data: str, dim: int) -> list[float]:
    raw = base64.b64decode(data)
    return list(struct.unpack(f"<{dim}f", raw))


def normalize(values: list[float]) -> list[float]:
    norm = math.sqrt(sum(v * v for v in values))
    if norm == 0:
        return values
    return [v / norm for v in values]


class FakeEmbedder:
    """Deterministic, dependency-free embedder for protocol/fusion tests.

    Not a relevance stand-in: it hashes whitespace tokens into a bag-of-hashes
    vector, so it can prove ordering, top-k, digest restriction and the wire
    protocol work, but it proves nothing about semantic quality. Real
    relevance (including cross-language paraphrases) is only ever validated
    against a real installed model, via `make test-model` (ROADMAP.md
    phase 1) - this fake is never used to claim retrieval quality.
    """

    def __init__(self, dimension: int):
        self.dimension = dimension

    def embed(self, texts: list[str]) -> tuple[list[list[float]], int]:
        vectors = []
        truncated = 0
        for text in texts:
            vector = [0.0] * self.dimension
            tokens = text.casefold().split()
            if len(tokens) > 512:
                truncated += 1
                tokens = tokens[:512]
            for token in tokens:
                index = hash(token) % self.dimension
                vector[index] += 1.0
            vectors.append(normalize(vector))
        return vectors, truncated


class OnnxEmbedder:
    """Real embedder: tokenizers + onnxruntime, mean- or CLS-pooled, normalized.

    Imports its dependencies lazily so a fake-mode backend process never
    needs onnxruntime/tokenizers/numpy installed.
    """

    def __init__(self, model_dir: Path, preset: dict[str, Any]):
        import numpy as np
        import onnxruntime
        from tokenizers import Tokenizer

        self._np = np
        self.dimension = preset["dimension"]
        self.max_tokens = preset["max_tokens"]
        self.pooling = preset.get("pooling", "mean")
        self.tokenizer = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
        self.tokenizer.enable_truncation(max_length=self.max_tokens)
        self.tokenizer.enable_padding()
        onnx_path = model_dir / preset["onnx_file"]
        if not onnx_path.exists():
            # Some exports flatten the onnx/ subdirectory away.
            onnx_path = model_dir / Path(preset["onnx_file"]).name
        self.session = onnxruntime.InferenceSession(
            str(onnx_path), providers=["CPUExecutionProvider"]
        )

    def embed(self, texts: list[str]) -> tuple[list[list[float]], int]:
        np = self._np
        encodings = self.tokenizer.encode_batch(texts)
        truncated = sum(1 for e in encodings if len(e.overflowing) > 0)
        input_ids = np.array([e.ids for e in encodings], dtype=np.int64)
        attention_mask = np.array([e.attention_mask for e in encodings], dtype=np.int64)
        feeds = {"input_ids": input_ids, "attention_mask": attention_mask}
        input_names = {i.name for i in self.session.get_inputs()}
        if "token_type_ids" in input_names:
            feeds["token_type_ids"] = np.zeros_like(input_ids)
        outputs = self.session.run(None, feeds)
        hidden = outputs[0]  # (batch, seq, dim)
        if self.pooling == "cls":
            pooled = hidden[:, 0, :]
        else:
            mask = attention_mask[:, :, None].astype(np.float32)
            summed = (hidden * mask).sum(axis=1)
            counts = np.clip(mask.sum(axis=1), 1e-9, None)
            pooled = summed / counts
        norms = np.linalg.norm(pooled, axis=1, keepdims=True)
        norms = np.clip(norms, 1e-12, None)
        normalized = pooled / norms
        return normalized.tolist(), truncated


class Backend:
    def __init__(self, preset_name: str, presets: dict[str, dict[str, Any]],
                 model_dir: Path | None, fake: bool):
        if preset_name not in presets:
            raise ValueError(f"unknown model preset: {preset_name}")
        self.preset_name = preset_name
        self.preset = presets[preset_name]
        self.dimension = self.preset["dimension"]
        self.vectors: dict[str, list[float]] = {}
        if fake:
            self.embedder = FakeEmbedder(self.dimension)
        else:
            if model_dir is None:
                raise ValueError("model_dir is required outside fake mode")
            self.embedder = OnnxEmbedder(model_dir, self.preset)
        # numpy is only ever available here via OnnxEmbedder (which already
        # requires it); reusing that reference means the fake-embedder path
        # never imports numpy, keeping the fast test suite dependency-free,
        # while a real, thousands-of-chunks corpus gets vectorized scoring.
        self._np = getattr(self.embedder, "_np", None)
        self._matrix_cache: tuple[list[str], Any, list[float], list[float]] | None = None

    def hello(self) -> dict[str, Any]:
        return {
            "model_id": self.preset["model_id"],
            "preset": self.preset_name,
            "dimension": self.dimension,
            "max_tokens": self.preset["max_tokens"],
            "query_prefix": self.preset["query_prefix"],
            "passage_prefix": self.preset["passage_prefix"],
        }

    def embed(self, texts: list[str], kind: str) -> dict[str, Any]:
        prefix = self.preset["query_prefix"] if kind == "query" else self.preset["passage_prefix"]
        prefixed = [f"{prefix}{text}" for text in texts]
        vectors, truncated = self.embedder.embed(prefixed)
        return {
            "vectors": [encode_vector(normalize(v)) for v in vectors],
            "truncated": truncated,
        }

    def load(self, items: list[dict[str, Any]]) -> dict[str, Any]:
        loaded = 0
        for item in items:
            digest = item["digest"]
            vector = decode_vector(item["vector"], self.dimension)
            self.vectors[digest] = vector
            loaded += 1
        self._matrix_cache = None
        return {"loaded": loaded}

    def unload(self, digests: list[str]) -> dict[str, Any]:
        unloaded = 0
        for digest in digests:
            if self.vectors.pop(digest, None) is not None:
                unloaded += 1
        self._matrix_cache = None
        return {"unloaded": unloaded}

    def _centered_matrix(self):
        """Return (digests, centered-unit vectors, mean, per-vector hub score).

        Cached until the next `load`/`unload`. Centered vectors and hub
        scores are recomputed together because both derive from the same
        pass over the loaded vector set, and both are invalidated by
        exactly the same events.
        """
        if self._matrix_cache is not None:
            return self._matrix_cache
        digests = list(self.vectors.keys())
        if not digests:
            self._matrix_cache = (digests, None, None, [])
            return self._matrix_cache
        if self._np is not None:
            np = self._np
            matrix = np.array([self.vectors[d] for d in digests], dtype=np.float32)
            mean = matrix.mean(axis=0)
            centered = matrix - mean
            norms = np.clip(np.linalg.norm(centered, axis=1, keepdims=True), 1e-12, None)
            centered = centered / norms
            n = len(digests)
            if n > 1:
                similarity = centered @ centered.T
                np.fill_diagonal(similarity, -1.0)
                neighbors = min(DEFAULT_HUB_NEIGHBORS, n - 1)
                nearest = np.partition(similarity, n - neighbors, axis=1)[:, n - neighbors:]
                hub = nearest.mean(axis=1).tolist()
            else:
                hub = [0.0]
            mean = mean.tolist()
        else:
            # Pure-Python fallback: only reachable via the fake embedder,
            # whose tests use a handful of vectors, so an O(n^2) pass here
            # is fine; a real corpus always goes through the numpy path
            # above via OnnxEmbedder.
            dim = len(self.vectors[digests[0]])
            n = len(digests)
            mean = [sum(self.vectors[d][i] for d in digests) / n for i in range(dim)]
            centered = []
            for d in digests:
                shifted = [self.vectors[d][i] - mean[i] for i in range(dim)]
                norm = math.sqrt(sum(x * x for x in shifted)) or 1.0
                centered.append([x / norm for x in shifted])
            hub = []
            for i in range(n):
                sims = sorted(
                    (sum(a * b for a, b in zip(centered[i], centered[j]))
                     for j in range(n) if j != i),
                    reverse=True,
                )
                top = sims[: min(DEFAULT_HUB_NEIGHBORS, len(sims))]
                hub.append(sum(top) / len(top) if top else 0.0)
        self._matrix_cache = (digests, centered, mean, hub)
        return self._matrix_cache

    def search(self, query: str, k: int, digests: list[str] | None,
               min_z: float | None, hub_lambda: float,
               min_pool_for_z: int = DEFAULT_MIN_POOL_FOR_Z) -> dict[str, Any]:
        all_digests, centered, mean, hub = self._centered_matrix()
        if not all_digests:
            return {"results": []}
        embedded = self.embed([query], "query")
        query_vector = decode_vector(embedded["vectors"][0], self.dimension)
        if self._np is not None:
            np = self._np
            shifted = np.asarray(query_vector, dtype=np.float32) - np.asarray(mean, dtype=np.float32)
            norm = max(float(np.linalg.norm(shifted)), 1e-12)
            query_centered = shifted / norm
            cosine = (centered @ query_centered).tolist()
        else:
            shifted = [query_vector[i] - mean[i] for i in range(len(query_vector))]
            norm = math.sqrt(sum(x * x for x in shifted)) or 1.0
            query_centered = [x / norm for x in shifted]
            cosine = [sum(a * b for a, b in zip(row, query_centered)) for row in centered]
        raw = [cosine[i] - hub_lambda * hub[i] for i in range(len(all_digests))]
        if digests is not None:
            allowed = set(digests)
            candidate_indices = [i for i, d in enumerate(all_digests) if d in allowed]
        else:
            candidate_indices = list(range(len(all_digests)))
        if not candidate_indices:
            return {"results": []}
        pool = [raw[i] for i in candidate_indices]
        median = statistics.median(pool)
        spread = statistics.pstdev(pool) or 1e-9
        scored = [
            {
                "digest": all_digests[i],
                "score": raw[i],
                "cosine": cosine[i],
                "z": (raw[i] - median) / spread,
            }
            for i in candidate_indices
        ]
        scored.sort(key=lambda item: item["score"], reverse=True)
        # A z-score threshold is not statistically meaningful below a
        # minimum candidate count: numerically optimizing this exact
        # formula (one point's deviation from the pool's median, scaled by
        # the pool's population standard deviation) shows the single best
        # candidate in a 7-item pool cannot exceed z~2.96 under ANY
        # arrangement of the other six values, while an 8-item pool can
        # just clear 3.0. DEFAULT_MIN_POOL_FOR_Z (10) sits comfortably
        # above that breakeven point, so `min_z`'s default of 3.0 has real
        # headroom to reject a merely-average candidate rather than being
        # unreachable by construction. Below the floor, min_z is not
        # applied at all - the caller gets its top-k by score instead of a
        # confident empty result.
        if min_z is not None and len(candidate_indices) >= min_pool_for_z:
            scored = [item for item in scored if item["z"] >= min_z]
        return {"results": scored[: max(0, k)]}



def handle(backend: Backend, request: dict[str, Any]) -> dict[str, Any]:
    op = request.get("op")
    if op == "hello":
        return backend.hello()
    if op == "embed":
        return backend.embed(list(request["texts"]), request.get("kind", "passage"))
    if op == "load":
        return backend.load(list(request["items"]))
    if op == "unload":
        return backend.unload(list(request["digests"]))
    if op == "search":
        return backend.search(request["query"], int(request.get("k", 10)),
                               request.get("digests"), request.get("min_z"),
                               float(request.get("hub_lambda", DEFAULT_HUB_LAMBDA)),
                               int(request.get("min_pool_for_z", DEFAULT_MIN_POOL_FOR_Z)))
    raise ValueError(f"unknown op: {op!r}")


def main() -> int:
    preset_name = sys.argv[1] if len(sys.argv) > 1 else "e5-small"
    model_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    fake = os.environ.get("ORG_GLEAN_FAKE_EMBED") == "1"
    presets = load_presets()
    backend = Backend(preset_name, presets, model_dir, fake)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request = json.loads(line)
        request_id = request.get("id")
        try:
            result = handle(backend, request)
            response = {"id": request_id, "result": result}
        except Exception as error:  # noqa: BLE001 - report, never crash the backend
            response = {"id": request_id,
                        "error": {"type": type(error).__name__, "message": str(error)}}
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
