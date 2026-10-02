# Org Glean application API — contract v1

This document specifies the package-facing Emacs API and its versioned values.
It separates the application contract from SQLite rows, MCP JSON, and the
interactive frontend. The existing first-slice functions remain compatible;
new frontends should use the structured search API.

## Conventions

- Paths are expanded absolute local paths. A path is eligible only when it
  resolves inside an explicitly configured root.
- `org-id` is optional. A target without one has a snapshot-scoped key and a
  provisional location; callers must resolve it against the current source
  snapshot before navigation.
- Search limits are clamped to `1..100`. Candidate work is bounded separately.
- Search completeness has exactly three values: `complete` (all requested
  providers that were applicable completed and their candidate sets were
  exhausted), `truncated` (an additional eligible result proves there are more
  than the caller limit), and `incomplete` (a work budget or provider failure
  prevented determining completeness). An incomplete result is never a
  definitive miss.
- Errors are signalled as Emacs conditions to Lisp callers. The MCP adapter
  translates them to its versioned JSON error object.

## Value types

Schema version `1` values use keyword plists internally and JSON objects at the
MCP boundary. Backends must not expose database row IDs or SQL-specific values.

### Root

```elisp
(:schema-version 1
 :id STRING
 :path ABSOLUTE-DIRECTORY
 :include REGEXP-LIST
 :exclude REGEXP-LIST)
```

The current configuration compatibility form is
`(NAME DIRECTORY INCLUDE-REGEXPS EXCLUDE-REGEXPS)`. Includes are optional; an
empty list selects every `.org` file under the root before excludes are applied.

### Source

```elisp
(:schema-version 1
 :key STRING                 ; root-relative path identity
 :root-id STRING
 :path ABSOLUTE-FILE
 :fingerprint SHA256-STRING
 :parser-version STRING
 :state current-or-stale)
```

The fingerprint describes the exact saved source snapshot projected into the
index. Source replacement and removal are source-owned operations.

### Chunk (schema v2, storage-internal)

Not yet part of the public value contract, but the storage foundation phase 1
builds on:

```sql
chunks(key, target_key, path, ord, text, text_digest)
vectors(model_id, text_digest, dim, vector)
```

A chunk is one embeddable passage owned by a target. A file-level target has
one chunk summarizing its title and shallow heading outline; a heading
target has one chunk per paragraph-aligned window of its outline-path-
prefixed passage, with trailing-paragraph overlap into the next window (see
`org-glean-chunk.el` and `ROADMAP.md` phase 1). A vector is keyed on
`(model_id, text_digest)` alone, never on a chunk or target key, so it
survives reprojection, moves, and even a full reconciliation rebuild of an
otherwise-unchanged passage. `org-glean--replace` rewrites a source's
`chunks` rows wholesale on every change; it never deletes or writes
`vectors`.

### Query

```elisp
(:schema-version 1
 :text STRING
 :modes (exact lexical fuzzy semantic)
 :roots ROOT-ID-LIST         ; nil means configured roots for local Lisp calls
 :kinds (file heading ...)   ; planned phase 2: chunk/heading/file granularity
 :filters FILTER-PLIST
 :limit INTEGER
 :purpose SYMBOL-OR-NIL)
```

