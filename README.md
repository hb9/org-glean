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
```

The root tuple is `(NAME DIRECTORY INCLUDE-REGEXPS EXCLUDE-REGEXPS)`; patterns
match root-relative file paths, and only `.org` files are indexed. The database
defaults to `org-glean.sqlite` under `user-emacs-directory`; set
`org-glean-database-file` to choose another disposable index. Search functions
return at most 100 typed results. Existing Org IDs enable move-stable lookup;
ID-less targets are snapshot-scoped and navigation rechecks the source before
opening it.

Run synthetic-fixture tests with:

```sh
emacs --batch -Q -L . -L test -l test/org-glean-test.el \
  -f ert-run-tests-batch-and-exit
```
