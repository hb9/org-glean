# Roadmap

## Short term

1. Manual, transactional recursive reconciliation of configured Org roots;
   versioned public API values and search semantics are specified in `API.md`.
2. `org-element` file and heading projections, including ID-less headings.
3. SQLite exact/FTS search and a completion picker with safe navigation.
4. Save-triggered updates, initial/startup and configurable periodic full-tree
   reconciliation (600-second default), bounded fuzzy results and exploration
   side buffer are implemented and verified against temporary fixtures.
5. Thin, bounded MCP search adapter is implemented for the current Emacs MCP
   registry as `org-glean_search`; metadata filters and allowed-root scope are
   applied before result limits. Doom integration is configured separately.
6. Compare Org Glean candidates against `orgk --for-capture`; preserve the
   semantic fallback until a semantic provider is integrated and validated.

Results buffer uses Emacs `tabulated-list-entries` rows in `(ID [COLUMNS])`
format; it orders exact/lexical/fuzzy hits, groups repeated fuzzy file/title hits
with `e` to expand/collapse, maps `TAB` to preview without taking focus and
`RET` to jump to the selected (including expanded group-member) heading by ID.
Lexical scores preserve BM25 ordering and are ranked above fuzzy candidates.
These behaviors are covered by synthetic-corpus tests.

Search providers page candidates until filters have filled the requested result
limit or their candidate set is exhausted. A shared work budget bounds exact,
lexical, and fuzzy retrieval; responses distinguish complete results,
result-limit truncation, and work-budget incompleteness. MCP fails closed when
no allowed roots are configured and applies its root scope during retrieval.
Adversarial tests cover excluded prefixes, out-of-scope prefixes, and incomplete
empty results.

## Mid term

- Compare lexical/vector providers using the same Org projections and
  conformance fixtures; preserve generation consistency across stores.
- Generic link/metadata filters and structural retrieval.
- Optional local multilingual semantic provider, model freshness checks.
- Optional headless CLI consuming a versioned Emacs-exported configuration.

The broader Agentic Setup MVP still asks for semantic search; making it an
optional `org-glean` provider does not close that system-level requirement.
