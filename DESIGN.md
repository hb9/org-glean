# org-glean — first slice

Org files are canonical. A local SQLite database is disposable derived state.
The package reads sources, never assigns IDs or writes Org. Emacs 29+ with
SQLite/FTS5 is the first runtime; capability failure is explicit.

## Boundaries

1. Root discovery accepts named roots and include/exclude patterns. It never
   follows directory symlinks or accepts a source escaping its root.
2. An `org-element` projector reads one saved file and emits file/heading
   records with source ownership. Org `ID` is optional; ID-less headings have
   snapshot-scoped occurrence keys and provisional navigation.
3. The reconciler compares a manifest with recursive discovery. It adds,
   replaces, skips or removes whole sources transactionally. A parse failure
   leaves the previous indexed version intact.
4. A SQLite/FTS5 writer owns the first materialization. Exact and FTS queries
   return bounded, typed results. A completion picker navigates after checking
   that the source snapshot still matches the index.

These interfaces are logical ports so watchers, writers, and search engines can
be changed independently. The first implementation may share one Lisp file.
File notifications are not an authoritative source of truth. A future Emacs
frontend supplies save hooks and periodic reconciliation; an optional CLI must
use the same application semantics and Emacs-exported configuration, not its
own separately edited settings.

## First slice acceptance

- Temporary fixtures only: nested files, duplicate ID-less headings, moves,
  deletion, unchanged no-op, changed source replacement, and parse errors.
- Full reconciliation twice yields identical logical targets and no row growth.
- A failed source replacement leaves the prior searchable rows intact.
- A saved file can be searched by exact heading/title and FTS body terms.
- Bounded results identify source, heading, stability and navigation hint.
- The picker does not silently open an ambiguous/stale provisional heading.

No semantic model, fuzzy ranking, structural graph or CLI is in this slice.
Those capabilities remain separate provider/front-end decisions.