Generic filters include `:allowed-roots`, `:property-filters`,
`:max-heading-level`, and `:exclude-titles`. They are
applied before the caller-visible result limit for every mode, including
`semantic`. Requesting `semantic` when `org-glean-semantic-provider` is nil,
or when it is configured but the active model is not installed
(`M-x org-glean-install`), is honestly reported as unavailable via
`provider-errors` — never silently dropped, never served from another
provider's results. When the model is installed, `semantic` returns
targets whose owning chunk best matches the query by embedding similarity,
aggregated by max score per target, after mean-centering and a hub-
similarity correction (`org-glean-semantic-hub-lambda`) and a z-score
threshold relative to the query's own candidate pool
(`org-glean-semantic-min-z`, `org-glean-semantic-max-hits`) — see
README.md's "Semantic ranking quality" for why raw cosine similarity alone
is not used. A semantic hit's fusion weight is itself scaled by its
z-score, so a hit that only barely cleared the threshold contributes far
less than a confident one. Every requested mode collects its own
candidate pool independently (`org-glean-fusion-pool-size`, default 50) so
one mode's result volume never crowds another out; candidates are then
merged by target and ranked by weighted reciprocal-rank fusion
(`org-glean-fusion-weights`, `org-glean-fusion-k`) — exact matches are
pinned above the fused order, ties broken by fused score then best
contributing rank, so ordering is deterministic for a given generation and
query. Chunk/heading/file caller-selected granularity remains planned
(`ROADMAP.md` phase 2). Unsupported modes or filter operators must be
reported, never silently treated as applied.

### Result (current API v1)

```elisp
(:key STRING
 :path ABSOLUTE-FILE
 :kind "file"-or-"heading"
 :title STRING
 :org-id STRING-OR-NIL
 :position INTEGER
 :digest SHA256-STRING
 :snippet STRING
 :capture-policy STRING
 :level INTEGER
 :outline-path STRING-LIST
 :properties PROPERTY-ALIST
 :match-type exact-or-lexical-or-fuzzy-or-semantic
 :modes ((MODE RANK RAW-SCORE Z-OR-NIL) ...)
 :score NUMBER
 :source-current BOOLEAN
 :rank INTEGER
 :margin NUMBER
 :match-reason STRING
 :link STRING)
```

`:match-type` is the single strongest contributor (by fusion weight); `:modes`
lists every mode that found this target, each with its own 0-based RANK
within that mode's candidate pool and a provider-specific RAW-SCORE (never
compared across modes directly — only ranks feed the fusion formula). Z is
the semantic backend's z-score for a `semantic` entry (nil for every other
mode); `:match-reason` renders it as e.g. `"semantic #1 z5.8"` when present.
`:score` is the fused result across all contributing modes, not any one
provider's raw relevance number. The current stable identity is `:org-id`
when present; otherwise `:key` is snapshot-scoped. The current result-set
schema is versioned at the outer level; result items do not yet have their
own schema-version field. A link is a navigation hint, not permission to
bypass freshness/ambiguity checks. Backends should map this row-compatible
v1 representation to the canonical source/target port types during the
planned extraction. Planned phase 2 addition: a `:granularity` value
(`chunk`/`heading`/`file`).


### Result set

The structured search API returns an alist with these fields:

| Field | Meaning |
| --- | --- |
| `schema-version` | Result-set schema; currently `1`. |
| `query` | Original query string. |
| `requested` | Alist of requested mode to `t`, one entry per requested provider mode. |
| `used` | Providers completed successfully; failed providers are listed separately. |
| `degraded` | `:false`, `incomplete` for exhausted work budget, or `provider-error` when one or more requested providers failed. |
| `freshness` | `stale-source-present`, `index-checked`, or `sources-checked-current`. |
| `limit` | Clamped caller-visible result limit. |
| `candidate-count` | Number of returned candidates, at most `limit`. |
| `completeness` | `complete`, `truncated`, or `incomplete`. |
| `truncated` | True for `truncated` and `incomplete`; false only for `complete`. |
| `work-examined` | Number of provider candidates examined under the request budget. |
| `provider-errors` | Vector of objects with `provider` and `message`; empty when no provider failed. |
| `results` | Vector of typed result plists. |

Freshness and completeness are independent. A result set can be complete but
contain a stale source, or incomplete with no returned candidates. Failed
providers are omitted from `used`, listed in `provider-errors`, and force
`completeness` to `incomplete` even if another provider returned candidates.
When a provider fails, applicable secondary providers are still attempted if
the remaining work budget permits.

