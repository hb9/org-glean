# org-glean — design

## Vision

Org Glean is the local **semantic retrieval layer** for an Org corpus. Exact
title lookup, FTS5 lexical search and fuzzy title/heading matching already
exist elsewhere (grep, `ripgrep`, `org-agenda`'s own search) and are not why
this package exists. Org Glean exists to answer queries that share **no
words** with the right target: "where should notes about a supplier quality
escalation go" should surface `supplier-audits.org` even though neither
"escalation" nor "quality" appears in it. Exact, lexical and fuzzy retrieval
remain in the package as **evidence signals** that sharpen and explain
semantic results (an exact ID match is pinned; a lexical hit corroborates a
semantic one) — they are not peer products, and they are not the goal.

If semantic search does not work well, Org Glean does not need to exist: a
thinner package wrapping SQLite FTS5 would do. Every design decision below is
in service of solid, swappable, local semantic retrieval that works out of
the box.

### Who this serves

- **Agents**, human and automated, interacting with the corpus — via MCP
  through Emacs today; this is the primary scale driver, because agents
  already have grep-equivalent tools and need what grep cannot give them.
- **Capture** (in `org-knowledge`), which needs to place new material without
  forcing a classification — an important client, not the reason to exist.
- **Interactive Emacs search**, for humans exploring the corpus directly.

### Retained invariants

- Org files are canonical. The index (SQLite, vectors) is disposable derived
  state and can always be rebuilt from source.
- Org Glean reads Org; it never writes it, never assigns IDs, never mutates a
  buffer under a user's cursor.
- No language model or capability is ever downloaded silently. Installing a
  semantic backend is an explicit, consented action (`org-glean-install`).
- Degradation is always explicit and scoped. A missing/stale semantic backend
  degrades semantic mode; it never disables lexical/exact search, and it is
  never silently reported as success.
- `unfiled`/"no good match" is a legitimate result, not something to paper
  over with a forced best guess.

## Architecture

```
Emacs (configuration authority)                 Embedding backend (optional process)
 ├ discovery + org-element projection  ───────▶  ├ embed(texts) → vectors
 ├ SQLite: sources, targets, chunks, FTS         └ stateless: no generation/manifest
 ├ vector store (chunks, content-keyed BLOBs)        bookkeeping of its own
 ├ query orchestration + fusion + aggregation
 ├ UI (picker, results buffer, status)
 └ MCP adapter (agents)
```

Emacs owns configuration, Org projection, reconciliation policy, search
orchestration and result semantics. The embedding backend is a narrow,
swappable, stateless component: give it text, get back vectors (or give it a
query and a set of held vectors, get back scored candidates). It does not
decide what is stale, what the active model is, or what a "generation" is —
Emacs decides that, per chunk, from content digests it already tracks.

### Why a stateless backend

An earlier iteration of this design had the Python helper own "generations":
one global digest over all target text, a versioned on-disk manifest, and
reuse-by-passage-digest logic duplicated between Emacs and the helper. That
produced an all-or-nothing freshness model (any single save invalidated
*all* semantic search) and O(N) query cost (every query re-shipped and
re-scored every target). Freshness belongs where the rest of the index's
change-tracking already lives: per chunk, in Emacs's SQLite store.

### Chunking

Retrieval units are Org-aware, not raw byte windows:
- one chunk for a file's title plus its top-level outline (a file-level
  passage, so file-granularity suggestions do not require aggregating
  dozens of heading chunks);
- one or more chunks per heading: title plus outline path plus a window of
  body text, split at paragraph boundaries at roughly 350–400 tokens
  (approximated by characters) with light overlap, so a long body is never
  silently truncated by the model's context window;
- properties/tags rendered as text where they carry retrievable meaning.

Each chunk has a `text_digest` (content hash of its exact passage text,
including outline-path context) so an unrelated edit elsewhere in a heading,
or a pure move, does not invalidate its vector.

### Storage: SQLite BLOBs, keyed by (model, content)

```sql
CREATE TABLE chunks (
  key TEXT PRIMARY KEY,      -- stable chunk identity
  target_key TEXT NOT NULL,  -- owning file/heading target
  path TEXT NOT NULL,
  ord INTEGER NOT NULL,      -- chunk order within its target
  text TEXT NOT NULL,        -- the exact embedded passage
  text_digest TEXT NOT NULL
);

CREATE TABLE vectors (
  model_id TEXT NOT NULL,
  text_digest TEXT NOT NULL,
  dim INTEGER NOT NULL,
  vector BLOB NOT NULL,      -- float32, normalized
  PRIMARY KEY (model_id, text_digest)
);
```

