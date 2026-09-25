# org-glean

Local semantic retrieval for an Org corpus, for agents and humans. Org
Glean's reason to exist is answering queries that share no words with the
right target — install a local model once (`M-x org-glean-install`) and
`semantic` search mode finds "Quarterly sales figures" for "how is revenue
trending", or a German heading for an English query, with zero literal word
overlap. Exact, lexical (FTS5) and fuzzy title/heading search work
alongside it, combined by weighted rank fusion rather than treated as
separate fallbacks. See [DESIGN.md](DESIGN.md) for the full vision and
architecture, and [ROADMAP.md](ROADMAP.md) for phases and current status.
Emacs owns configuration and interaction; the index is derived from Org and
can always be rebuilt. Requires Emacs 29+ compiled with SQLite FTS5 support.
This project is under active development; no release has been cut.

See [API.md](API.md) for the versioned application API contract. The
originating design is the E2 Org Glean note in `hb9/org-knowledge` (Denote ID
`20260923T130815`).

Licensed under GPL-3.0-or-later; see [LICENSE](LICENSE).

## Quick start

```elisp
(add-to-list 'load-path "/path/to/org-glean")
(require 'org-glean)
(setq org-glean-roots
      '(("notes" "~/org/notes" nil ("/archive/"))))
(org-glean-reconcile) ; manual first build and recovery
(org-glean-find "sqlite transaction")
(org-glean-search-buffer "sqlite transaction")
```

The root tuple is `(NAME DIRECTORY INCLUDE-REGEXPS EXCLUDE-REGEXPS)`; patterns
match root-relative file paths, and only `.org` files are indexed. The database
defaults to `org-glean.sqlite` under `user-emacs-directory`; set
`org-glean-database-file` to choose another disposable index. Search functions
return at most 100 typed results. Existing Org IDs enable move-stable lookup;
ID-less targets are snapshot-scoped and navigation rechecks the source before
opening it.

`org-glean-start` enables coalesced saved-file updates and the configurable
600-second authoritative reconciliation timer. `org-glean-stop` disables both.
In an interactive Emacs with roots configured, the package starts these hooks
and queues an initial reconciliation at startup.

`org-glean-status` reports index health (`ready`/`degraded`/`unavailable`),
configured roots, indexed source/target counts, and the last reconciliation's
time and errors. `org-glean-show-errors` opens a buffer with the latest
reconciliation and search-provider failures.

`org-glean-search-api` accepts an explicit `MODES` list among `exact`,
`lexical`, `fuzzy` and `semantic`. Every requested mode collects its own
bounded candidates independently and they are combined by weighted
reciprocal-rank fusion (`org-glean-fusion-weights`, `org-glean-fusion-k`):
an exact match is always pinned first, and beyond that a strong semantic
hit can outrank a weak lexical one instead of losing by mode alone. No
PyTorch and no third-party embedding library: the local backend is our
own `onnxruntime` + `tokenizers` wrapper (see `ROADMAP.md` phase 1).

## Using semantic search

Install a model once:

```elisp
M-x org-glean-install
```

This creates a package-private `uv` environment, asks for one explicit
consent naming the model (default `e5-small`, swappable via
`org-glean-semantic-model` to `e5-base` or `bge-m3`) and its approximate
download size, downloads it, and runs a self-test before reporting
success. Saves and reconciliation then queue a background embedding pass
automatically; `org-glean-status` reports coverage (how many chunks have
been embedded) and the queue's state.

Once installed, `semantic` is included automatically wherever modes are
not specified — `org-glean-find`, `org-glean-search-buffer`, and MCP. Set
`org-glean-default-modes` to override this. Requesting `semantic` before
the model is installed, or during a genuine query failure, is honestly
reported via `provider-errors` rather than silently dropped or served
from another provider's results.

Default key bindings, under `org-glean-keymap-prefix` (default `M-s g`;
set to nil to disable and bind `org-glean-command-map` yourself):

| Key | Command |
|---|---|
| `M-s g g` | `org-glean-find` — pick and visit a result |
| `M-s g G` | `org-glean-search-buffer` — show results in a buffer |
| `M-s g s` | `org-glean-find-semantic` — semantic-only pick and visit |
| `M-s g S` | `org-glean-search-buffer-semantic` — semantic-only results buffer |
| `M-s g r` | `org-glean-reconcile` |
| `M-s g i` | `org-glean-status` (one-line summary) |
| `M-s g e` | `org-glean-show-errors` |
| `M-s g p` | `org-glean-semantic-toggle` — pause/resume the embedding queue |

Inside a results buffer: `s` toggles between the buffer's normal modes and
semantic-only (and back), `e` expands/collapses grouped fuzzy hits, `g`
refreshes, `TAB` previews, `RET` visits. The "Via" column shows which
modes found each result (e.g. `sem+lex`).

With `rhblind/emacs-mcp-server` installed, load `org-glean-mcp.el` to register
the read-only `org-glean_search` tool. Set `org-glean-mcp-allowed-roots` to the
caller-approved roots before exposing it to an agent. Results include a
versioned result set, freshness state, provisional/stable target identity,
match reason, score and margin. Completeness is `complete`, `truncated`, or
`incomplete`; callers must not treat an incomplete empty result as a definitive
miss.

Run synthetic-fixture tests with:

```sh
emacs --batch -Q -L . -L test -l test/org-glean-test.el \
  -f ert-run-tests-batch-and-exit
```