### Status and error

Status values use `(:schema-version 1 :state STATE ...)`, where `STATE` is one
of `ready`, `degraded`, or `unavailable` (`indexing` is reserved for a planned
asynchronous reconciliation path; the current synchronous
`org-glean-reconcile` runs to completion before returning). Optional fields
report configured roots, indexed source/target counts, last reconciliation
time and counts, and recorded errors. `:semantic-state` is `unavailable` if
`org-glean-semantic-provider` is nil (no provider function at all), `ready`
if a provider is configured and the active model's backend is installed
(`org-glean-embed-available-p`), or `not-installed` if a provider is
configured but the model has not been installed yet (run
`M-x org-glean-install`). `:semantic-model` names the
active preset (`org-glean-semantic-model`, default `"e5-small"`).
`:semantic-coverage-chunks`/`:semantic-coverage-total` report how many of the
index's chunks have a vector for the active model — a per-chunk fact, never
a single global stale/fresh flag, so one save never invalidates semantic
search for the rest of the corpus. `:semantic-queue-state` is `idle`,
`running`, or `paused`, reflecting the background embedding queue
(`org-glean-semantic-queue-start`/`-pause`/`-resume`) that closes any
coverage gap without blocking interactive use. Status inspection is
read-only. `org-glean-show-errors` renders the same reconciliation and
search-provider failures in a dedicated buffer.

Errors are conditions, not result-set states. The v1 condition families are:

- `org-glean-error`: base condition for package errors.
- `org-glean-configuration-error`: invalid or ambiguous roots/configuration.
- `org-glean-capability-error`: required Emacs/SQLite/FTS capability absent.
- `org-glean-source-error`: source could not be read or projected; previous
  indexed source rows remain active.
- `org-glean-stale-result`: the indexed source snapshot no longer matches.
- `org-glean-ambiguous-result`: identity/location cannot be resolved uniquely.
- `org-glean-query-error`: invalid query or unsupported requested mode/filter.

Current implementation may still signal built-in `error` or `user-error`; the
named condition hierarchy is the contract to adopt as the application API is
extracted.

## Function signatures

### Implemented first-slice entry points

```elisp
(org-glean-reconcile)                         ; -> reconciliation count plist
(org-glean-update-file PATH)                  ; -> t if selected, nil otherwise
(org-glean-search-exact TITLE &optional LIMIT) ; -> result plist list
(org-glean-search QUERY &optional LIMIT FUZZY) ; -> result plist list
(org-glean-search-api QUERY &optional LIMIT FUZZY FILTERS MODES)
                                              ; -> versioned result-set alist
(org-glean-open-result RESULT &optional PREVIEW) ; -> source buffer
(org-glean-visit RESULT)                      ; -> source buffer
(org-glean-search-buffer QUERY &optional FILTERS MODES) ; -> results buffer
(org-glean-search-buffer-semantic QUERY &optional FILTERS) ; -> results buffer, semantic-only
(org-glean-find QUERY)                        ; -> selected result / quit value
(org-glean-find-semantic QUERY)               ; -> selected result / quit value, semantic-only
(org-glean-start)                             ; -> nil; idempotently enable updates
(org-glean-stop)                              ; -> nil; disable updates
(org-glean-close)                             ; -> nil; close disposable index
(org-glean-status)                            ; -> versioned status plist
(org-glean-show-errors)                       ; -> diagnostic buffer
(org-glean-install &optional PRESET)          ; -> phase 1: managed backend install
(org-glean-embed-available-p &optional PRESET) ; -> t if PRESET is installed
(org-glean-embed-stop)                        ; -> nil; stop the backend process
(org-glean-semantic-queue-start)              ; -> nil; ensure the background
                                               ;    embedding queue is running
(org-glean-semantic-pause)                    ; -> nil; stop the queue
(org-glean-semantic-resume)                   ; -> nil; restart the queue
(org-glean-semantic-toggle)                   ; -> nil; pause if running, resume if paused
```