A vector is content-addressed: reprojecting an unchanged heading, or
switching back to a previously-used model, never re-embeds. **Freshness is a
per-chunk fact**, not a global flag: coverage is simply
`count(chunks with a vectors row for the active model) / count(chunks)`.
Saving one file invalidates only that file's changed chunks; search remains
available for everything else at full semantic quality throughout.

Vector storage lives in Org Glean's own SQLite database (not a separate file
the backend owns), so there is exactly one store to reason about, one thing
to back up, and one thing `VACUUM INTO` needs to copy safely.

### Embedding backend protocol

A model cannot run in Elisp. The backend is a subprocess speaking JSON Lines
over stdio:

- `hello` → `{model_id, dimension, max_tokens, query_prefix, passage_prefix}`
- `embed {texts, kind: "query"|"passage"}` → `{vectors: [[float, ...], ...]}`
- `load {vectors: [{text_digest, dim, vector}, ...]}` — hand the backend the
  currently-known vectors so it can score in memory without Emacs re-sending
  them on every query
- `search {query, k, prefilter}` → `{results: [{text_digest, score}, ...]}`,
  scored against whatever `load` has accumulated plus fresh `embed` calls

Emacs owns the source of truth in SQLite; the backend is a stateless (per
model) scoring cache that can be discarded and rebuilt from `load` at any
time with no data loss. Brute-force cosine similarity over normalized
vectors is sufficient up to roughly 100k chunks (e5-small at 384 dimensions
is about 1.5 KB/chunk); ANN (`sqlite-vec`, `hnswlib`) is a later optimization
behind the same `search` call, not a design requirement now.

### Own ONNX wrapper, not a third-party embedding library

The backend is `onnxruntime` + `tokenizers` + `numpy`, wrapped by
Org Glean itself rather than delegated to a higher-level embeddings library.
This is deliberate: it keeps model swapping (see below) fully under our
control — mean-pooling, normalization, and query/passage prefix conventions
differ subtly across E5-family and BGE models, and a thin wrapper we own can
support all three presets without waiting on an upstream library's model
list. Total install size is on the order of 100 MB (no PyTorch).

### Model presets (swappable)

```elisp
(:name "e5-small" :model-id "intfloat/multilingual-e5-small"
 :dimension 384 :query-prefix "query: " :passage-prefix "passage: ")
(:name "e5-base"  :model-id "intfloat/multilingual-e5-base"
 :dimension 768 :query-prefix "query: " :passage-prefix "passage: ")
(:name "bge-m3"   :model-id "BAAI/bge-m3"
 :dimension 1024 :query-prefix "" :passage-prefix "")
```

`e5-small` is the default: fast, small, and the same model already used
successfully in `org-knowledge` for German/English retrieval, which is the
primary language pairing. Switching `org-glean-semantic-model` only changes
which `model_id` rows in `vectors` are consulted; nothing else invalidates,
and old-model vectors are garbage-collected once no longer referenced rather
than deleted eagerly.

### Managed installation: `org-glean-install`

