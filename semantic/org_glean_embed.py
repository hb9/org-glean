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

    {"id": 5, "op": "search", "query": "...", "k": 10, "digests": [...]?}
    -> {"id": 5, "result": {"results": [{"digest": "...", "score": 0.83}, ...]}}

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
"""

from __future__ import annotations

import base64
import json
import math
import os
import struct
import sys
from pathlib import Path
from typing import Any

PRESETS_PATH = Path(__file__).resolve().parent / "presets.json"


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


def dot(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


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
        return {"loaded": loaded}

    def unload(self, digests: list[str]) -> dict[str, Any]:
        unloaded = 0
        for digest in digests:
            if self.vectors.pop(digest, None) is not None:
                unloaded += 1
        return {"unloaded": unloaded}

    def search(self, query: str, k: int, digests: list[str] | None) -> dict[str, Any]:
        embedded = self.embed([query], "query")
        query_vector = decode_vector(embedded["vectors"][0], self.dimension)
        candidates = (
            [(d, self.vectors[d]) for d in digests if d in self.vectors]
            if digests is not None
            else list(self.vectors.items())
        )
        scored = [(digest, dot(query_vector, vector)) for digest, vector in candidates]
        scored.sort(key=lambda pair: pair[1], reverse=True)
        top = scored[: max(0, k)]
        return {"results": [{"digest": d, "score": s} for d, s in top]}


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
                               request.get("digests"))
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
