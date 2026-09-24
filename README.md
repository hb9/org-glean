# org-glean

Local, read-only search for Org files. Emacs owns configuration and interaction;
the index is derived from Org and can be rebuilt. Requires Emacs 29+ compiled
with SQLite FTS5 support. This project is under active development; no release
has been cut.

See [DESIGN.md](DESIGN.md) for the component contract and [ROADMAP.md](ROADMAP.md)
for first-release and intermediate goals. The originating design is the E2
Org Glean note in `hb9/org-knowledge` (Denote ID `20260923T130815`).

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

With `rhblind/emacs-mcp-server` installed, load `org-glean-mcp.el` to register
the read-only `org-glean_search` tool. Set `org-glean-mcp-allowed-roots` to the
caller-approved roots before exposing it to an agent. Results include a
versioned result set, freshness state, provisional/stable target identity,
match reason, score and margin.

Run synthetic-fixture tests with:

```sh
emacs --batch -Q -L . -L test -l test/org-glean-test.el \
  -f ert-run-tests-batch-and-exit
```