`M-x org-glean-install`:
1. creates a package-private `uv`-managed virtual environment under
   `user-emacs-directory` (not the user's global Python);
2. prompts once, explicitly, for consent to download the selected model
   (default `e5-small`) from Hugging Face;
3. exports the model to ONNX if not already cached, and runs a self-test —
   a German/English paraphrase pair must rank above an unrelated distractor;
4. reports pass/fail; ordinary search never triggers any of this implicitly.

### Query path

The backend holds vectors in memory (via `load`) so a query is one `embed`
call plus an in-process scan, not a full reload from SQLite. Emacs never
ships a full candidate key list to the backend; a query carries an optional
structural prefilter (allowed roots, path/kind constraints) that the backend
applies before scoring, and the backend applies it directly against its
loaded vector set. The query API is asynchronous (process callback,
non-blocking for the picker); a synchronous wrapper with an explicit timeout
exists for MCP and batch callers only.

### Retrieval, aggregation and fusion

1. Candidates are collected per mode (semantic, lexical/BM25, exact/fuzzy),
   each independently bounded, so a full lexical result set never crowds out
   semantic candidates before fusion runs.
2. Fusion is deterministic weighted reciprocal-rank fusion, semantic
   weighted highest, with an exact ID/title match pinned above the fused
   order rather than competing on score.
3. Results aggregate from chunk → heading → file (max chunk score plus a
   top-3 mean), and the caller chooses the returned granularity
   (`chunk | heading | file`) — "suggest a file" and "suggest a heading" are
   both this same aggregation at a different level, which is what makes
   "suggest where new content belongs" a generic capability rather than a
   capture-specific one.
4. Every result keeps every contributing mode, its provider-specific rank
   and score, and a human-readable match reason. Scores from different
   providers (BM25, cosine, edit distance) are never averaged together as if
   they were one confidence scale.

### Indexing

- Save updates and reconciliation run **in-process** in Emacs. Projecting one
  file is cheap; SQLite is updated immediately, so lexical search reflects a
  save at once.
- Changed chunks are queued for embedding in the background; an idle timer
  sends bounded batches to the backend asynchronously (process callbacks,
  not busy-waiting), so semantic coverage catches up without blocking
  editing.
- Full reconciliation is incremental and time-sliced on idle timers, not a
  from-scratch rebuild: unchanged sources cost a stat plus a digest compare.
  A batch `emacs --batch` child (spawned directly by Elisp, no Python
  involved) is reserved for the first build of a very large corpus, not for
  routine periodic runs.
- A projection-config digest (relevant `org-todo-keywords`, tags and
  `org-element` version) is stored alongside the index; if it changes,
  affected sources are re-projected even though their file digest is
  unchanged, so a batch worker's `emacs --batch -Q` context never silently
  diverges from the interactive daemon's projection.
- Any full-database copy (for staging, backup, or worker handoff) uses
  SQLite's backup API or `VACUUM INTO`, never a raw file copy of a database
  that might have an open connection or an unflushed WAL.

## Agent-facing surface (MCP, via Emacs)

- `org-glean_search`: query, granularity, filters, modes, k. Returns
  per-mode evidence, coverage/freshness, and completeness.
- `org-glean_similar` (planned): given a target or free text, return
  neighbours — related notes, deduplication.
- `org-glean_suggest_location` (planned): file/heading placement ranking for
  new content — the generic capability capture's routing need is an
  instance of.

Headless (non-Emacs) agent access is deliberately deferred: MCP through a
running Emacs is sufficient for now (see ROADMAP.md open questions).

## What changed from the first slice

The original first-slice design (exact/FTS/fuzzy, described below for
historical reference) is unchanged in its mechanics but is now explicitly
scoped as **evidence infrastructure for fusion**, not the product surface.
Two prior implementation directions were tried and parked
(`park/worker-and-generation-semantic`, local branch only) because they
worked against this vision rather than for it:
- A Python-driven batch reconciliation worker that always started from an
  empty staged database, making every periodic run a full rebuild; the
  in-process, time-sliced, config-digest-aware reconciler above replaces it
  without needing Python at all for lexical indexing.
- A generation/manifest-based semantic helper with a single global staleness
  digest and O(N) per-query key shipping; the per-chunk, content-keyed,
  stateless-backend design above replaces it.

Legacy `org-knowledge`'s `sentence-transformers`-based e5 search (in
`src/orgknowledge/search/embed.py`) is the working proof that multilingual
e5 retrieval is worth having; it is a precursor to be ported into the ONNX
backend above, not a competing implementation to keep running in parallel.

## First-slice mechanics (unchanged, retained as evidence infrastructure)

1. Root discovery accepts named roots and include/exclude patterns. It never
   follows directory symlinks or accepts a source escaping its root.
2. An `org-element` projector reads one saved file and emits file/heading
   records with source ownership. Org `ID` is optional; ID-less headings have
   snapshot-scoped occurrence keys and provisional navigation.
3. The reconciler compares a manifest with recursive discovery. It adds,
   replaces, skips or removes whole sources transactionally. A parse failure
   leaves the previous indexed version intact.
4. A SQLite/FTS5 writer owns the first materialization. Exact and FTS queries
   return bounded, typed results; optional fuzzy title/heading matching draws
   from a bounded candidate pool. A completion picker and exploration side
   buffer navigate only after checking that the source snapshot still matches.
5. Save hooks enqueue debounced per-file refreshes. A configurable idle timer
   (initially 600 seconds) runs authoritative full-tree reconciliation; an
   initial asynchronous startup run populates/reconciles the index.
6. A separate MCP adapter exposes the generic result-set through the installed
   Emacs MCP tool registry as `org-glean_search`. It applies an explicit
   allowed-root fence and has no write or arbitrary-evaluation capability.

These interfaces are logical ports so watchers, writers, and search engines can
be changed independently.

## First-slice acceptance (unchanged)

- Temporary fixtures only: nested files, duplicate ID-less headings, moves,
  deletion, unchanged no-op, changed source replacement, and parse errors.
- Full reconciliation twice yields identical logical targets and no row growth.
- A failed source replacement leaves the prior searchable rows intact.
- A saved file can be searched by exact heading/title and FTS body terms.
- Bounded results identify source, heading, stability and navigation hint.
- The picker does not silently open an ambiguous/stale provisional heading.
- Save update refreshes only the selected source; startup/periodic reconciles
  catch external edits, renames and deletes.
- MCP JSON output is bounded, source-freshness-labelled and root-confined.
