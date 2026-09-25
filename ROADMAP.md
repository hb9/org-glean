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
- [x] Async client (`org-glean-embed.el`): a persistent, restartable
      subprocess wrapper around the C3 backend with both an asynchronous
      (callback-keyed) and synchronous (timeout) calling convention.
      `org-glean-embed-available-p` is a pure filesystem check with no
      process start and no network access.
- [x] `org-glean-install`: prompts for a preset (default
      `org-glean-semantic-model`) and shows its approximate download size
      before one explicit consent prompt; creates a package-private `uv`
      venv under `org-glean-semantic-venv-dir`, installs backend
      dependencies, downloads the model's tokenizer/ONNX files
      (`semantic/org_glean_download.py`, the only network-touching step),
      and runs a self-test that a German/English paraphrase outranks an
      unrelated distractor via the real protocol (embed, load, search) —
      not a hand-rolled similarity computation in Elisp. Model download and
      dependency install currently run synchronously (`call-process`) with
      output in a `*Org Glean Install*` log buffer; converting this to a
      fully async step chain is deferred (see open questions).
- Model presets: `e5-small` (default), `e5-base`, `bge-m3` — swappable via
  `org-glean-semantic-model` with no other invalidation.
- [x] Background embedding queue (`org-glean-semantic.el`): saves and
      reconciliation update chunks and lexical search immediately, then call
      `org-glean-semantic-queue-start`, which starts an idle timer (fires
      only once Emacs is idle, so it naturally pauses while typing with no
      `input-pending-p` polling needed). Each tick embeds one bounded batch
      (`org-glean-semantic-batch-size`, default 32) of chunks lacking a
      vector for the active model, asynchronously; the batch's callback
      writes vectors in one transaction and pushes them into the backend's
      in-memory `load` cache so a query right after sees them. Overlapping
      batches are prevented by an in-flight flag, not by stopping the
      timer. `org-glean-semantic-pause`/`-resume` stop/restart it;
      `org-glean-status`'s `:semantic-queue-state` reports `idle`/
      `running`/`paused`. `org-glean-install-hook` (run after a passing
      self-test) starts the queue immediately after a fresh install,
      without needing a require cycle back into org-glean-embed.el.
