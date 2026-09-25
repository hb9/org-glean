# Roadmap

Org Glean's reason to exist is solid, out-of-the-box local semantic
retrieval over an Org corpus. Exact/lexical/fuzzy search exist to support and
explain semantic results, not as the product. See `DESIGN.md` for the full
architecture; this file tracks phases and exit criteria.

## Phase 0 — Reset (in progress)

Salvage what works, park what doesn't, rewrite the contract documents around
the semantic-first vision, then split the single-file implementation into
modules before adding new capability.

- [x] Park the Python worker-backed reconcile and the generation/manifest
      semantic helper on a local-only branch
      (`park/worker-and-generation-semantic`); they are superseded by
      designs in `DESIGN.md`, not lost.
- [x] Rebuild the parts worth keeping as atomic commits on `main`: the FTS
      rebuild-on-open fix (plus a second, related bug it uncovered), the
      `org-glean-status`/`org-glean-show-errors` diagnostics, and explicit
      provider modes with structured `provider-errors` (including the
      `org-glean-semantic-provider` hook, nil by default).
- [x] Rewrite `DESIGN.md`, `ROADMAP.md` (this file) and `API.md` around the
      semantic-first vision.
- [x] Split `org-glean.el` into modules with no behaviour change:
      `org-glean-core`, `-project`, `-store`, `-index`, `-search`, `-ui`,
      `-mcp`, with `org-glean.el` as a thin entry point. Add a `Makefile`
      with `test`/`compile`/`clean` targets.

**Exit:** same ERT count green, each module byte-compiles warning-free,
`emacs -Q -l org-glean.el` loads cleanly, MCP tool registers, worktree clean.
Met.

## Phase 1 — Semantic MVP, end to end

- [x] Store schema v2: `chunks` and `vectors` tables, content-keyed by
      `(model_id, text_digest)`; coverage computed as a per-chunk fact, not a
      global generation digest. `org-glean--replace` rewrites a source's
      chunks wholesale but never touches `vectors`, so an unchanged passage
      keeps its vector across reprojection. Chunking was initially naive
      (title+body verbatim, one chunk per target); real chunking landed
      next (below).
- [x] Chunking (`org-glean-chunk.el`): a file-level passage summarizing its
      shallow heading outline, and a heading passage prefixed with its full
      outline path so a chunk is self-describing without its neighbours.
      Long bodies split into paragraph-aligned windows
      (`org-glean-chunk-max-chars`, default ~1500 characters — a character
      estimate, not a token count; see the open question below) with
      trailing-paragraph overlap (`org-glean-chunk-overlap-chars`) carried
      into the next window. A chunk's digest depends only on its text, not
      its position, so a heading that moves within its file keeps its
      vector.
- [x] Backend protocol and process (`semantic/org_glean_embed.py`):
      `hello`/`embed`/`load`/`unload`/`search` over JSON Lines on stdio, our
      own `onnxruntime` + `tokenizers` wrapper (no third-party embedding
      library, no PyTorch), lazily imported so the fake-embedder test path
      (`ORG_GLEAN_FAKE_EMBED=1`) has zero third-party dependencies. Model
      presets (`semantic/presets.json`) are data: `e5-small` (default, 384
      dimensions, mean pooling — verified against the cached model's own
      `1_Pooling/config.json`), `e5-base`, `bge-m3`. Vectors travel as
      base64-encoded float32, never JSON float arrays. The backend holds no
      Org-shaped state (no generations, no manifests): it is a pure,
      restartable scoring cache Emacs repopulates via `load`.
- `org-glean-install`: package-private `uv` venv, one explicit consent
  prompt for model download, ONNX export + self-test (German/English
  paraphrase ranks above a distractor).
- Model presets: `e5-small` (default), `e5-base`, `bge-m3` — swappable via
  `org-glean-semantic-model` with no other invalidation.
- Background embedding queue: saves and reconciliation update chunks and
  lexical search immediately; an idle timer embeds queued chunks in bounded,
  cancellable batches via process callbacks (never blocking Emacs).
- Asynchronous semantic query with in-memory backend-held vectors and
  structural prefiltering (no per-query key-list shipping); a synchronous
  wrapper with a timeout for MCP/batch callers.
- Aggregation from chunk → heading → file, caller-selected granularity.
- Deterministic test coverage: a fake, hash-based backend for fast ERT runs,
  one real end-to-end test per process boundary (this was the gate that
  caught a real crash in the previous worker attempt — never skip it again),
  and an opt-in real-model suite (`make test-model`) with German/English
  paraphrase fixtures.
- A small private judged query set (no-term-overlap, German↔English, file
  suggestion) and `org-glean-eval`, used to tune chunking/fusion and compare
  model presets — a regression/tuning tool, not an existence gate.

**Exit:** a fresh Emacs plus one `org-glean-install` run produces relevant
semantic results on a real corpus. Saves never block editing; lexical
results reflect a save immediately, semantic coverage catches up in the
background and is reported honestly (`"semantic: 97% covered"`, not a single
stale/ready flag). Swapping to `bge-m3` re-embeds without breaking search,
which stays fully usable throughout on lexical/exact evidence.

## Phase 2 — Hybrid quality

- Weighted reciprocal-rank fusion across exact/lexical/fuzzy/semantic, with
  exact ID/title pinned above the fused order; tune weights against the
  judged set from phase 1.
- Chunk-window and outline-path passage tuning informed by real misses.
- File- and heading-suggestion quality as a first-class evaluation target,
  not a side effect of chunk-level scoring.

## Phase 3 — Agents

- `org-glean_search` (evidence, coverage, freshness, granularity),
  `org-glean_similar`, `org-glean_suggest_location` as MCP tools.
- Revisit headless (non-Emacs) agent access once MCP-through-Emacs proves
  insufficient in practice (see open questions).

## Phase 4 — Robustness and scale

- Incremental, time-sliced full reconciliation using the projection-config
  digest; a batch `emacs --batch` path (no Python) for first-build-only of
  very large corpora.
- Model switching/re-embedding at scale; vector garbage collection for
  superseded models.
- Optional ANN (`sqlite-vec` or `hnswlib`) behind the same `search` call.
- Optional HTTP/Ollama-compatible embedding backend for users who already
  run a local model server.
- Restart, cancellation and concurrent-save-during-reconcile hardening.

## Later

- Structural and link retrieval: backlinks and Org IDs as a fusion signal
  alongside semantic/lexical evidence, not a separate subsystem.

## Open questions (revisit as they become blocking)

- **Headless agent access.** MCP through a running Emacs is accepted for
  now; a CLI/daemon reading the same SQLite index directly would make Org
  Glean usable by agents with no Emacs process, at the cost of a second
  front end to keep in sync with Emacs's configuration authority.
- **ANN vs. brute-force threshold.** Brute-force cosine is fine to roughly
  100k chunks; revisit if a real corpus approaches that size.
- **Character-estimated chunk windows.** `org-glean-chunk-max-chars` is a
  character count, not a token count, because Emacs does the windowing and
  has no tokenizer. The backend (C3/C4) reports actual per-chunk truncation
  against the model's real token limit; if that shows frequent truncation on
  real content, tune the character estimate down or move windowing behind
  the backend boundary where a real tokenizer is available.
