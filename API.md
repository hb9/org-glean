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

Generic filters include `:allowed-roots`, `:exclude-property-values`,
`:property-equals`, `:max-heading-level`, and `:exclude-titles`. They are
applied before the caller-visible result limit for every mode, including
`semantic`. Requesting `semantic` when `org-glean-semantic-provider` is nil,
or when it is configured but the active model is not installed
(`M-x org-glean-install`), is honestly reported as unavailable via
`provider-errors` — never silently dropped, never served from another
provider's results. When the model is installed, `semantic` returns
targets whose owning chunk best matches the query by embedding similarity,
aggregated by max score per target (see `ROADMAP.md` phase 1 for the
chunk-to-target aggregation and phase 2 for planned chunk/heading/file
granularity and calibrated rank fusion; today, ordering across modes is
still priority-tier: exact, then lexical, then semantic, then fuzzy).
Unsupported modes or filter operators must be reported, never silently
treated as applied.

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
 :score NUMBER
 :source-current BOOLEAN
 :rank INTEGER
 :margin NUMBER
 :match-reason STRING
 :link STRING)
```

The current stable identity is `:org-id` when present; otherwise `:key` is
snapshot-scoped. The current result-set schema is versioned at the outer level;
result items do not yet have their own schema-version field. A link is a
navigation hint, not permission to bypass freshness/ambiguity checks. Backends
should map this row-compatible v1 representation to the canonical source/target
port types during the planned extraction. Planned phase 1 additions: a
`:granularity` value (`chunk`/`heading`/`file`) and a list of all contributing
modes per result, not just the top `:match-type` (see `ROADMAP.md` phase 1–2).

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
(org-glean-search-buffer QUERY &optional FILTERS) ; -> results buffer
(org-glean-find QUERY)                        ; -> selected result / quit value
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
```

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

`org-glean-search-api` accepts these filter plist keys:

```elisp
(:allowed-roots DIRECTORY-LIST
 :exclude-property-values STRING-LIST
 :property-equals ((PROPERTY . VALUE) ...)
 :max-heading-level POSITIVE-INTEGER
 :exclude-titles STRING-LIST)
```

The optional `:allowed-roots` value is fail-closed when explicitly supplied as
an empty list. When omitted from a local Lisp call, configured `org-glean-roots`
govern search. MCP always requires a non-empty explicit allowed-root set.

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