`org-glean-find`/`org-glean-search-buffer` use `org-glean--default-modes` when
MODES is omitted: `(exact lexical fuzzy semantic)` once a semantic backend is
installed for the active model, otherwise `(exact lexical fuzzy)`. The
`-semantic` variants force `(semantic)` and signal a `user-error` pointing at
`M-x org-glean-install` if the model is not installed, rather than returning
an empty result silently. `org-glean-default-modes` overrides the automatic
choice for all of these (and for MCP); it does not affect `org-glean-search-api`'s
own lower-level default, which callers of the application API can still rely
on unchanged.

`org-glean-install` is interactive-first (prompts for PRESET via
`completing-read` over the presets in `semantic/presets.json`), asks for one
explicit consent naming the model and its approximate download size, then
creates a package-private `uv` venv, installs backend dependencies,
downloads the model's files, and runs a paraphrase self-test. It signals if
`uv` is missing, if the download or self-test fails, or if PRESET is not a
known name; it never silently downloads anything from ordinary search or
status calls. `org-glean-embed-available-p` is the read-only counterpart:
a pure filesystem check other code (the planned embedding queue, the
semantic provider) uses to decide whether to attempt anything at all.

MODES, when non-nil, is a list among `exact`, `lexical`, `fuzzy` and
`semantic`; it defaults to `(exact lexical)`, with FUZZY as a legacy
shorthand for adding `fuzzy`.

`exact` checks two things, both reported under the same `exact` mode in
a result's `:modes`: a file-level or heading-level target's own title,
and — new, file-level only — a file's `ALIASES` property (the
KIND/STATUS/ROLE/ALIASES convention, capture-workflow note §7.1), split
on whitespace except for a double-quoted run, which counts as one alias
(`split-string-and-unquote`): `ALIASES aistore ai.store OD DMS` makes
"OD" and "DMS" each a separate exact-match alias for that file, even
though neither appears anywhere in its title, while `ALIASES tales "ai
story"` keeps the quoted phrase as one alias rather than splitting it
into "ai" and "story". Matching is exact and case-insensitive, never a
substring or fuzzy match — that is what `fuzzy` mode is for. This is
file-level only: a heading itself has no `ALIASES` of its own. The
candidate pool is pre-filtered in SQL to files whose `properties` blob
mentions `ALIASES` at all, so this stays proportional to actual
`ALIASES` usage (a handful of files in practice) rather than scanning
every file-level target on every search.

`org-glean-search-api` accepts these filter plist keys:

```elisp
(:allowed-roots DIRECTORY-LIST
 :property-filters ((:key STRING :op OP :value STRING :values STRING-LIST) ...)
 :max-heading-level POSITIVE-INTEGER
 :exclude-titles STRING-LIST)
```

`:property-filters` constrains on any inherited Org property (a heading's
own property drawer, or a file-level `#+PROPERTY` line it inherits from) —
this mechanism has no built-in knowledge of any particular property name,
`CAPTURE_POLICY` included. Every entry must match (they are ANDed
together). `OP` is one of `equals`, `not-equals`, `in`, `not-in`,
`exists`, `missing`; `:value` is used by `equals`/`not-equals`, `:values`
by `in`/`not-in`. A property that was never set anywhere on a target is
simply absent — it satisfies `not-equals`/`not-in`/`missing` and fails
`equals`/`in`/`exists`, with no implicit default value substituted for
any property. This is why, for example, filtering out `CAPTURE_POLICY`
values of `"none"` (`:property-filters ((:key "CAPTURE_POLICY" :op not-in
:values ("none")))`) also keeps a target that never set the property at
all: absent is not `"none"`.