- [x] Semantic provider (`org-glean--semantic-search-provider` in
      `org-glean-search.el`, registered as `org-glean-semantic-provider`'s
      default the moment the file loads, unless something already
      customized the hook away): embeds the query with a synchronous
      request, warms a fresh backend process from SQLite first
      (`org-glean--semantic-ensure-warm`, paged so an Emacs restart doesn't
      need to re-embed anything, only reload), asks the backend for
      `k = clamp(5×limit, 50, 200)` chunk hits, aggregates chunk hits up to
      their owning target by max score (deduping is free: the backend
      already returns hits sorted descending, so a target's first hit is
      its best chunk), applies the same generic filters every other
      provider applies, and returns at most `limit` items. Missing
      installation surfaces as a normal provider error
      (`provider-errors`), exactly like a lexical or fuzzy provider
      failure — never a crash, never silently empty. `:semantic-state` in
      `org-glean-status` now distinguishes `unavailable` (no provider at
      all), `not-installed` (provider configured, model not installed) and
      `ready` (installed and warmable). Result ordering places `semantic`
      between `lexical` and `fuzzy` (still priority-tier ordering, not
      calibrated fusion — that is phase 2's `RRF` work below). File- and
      caller-selected chunk/heading/file granularity is not yet
      implemented: a semantic hit always resolves to its exact owning
      target (file record or heading record), which is a strict subset of
      the planned aggregation.
- Deterministic test coverage: a fake, hash-based backend for fast ERT runs,
  one real end-to-end test per process boundary (this was the gate that
  caught a real crash in the previous worker attempt — never skip it again),
  and an opt-in real-model suite (`make test-model`) with German/English
  paraphrase fixtures.
- A small private judged query set (no-term-overlap, German↔English, file
  suggestion) and `org-glean-eval`, used to tune chunking/fusion and compare
  model presets — a regression/tuning tool, not an existence gate.
- [x] `make test-model` (`test/org-glean-model-test.el`) implemented and
      passing against a real installed `e5-small`: `org-glean-install`'s
      self-test, cross-language German→English retrieval (a heading titled
      "Schweißnahtprüfung Protokoll" is the top result for the query "weld
      inspection"), a no-term-overlap query ("how is revenue trending"
      correctly finds "Quarterly sales figures" with zero shared words),
      and `org-glean-search-api` with `semantic` in modes end to end.

**Exit: met.** `org-glean-install e5-small` succeeded end to end on this
machine (venv, dependency install, ~470 MB ONNX download, self-test) after
fixing two real bugs surfaced only by actually running it (below). A fresh
Emacs plus that one install run now produces relevant semantic results on a
real corpus, confirmed both manually and by `make test-model`: saves never
block editing; lexical results reflect a save immediately, semantic
coverage catches up in the background. Not yet true: coverage/freshness
reporting is still a single per-model fraction
(`:semantic-coverage-chunks`/`-total`), not the free-text "97% covered"
framing this exit criterion originally imagined — that framing was always
aspirational prose, not a field name; the actual per-chunk-fact mechanism
behind it is real (phase 1, C1). Swapping models to confirm `bge-m3`
re-embeds cleanly has not been tried yet.

**Two real bugs found only by running the actual install against a real
network and a real model, neither caught by the fake-embedder test suite:**

1. **TLS verification failure in a proxied/sandboxed environment.**
   `huggingface_hub` (via `httpx`) trusts only the bundled `certifi` CA
   list by default, not the OS trust store; a MITM-proxied environment
   (this dev sandbox, and plausibly many corporate networks) only has the
   proxy's root CA in the OS store. Fixed in
   `semantic/org_glean_download.py` by setting `SSL_CERT_FILE` to the
   OS-reported default CA file (`ssl.get_default_verify_paths().cafile`)
   before importing `huggingface_hub`, unless the user already set
   `SSL_CERT_FILE` themselves.
2. **Lossy BLOB round-trip through `sqlite-select`.** Emacs's `sqlite-select`
   does not reliably return a BLOB column's exact original bytes: byte
   sequences that happen to form valid UTF-8 are silently decoded into
   fewer multibyte characters on the way back out, corrupting arbitrary
   binary data (confirmed with a minimal repro: a 256-byte unibyte string
   written to a BLOB column comes back as a *different*, longer-or-shorter
   multibyte string; `string-to-unibyte` can only reverse this for the
   subset of cases where every byte stayed a distinct raw "eight-bit"
   pseudo-character, which real embedding vectors do not guarantee). This
   only manifested once a *fresh* backend process needed to reload vectors
   from SQLite (`org-glean--semantic-ensure-warm`'s warm-reload path,
   e.g. after an Emacs restart) rather than serving them from the
   in-memory cache a same-session embedding batch had just populated via
   `load` — which is exactly why the ERT suite's fake-backend tests never
   hit it. Fixed by never decoding vectors to raw bytes at all: `vectors.vector`
   now stores the base64 ASCII text itself (immune to the corruption,
   since ASCII bytes round-trip identically regardless of unibyte/
   multibyte flag), forwarded verbatim on reload instead of decode-then-
   re-encode. A new ERT regression test
   (`org-glean-test-semantic-provider-survives-backend-restart`) forces
   exactly this reload path with the fake backend so this class of bug is
   now caught without needing a real model.
3. **Re-running `org-glean-install` crashed on a partial prior success.**
   `hf_hub_download`'s cache copies preserve the upstream file's (typically
   read-only) permissions; `shutil.copy2` opens the destination for
   writing and raised `PermissionError` the moment a second install
   attempt tried to overwrite a file a first, successful download had
   already placed (e.g. after `org-glean-install` failed on a later step
   and was simply re-run). Fixed with `_copy_overwriting`, which removes
   an existing destination file before copying; covered by
   `test/test_download_script.py` (no network needed — it tests the copy
   helper directly, including the read-only-destination case).

## Phase 1.5 — Hybrid fusion and semantic-first interactive use (done)

Landed ahead of phase 2's original schedule, once real-model validation
(above) showed the foundation was solid enough to build on:

- [x] **Weighted reciprocal-rank fusion** (`org-glean-search.el`). Every
      requested mode collects its own candidate pool independently
      (`org-glean-fusion-pool-size`, default 50) instead of lexical results
      consuming the limit before semantic/fuzzy get a chance; candidates
      are merged by target key (`:modes` lists every contributing mode
      with its rank and raw score) and ranked by
      `weight/(k+rank+1)` summed per mode (`org-glean-fusion-weights`:
      exact 1.0, semantic 1.0, lexical 0.8, fuzzy 0.3; `org-glean-fusion-k`
      60). An exact match is pinned above the fused order; ties break by
      fused score then best contributing rank, so ordering is
      deterministic for a given generation and query. Real caught bug: the
      merge step discarded `:source-current` on every item because a
      helper adding a *new* alist key was called only for its side effect
      instead of its return value being captured — a fresh regression test
      now locks this in.
- [x] **Semantic on by default once installed** (`org-glean--default-modes`,
      overridable via `org-glean-default-modes`): `org-glean-find`,
      `org-glean-search-buffer` and MCP now request
      `(exact lexical fuzzy semantic)` automatically once
      `org-glean-embed-available-p` is true, `(exact lexical fuzzy)`
      otherwise. `org-glean-search-api`'s own low-level default is
      unchanged, so existing programmatic callers are unaffected.
- [x] **Semantic-only commands and results UI**: `org-glean-find-semantic`,
      `org-glean-search-buffer-semantic` (force `(semantic)` modes; signal
      a clear `user-error` pointing at `M-x org-glean-install` rather than
      returning nothing if not installed); the results buffer remembers
      its modes across `g` refresh, toggles to/from semantic-only with
      `s`, gains a "Via" column showing contributing modes, and its header
      line reports active modes and semantic coverage.
- [x] **Default key bindings** under `org-glean-keymap-prefix` (default
      `M-s g`, confirmed unbound by Emacs/`search-map` by default; nil
      disables the binding): `g`/`G` normal find/search-buffer, `s`/`S`
      semantic-only, `r` reconcile, `i` status, `e` show-errors, `p`
      `org-glean-semantic-toggle` (new: pause the embedding queue if
      running, resume if paused).
- [x] **`org-glean-status` gains a one-line interactive summary**
      (`org-glean--status-summary`), e.g. `ready | semantic ready
      (e5-small) 812/1040 embedded, queue idle`.
- [x] **Hybrid real-model test** (`make test-model`): a target matching
      both lexically and semantically fuses both contributions and
      outranks a weaker semantic-only match. An earlier version of this
      test tried to make fusion override a genuinely better-matching
      lexical/semantic "decoy" and correctly failed — rank fusion combines
      real evidence, it does not manufacture relevance a model does not
      itself produce; the test was rewritten to assert something fusion
      actually guarantees.

89 ERT tests pass (was 71 before this phase), 5 real-model tests pass,
every module still byte-compiles clean.

Explicitly deferred to phase 2: caller-selected chunk/heading/file
granularity (a semantic hit still resolves to its exact owning target
only), and tuning `org-glean-fusion-weights`/`-k` against a judged query
set (they are reasonable literature defaults, not yet validated against
this corpus's actual retrieval quality).

## Phase 2 — Further hybrid quality

- Tune `org-glean-fusion-weights`/`org-glean-fusion-k` against a judged
  query set once one exists, rather than relying on literature defaults.
- Chunk-window and outline-path passage tuning informed by real misses.
- File- and heading-suggestion quality as a first-class evaluation target,
  not a side effect of chunk-level scoring — including caller-selected
  chunk/heading/file result granularity.

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
- **Synchronous `org-glean-install`.** venv creation, dependency install and
  model download currently block Emacs via `call-process`, appropriate for
  a rare, explicit, user-initiated action but not ideal for a large model on
  a slow connection. Convert to an async step chain if this proves
  disruptive in practice.
- **Synchronous semantic queries.** `org-glean--semantic-search-provider`
  uses `org-glean--embed-request-sync` (a blocking call with a timeout),
  because `org-glean-search-api` is itself a synchronous function that
  returns a value rather than taking a callback. Measured against the real
  e5-small model on a 3-file/6-chunk corpus: under a second per query
  including a cold warm-reload from SQLite (`make test-model`'s wall time
  is dominated by three separate reconcile+embed+query cycles, not by any
  single query). This is not evidence about a real multi-thousand-chunk
  corpus's warm-reload or per-query cost, but it is not the "might be too
  slow" hedge either. An async picker would need `org-glean-search-api`
  (or a new sibling) to grow a callback-based variant; revisit once real
  usage on a real-sized corpus shows the synchronous path is actually too
  slow, rather than restructuring the search API speculatively.
