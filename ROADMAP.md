# Roadmap

## Short term

1. Manual, transactional recursive reconciliation of configured Org roots.
2. `org-element` file and heading projections, including ID-less headings.
3. SQLite exact/FTS search and a completion picker with safe navigation.
4. The first manual-reconciliation/search/picker slice is implemented and
   verified against temporary synthetic fixtures.
5. Save-triggered updates and configurable periodic full-tree reconciliation
   (initial proposal: 600 seconds).
6. Bounded fuzzy heading/title candidates and an exploration side buffer.

## Mid term

- Compare lexical/vector providers using the same Org projections and
  conformance fixtures; preserve generation consistency across stores.
- Generic link/metadata filters and structural retrieval.
- Optional local multilingual semantic provider, model freshness checks.
- Optional headless CLI consuming a versioned Emacs-exported configuration.

The broader Agentic Setup MVP still asks for semantic search; making it an
optional `org-glean` provider does not close that system-level requirement.