`:exclude-property-values`, `:property-key`/`:property-value` and
`:property-equals` are all still accepted (the first two are deprecated
aliases translated into `:property-filters` entries automatically —
`org-glean--normalize-filters` — specifically, `:exclude-property-values`
becomes a `not-in` filter on `CAPTURE_POLICY`, since that was the only
property it was ever able to constrain; `:property-equals` is a separate,
still-current mechanism for several exact key/value requirements at once:
`((PROPERTY . VALUE) ...)`, all required). New callers wanting anything
other than plain equality on several properties at once should use
`:property-filters` directly.

The optional `:allowed-roots` value is fail-closed when explicitly supplied as
an empty list. When omitted from a local Lisp call, configured `org-glean-roots`
govern search. MCP always requires a non-empty explicit allowed-root set.

### `org-glean-outline` (whole-file structure, no placement logic)

```elisp
(org-glean-outline FILES &optional MAX-LEVEL)
;; -> ((:outlines . (OUTLINE ...)) (:errors . (((:path . PATH) (:message . STRING)) ...)))
```

Once `org-glean-search`/`org-glean-search-api` has named a plausible
destination file, an agent needs that file's actual structure to decide
*where* within it something belongs — an existing task section, an
existing cluster of active TODOs, or a new heading at the end.
`org-glean-outline` returns that structure; it makes no placement
decision itself (see `ROADMAP.md`'s explicit scope note — this is a
deliberate boundary, not a missing feature).

`FILES` is one path or a list of paths (e.g. the top few candidate files
from a search). One `OUTLINE` is:

```elisp
((:path . STRING) (:title . STRING) (:properties . PROPERTY-ALIST)
 (:headings . (HEADING ...)) (:heading-count . INTEGER) (:truncated . BOOLEAN))
```

and one `HEADING`:

```elisp
((:level . INTEGER) (:title . STRING) (:todo-keyword . STRING-OR-NIL)
 (:closed . BOOLEAN) (:priority . STRING-OR-NIL) (:tags . STRING-LIST)
 (:org-id . STRING-OR-NIL) (:outline-path . STRING-LIST)
 (:properties . PROPERTY-ALIST))
```

`:closed` is whether `:todo-keyword` is one of Org's own done keywords
(`org-done-keywords`, honoring a file's own `#+TODO:` line), so a caller
does not need to know Org's keyword sets itself to skip DONE/CANCELLED
entries when judging active task structure. `MAX-LEVEL`, when given,
omits headings deeper than it from `:headings`; `:heading-count` and
`:truncated` always describe the *whole* file regardless, since
`org-glean-outline-max-headings` (a hard response-size cap, default 500)
is a different concern from the depth filter.

Every file is read fresh from disk into a throwaway temp buffer — never a
live Emacs buffer, exactly like `org-glean-project.el`'s own indexing
pass. This means no auto-id side effect (unlike MCP `org-get-node`/
`org-search` with `mcp-server-emacs-tools-org-auto-id` on) and no
reflection of unsaved edits in an open buffer: this is a pure read, it
never writes anything, anywhere, ever. A missing or unparseable path
never aborts the other requested files — it is collected in `:errors`,
the same pattern `org-glean-search-api` uses for `provider-errors`.

The MCP tool `org-glean_outline` wraps this with the same allowed-roots
enforcement `org-glean_search` uses: a requested path outside every
allowed root is reported as a per-file error (`"Path is outside every
allowed root"`), not silently dropped or a reason to fail every other
requested file.

### Planned entry points

`org-glean-status`, `org-glean-show-errors` and `org-glean-install` are
implemented (see above and below). These names are reserved by the
application contract but not yet implemented:

```elisp
(org-glean-rebuild &optional ROOT-IDS)         ; -> reconciliation count plist
(org-glean-resolve IDENTITY)                  ; -> current result or condition
(org-glean-semantic-status)                   ; -> phase 1: per-model coverage
```

New public operations require a contract test and must preserve the guarantees
above. Implementation modules may add private helpers without expanding this
surface.
