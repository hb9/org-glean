# org-glean

Local semantic retrieval for an Org corpus, for agents and humans. Exact,
lexical (FTS5) and fuzzy title/heading search are implemented today and work
as evidence signals feeding future semantic fusion — Org Glean's actual
reason to exist is answering queries that share no words with the right
target, which is not yet implemented. See [DESIGN.md](DESIGN.md) for the full
vision and architecture, and [ROADMAP.md](ROADMAP.md) for phases and current
status. Emacs owns configuration and interaction; the index is derived from
Org and can always be rebuilt. Requires Emacs 29+ compiled with SQLite FTS5
support. This project is under active development; no release has been cut.

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
`lexical`, `fuzzy` and `semantic`. `semantic` is a recognized mode name today,
but no semantic provider ships yet — requesting it is honestly reported as
`provider-errors` rather than silently dropped or served by another provider
(`org-glean-semantic-provider` defaults to nil; see `ROADMAP.md` phase 1 for
the planned local ONNX-based backend, with no PyTorch and no third-party
embedding library dependency).

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
