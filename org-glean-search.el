;;; org-glean-search.el --- Exact, lexical and fuzzy candidate providers and fusion -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-store)
(require 'org-glean-project)
(require 'org-glean-semantic)
(require 'sqlite)
(require 'cl-lib)
(require 'subr-x)

(defcustom org-glean-fusion-pool-size 50
  "Minimum number of candidates each provider collects before fusion.
Every requested mode (exact, lexical, fuzzy, semantic) collects up to
`(max LIMIT org-glean-fusion-pool-size)' of its own candidates, filtered
before that cap, independently of how many candidates any other mode
found. This is what lets a semantic hit compete with a lexical one instead
of the lexical pool alone filling the caller-visible result limit before
semantic search ever gets a chance to contribute."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-fusion-weights
  '((exact . 1.0) (semantic . 1.0) (lexical . 0.8) (fuzzy . 0.3))
  "Per-mode weight in weighted reciprocal-rank fusion.
A mode absent from this alist contributes weight 0, i.e. its candidates
degrade to appearing only if some other mode also found the same target."
  :type '(alist :key-type symbol :value-type number)
  :group 'org-glean)

(defcustom org-glean-fusion-k 60
  "Rank-fusion smoothing constant.
Each mode's contribution to a target's fused score is
`weight / (org-glean-fusion-k + rank + 1)', RANK being 0-based. A larger
K flattens the difference between a mode's rank-1 and rank-20 candidates;
60 is the commonly used default for reciprocal-rank fusion."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-semantic-min-z 3.0
  "Minimum z-score (see `org-glean--embed-request-sync' `search' op) a
semantic hit must clear to be considered at all. Chosen against the
user's real corpus: every known-good query in that measurement reached
at least this z after mean-centering and hub correction, while it still
excludes most of the long, nearly-indistinguishable tail that plain
cosine similarity cannot separate. A query with no strong match anywhere
in the corpus can legitimately return nothing at this threshold -- that
is a correct result, not a bug; see `org-glean-eval' for how to check
this default against your own corpus."
  :type 'number
  :group 'org-glean)

(defcustom org-glean-semantic-hub-lambda 0.5
  "Hub-correction strength passed to the embedding backend's `search' op.
Subtracted, scaled by this factor, from each candidate's centered cosine
before ranking; see semantic/org_glean_embed.py for the derivation.
Validated together with `org-glean-semantic-min-z' against a real corpus:
0 (no correction) let generically-similar hub chunks outrank the actual
match for several known-good queries."
  :type 'number
  :group 'org-glean)

(defcustom org-glean-semantic-max-hits 10
  "Hard cap on semantic candidates contributed to fusion for one query,
applied after `org-glean-semantic-min-z' filtering. Keeps a query that
clears the z-threshold broadly (rather than sharply, for one obvious
target) from flooding fusion with a long tail of merely-plausible hits."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-default-modes nil
  "Provider modes requested by the interactive commands and MCP when the
caller does not specify any. Nil (the default) means automatic:
`(exact lexical fuzzy semantic)' once a semantic backend is configured
and installed for the active model (`org-glean-embed-available-p'),
otherwise `(exact lexical fuzzy)'. Set this explicitly to override the
automatic choice, for example to keep fuzzy out of the default search
once semantic search covers \"close but not exact\" queries better.

This governs `org-glean-find', `org-glean-search-buffer' and the MCP
adapter. It does not change `org-glean-search-api's own low-level
default (`(exact lexical)', plus `fuzzy' only when its FUZZY argument is
non-nil) — existing programmatic callers of the application API keep
their current behavior unless they ask for `org-glean--default-modes'
themselves."
  :type '(choice (const :tag "Automatic" nil) (repeat symbol))
  :group 'org-glean)

(defun org-glean--default-modes ()
  "Return the modes the interactive commands and MCP use by default."
  (or org-glean-default-modes
      (if (and org-glean-semantic-provider
               (org-glean-embed-available-p org-glean-semantic-model))
          '(exact lexical fuzzy semantic)
        '(exact lexical fuzzy))))

(defun org-glean-search-exact (title &optional limit)
  "Return at most LIMIT targets whose title exactly matches TITLE."
  (org-glean--results
   (sqlite-select (org-glean--db)
                   "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE title=? ORDER BY path,position LIMIT ?"
                  (vector title (max 1 (min 100 (or limit 20)))))))

(defun org-glean-search (query &optional limit fuzzy)
  "Search exact and FTS targets for QUERY, returning at most LIMIT results.
When FUZZY is non-nil, add bounded fuzzy candidates."
  (car (org-glean-search-filtered query limit fuzzy nil)))

(defun org-glean--fts-pattern (query)
  "Return a safely quoted FTS5 prefix query for QUERY, or nil if empty."
  (let ((words (split-string (string-trim (or query "")) "[[:space:]]+" t)))
    (when words
      (mapconcat (lambda (word)
                   (concat "\"" (replace-regexp-in-string "\"" "\"\"" word t t) "\"*"))
                 words " AND "))))

(defun org-glean--properties-match-p (properties requirements)
  "Return non-nil when PROPERTIES satisfies every key/value REQUIREMENT."
  (when (eq properties :null) (setq properties nil))
  (cl-every
   (lambda (requirement)
     (let* ((key (if (symbolp (car requirement))
                     (symbol-name (car requirement)) (car requirement)))
            (actual (cl-some (lambda (property)
                               (when (equal key (if (symbolp (car property))
                                                    (symbol-name (car property))
                                                  (car property)))
                                 (cdr property)))
                             properties)))
       (equal (cdr requirement) actual)))
   requirements))

(defun org-glean--property-lookup (properties key)
  "Return KEY's value in generic PROPERTIES, case-insensitively, or nil.
PROPERTIES is the alist stored on a result item's :properties field (an
Org property drawer plus any inherited file-level #+PROPERTY lines,
already merged by the projector — see `org-glean--properties' in
org-glean-project.el). A property that was never set anywhere for this
target is simply absent from this alist; there is no default-value
fallback here for any property name, `CAPTURE_POLICY' included — any
such interpretation is a caller's job, done by inspecting the dedicated
`:capture-policy' result field, which is where the target's own default
of \"eligible\" already lives (see the projector)."
  (when (eq properties :null) (setq properties nil))
  (cl-some (lambda (property)
             (let ((name (if (symbolp (car property))
                             (symbol-name (car property)) (car property))))
               (when (equal (downcase name) (downcase key))
                 (cdr property))))
           properties))

(defun org-glean--property-filter-match-p (properties filter)
  "Return non-nil when PROPERTIES satisfies one property FILTER.
FILTER is a plist: `(:key STRING :op OP :value STRING :values LIST)'. OP
is one of `equals', `not-equals', `in', `not-in', `exists', `missing'
(symbols). Value comparison is case-insensitive, matching every other
string comparison in this file. A property that is absent from
PROPERTIES simply has no value: it satisfies `not-equals'/`not-in' and
`missing', and fails `equals'/`in'/`exists' — there is no implicit
default value for any property name, including `CAPTURE_POLICY'; that is
what makes this mechanism generic rather than a hard-coded special case."
  (let* ((key (plist-get filter :key))
         (op (plist-get filter :op))
         (actual (org-glean--property-lookup properties key)))
    (pcase op
      ('exists (and actual t))
      ('missing (not actual))
      ('equals (and actual (equal (downcase actual)
                                  (downcase (or (plist-get filter :value) "")))))
      ('not-equals (not (and actual (equal (downcase actual)
                                           (downcase (or (plist-get filter :value) ""))))))
      ('in (and actual (member (downcase actual)
                               (mapcar #'downcase (plist-get filter :values)))))
      ('not-in (not (and actual (member (downcase actual)
                                        (mapcar #'downcase (plist-get filter :values))))))
      (_ (error "org-glean: unknown property filter op %S" op)))))

(defun org-glean--property-filters-match-p (properties property-filters)
  "Return non-nil when PROPERTIES satisfies every filter in PROPERTY-FILTERS."
  (cl-every (lambda (filter) (org-glean--property-filter-match-p properties filter))
            property-filters))

(defun org-glean--filtered-out-p (item filters)
  "Return non-nil if ITEM does not satisfy FILTERS.
FILTERS' `:property-filters' is the general mechanism for constraining on
any inherited property (see `org-glean--property-filters-match-p'); it
has no special knowledge of any particular property name. `:exclude-
property-values' and `:property-equals' remain accepted for callers who
have not moved to `:property-filters' yet, but are deprecated — see
`org-glean--eligible-p''s docstring for what they translate to. This
file has no hard-coded property name anywhere else."
  (or (and (plist-get filters :max-heading-level)
           (equal (alist-get :kind item) "heading")
           (> (or (alist-get :level item) 0) (plist-get filters :max-heading-level)))
      (member (downcase (or (alist-get :title item) ""))
              (mapcar #'downcase (plist-get filters :exclude-titles)))
      (not (org-glean--properties-match-p
            (alist-get :properties item) (plist-get filters :property-equals)))
      (not (org-glean--property-filters-match-p
            (alist-get :properties item) (plist-get filters :property-filters)))))

(defun org-glean--normalize-filters (filters)
  "Translate FILTERS' deprecated keys into `:property-filters' entries.

`:exclude-property-values VALUES' translates to a `not-in' filter on
`CAPTURE_POLICY' — the only property it was ever able to constrain — so
existing callers of the Elisp API and the MCP `exclude_property_values'
parameter keep working unchanged. `:property-key'/`:property-value'
translate to a single `equals' filter on whatever property name the
caller gave. New callers should use `:property-filters' directly instead
of either; this is the one place any of the old names is still
mentioned, everywhere else in this file the filtering mechanism has no
built-in knowledge of any particular property."
  (let ((exclude-values (plist-get filters :exclude-property-values))
        (property-key (plist-get filters :property-key))
        (property-value (plist-get filters :property-value))
        (extra nil))
    (when exclude-values
      (push (list :key "CAPTURE_POLICY" :op 'not-in :values exclude-values) extra))
    (when (and property-key property-value)
      (push (list :key property-key :op 'equals :value property-value) extra))
    (if extra
        (plist-put (copy-sequence filters) :property-filters
                   (append (plist-get filters :property-filters) extra))
      filters)))

(defun org-glean--eligible-p (item filters)
  "Return non-nil when ITEM passes FILTERS, including allowed-root scope."
  (let ((roots-specified (plist-member filters :allowed-roots))
        (roots (plist-get filters :allowed-roots)))
    (and (not (org-glean--filtered-out-p item filters))
         (or (not roots-specified)
             (and roots (org-glean--in-roots-p item roots))))))

(defun org-glean--collect-provider (db sql params filters limit budget page-size seen)
  "Read provider candidates in pages, filtering before filling LIMIT.
Return (ITEMS EXAMINED INCOMPLETE EXTRA)."
  (let ((offset 0) (examined 0) (items nil) (extra nil) (done nil))
    (while (and (not done) (< examined budget) (not extra)
                (< (length items) (1+ limit)))
      (let* ((size (min page-size (- budget examined)))
             (rows (org-glean--results
                    (sqlite-select db sql (vconcat params (vector size offset))))))
        (setq examined (+ examined (length rows))
              offset (+ offset (length rows))
              done (< (length rows) size))
        (cl-incf org-glean--provider-work-count (length rows))
        (dolist (item rows)
          (when (or (not (file-exists-p (alist-get :path item)))
                    (not (equal (alist-get :digest item)
                                (org-glean--digest (alist-get :path item)))))
            (setq org-glean--provider-stale-seen t))
          (unless (gethash (alist-get :key item) seen)
            (when (org-glean--eligible-p item filters)
              (if (>= (length items) limit)
                  (setq extra t)
                (puthash (alist-get :key item) t seen)
                (push item items)))))))
    (list (nreverse items) examined
          (and (not done) (not extra) (>= examined budget)
               (<= (length items) limit))
          extra)))

(defun org-glean--parse-aliases (value)
  "Parse an ALIASES property VALUE into a list of alias strings.
Space-separated, except a double-quoted run counts as one alias, e.g.
\"aistore ai.store OD DMS\" -> (\"aistore\" \"ai.store\" \"OD\" \"DMS\"),
each a separate alias, while \"tales \\\"ai story\\\"\" -> (\"tales\"
\"ai story\"), the quoted phrase kept as one."
  (and value (not (string-empty-p (string-trim value)))
       (ignore-errors (split-string-and-unquote value))))

(defun org-glean--collect-alias (db query filters limit budget page-size seen)
  "Collect file-level targets whose configured alias properties have
QUERY as one alias, exactly (case-insensitively), not a substring.
Which properties count as alias lists is read from
`org-glean-alias-properties', not hard-coded here — org-glean has no
built-in idea of what an alias is, any more than it has one of what
CAPTURE_POLICY means; a caller with no such convention configured gets
no rows and no cost at all, handled by the caller before this is ever
invoked (see its call site). This is not fuzzy or partial matching —
see `org-glean--collect-fuzzy' for that."
  (let* ((needle (downcase (string-trim query)))
         (properties org-glean-alias-properties)
         ;; A LIKE pre-filter per configured property name is cheap, not
         ;; the match itself: it only narrows to files whose header
         ;; mentions at least one configured alias-property name at all
         ;; (expected to be a handful of files, out of the whole corpus),
         ;; before the real per-alias comparison below. Without it this
         ;; would scan every file-kind row on every search, inflating
         ;; `work-examined' in proportion to total corpus size rather
         ;; than actual alias-property usage.
         (like-clause (mapconcat (lambda (_) "properties LIKE ?") properties " OR "))
         (like-params (mapcar (lambda (name) (concat "%" name "%")) properties))
         (sql (format "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE kind='file' AND (%s) ORDER BY path LIMIT ? OFFSET ?" like-clause))
         (offset 0) (examined 0) (done nil) (items nil) (extra nil))
    (while (and (not done) (< examined budget) (not extra)
                (< (length items) (1+ limit)))
      (let* ((size (min page-size (- budget examined)))
             (rows (org-glean--results
                    (sqlite-select db sql (vconcat like-params (vector size offset))))))
        (setq examined (+ examined (length rows))
              offset (+ offset (length rows))
              done (< (length rows) size))
        (cl-incf org-glean--provider-work-count (length rows))
        (dolist (item rows)
          (when (or (not (file-exists-p (alist-get :path item)))
                    (not (equal (alist-get :digest item)
                                (org-glean--digest (alist-get :path item)))))
            (setq org-glean--provider-stale-seen t))
          (unless (gethash (alist-get :key item) seen)
            (when (and (org-glean--eligible-p item filters)
                       (cl-some
                        (lambda (name)
                          (cl-some (lambda (alias) (equal needle (downcase alias)))
                                   (org-glean--parse-aliases
                                    (org-glean--property-value (alist-get :properties item) name))))
                        properties))
              (if (>= (length items) limit)
                  (setq extra t)
                (puthash (alist-get :key item) t seen)
                (setf (alist-get :match-type item) 'exact)
                (push item items)))))))
    (list (nreverse items) examined
          (and (not done) (not extra) (>= examined budget)
               (<= (length items) limit))
          extra)))

(defun org-glean--trigrams (text)
  "Return the unique padded trigrams from TEXT."
  (let ((text (concat "  " (downcase text) "  ")) result)
    (dotimes (index (max 1 (- (length text) 2)))
      (push (substring text index (+ index 3)) result))
    (let ((unique (delete-dups (nreverse result))))
      (if (<= (length unique) 32) unique
        (cl-loop for index below 32
                 collect (nth (/ (* index (1- (length unique))) 31) unique))))))

(defun org-glean--collect-fuzzy (db query filters limit budget page-size seen)
  "Collect typo-tolerant title results from bounded trigram candidates."
  (let* ((needle (downcase (string-trim query)))
         (trigrams (org-glean--trigrams needle))
         (where (mapconcat (lambda (_) "lower(title) LIKE ?") trigrams " OR "))
         (patterns (mapcar (lambda (gram) (concat "%" gram "%")) trigrams))
         (sql (format "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE %s ORDER BY title,path,position LIMIT ? OFFSET ?" where))
         (scan-cap (min budget org-glean-fuzzy-candidate-limit))
         (offset 0) (examined 0) (done nil) scored extra)
    (while (and (not done) (< examined scan-cap) (not extra))
      (let* ((size (min page-size (- scan-cap examined)))
             (rows (org-glean--results
                    (sqlite-select db sql (vconcat patterns (vector size offset))))))
        (setq examined (+ examined (length rows))
              offset (+ offset (length rows))
              done (< (length rows) size))
        (cl-incf org-glean--provider-work-count (length rows))
        (dolist (item rows)
          (when (or (not (file-exists-p (alist-get :path item)))
                    (not (equal (alist-get :digest item)
                                (org-glean--digest (alist-get :path item)))))
            (setq org-glean--provider-stale-seen t))
          (unless (gethash (alist-get :key item) seen)
            (when (org-glean--eligible-p item filters)
              (let* ((title (downcase (or (alist-get :title item) "")))
                     (scale (max 1 (length needle) (length title)))
                     (similarity (* 100.0 (/ (- scale (string-distance needle title))
                                             (float scale)))))
                (when (>= similarity 60.0)
                  (push (cons similarity item) scored))))))))
    (setq scored (sort scored (lambda (left right) (> (car left) (car right)))))
    (let* ((selected (cl-subseq scored 0 (min (length scored) (1+ limit))))
           (matches (mapcar (lambda (pair)
                              (let ((item (cdr pair)))
                                (puthash (alist-get :key item) t seen)
                                (setf (alist-get :match-type item) 'fuzzy
                                      (alist-get :score item) (* 0.84 (car pair)))
                                item))
                            (cl-subseq selected 0 (min limit (length selected))))))
      (setq extra (> (length scored) (length matches)))
      ;; Hitting scan-cap is "incomplete" only when the shared work BUDGET
      ;; was itself the limiting factor (budget <= org-glean-fuzzy-candidate-limit).
      ;; In the common case BUDGET is far larger than the fuzzy-specific
      ;; candidate cap, so scan-cap = org-glean-fuzzy-candidate-limit; fuzzy
      ;; stopping there reflects its own bounded, typo-tolerant design (an
      ;; OR over trigrams casts a wide net, so this cap is reached on nearly
      ;; every non-trivial query) and says nothing about whether the shared
      ;; budget had room to look further. Conflating the two made
      ;; `completeness' report `incomplete' on almost every search.
      (list matches examined
            (and (not done) (not extra) (>= examined scan-cap)
                 (<= budget org-glean-fuzzy-candidate-limit))
            extra))))

(defun org-glean--set-freshness (item)
  "Set ITEM's :source-current by comparing its recorded digest against disk."
  (setf (alist-get :source-current item)
        (and (file-exists-p (alist-get :path item))
             (equal (alist-get :digest item) (org-glean--digest (alist-get :path item)))))
  item)

(defun org-glean--raw-score (item mode rank)
  "Return a provider-specific score for ITEM found by MODE at 0-based RANK.
Exact and lexical providers do not compute a real relevance number (title
equality and BM25 ordering respectively), so this is a synthetic
rank-derived value, informational only: it is never itself compared across
providers, only each mode's RANK feeds the fusion formula in
`org-glean--fusion-score'. Fuzzy and semantic providers already attach a
real similarity number to :score; that is used as-is."
  (or (alist-get :score item)
      (if (eq mode 'exact) 100.0 (max 85.0 (- 94.0 (* rank 0.01))))))

(defun org-glean--semantic-chunk-hit-targets (db hits)
  "Return (TARGET-KEY SCORE . Z) entries from HITS, highest score first,
deduped by owning target. HITS is a vector of alists with `digest',
`score' and `z', already sorted by the backend descending by score; the
first hit seen for a given target is therefore its best-scoring chunk, so
later duplicate occurrences of the same target are simply skipped rather
than compared. Z is carried through unchanged from that same best chunk,
since it and SCORE describe the same backend decision."
  (let ((best (make-hash-table :test #'equal)) (order nil))
    (cl-loop for hit across hits
             for digest = (alist-get 'digest hit)
             for score = (alist-get 'score hit)
             for z = (alist-get 'z hit)
             for target-key = (caar (sqlite-select
                                     db "SELECT target_key FROM chunks WHERE text_digest = ? LIMIT 1"
                                     (vector digest)))
             when (and target-key (not (gethash target-key best)))
             do (progn (puthash target-key (cons score z) best)
                       (push target-key order)))
    (mapcar (lambda (key) (cons key (gethash key best))) (nreverse order))))

(defun org-glean--semantic-search-provider (query filters limit)
  "Return generic typed semantic candidates for QUERY, FILTERS and LIMIT.
Embeds QUERY, scores it against the backend's in-memory vectors (warming
it from SQLite first if this is a fresh process), aggregates chunk hits up
to their owning target by max score, applies FILTERS the same way every
other provider does, and returns at most `(min LIMIT
org-glean-semantic-max-hits)' target items with :score, :semantic-z and
:source-current set. Signals if the active model's backend is not
installed; the caller (`org-glean-search-filtered') turns that into a
`provider-errors' entry rather than a crash, exactly like any other
provider's failure."
  (let ((model org-glean-semantic-model)
        (db (org-glean--db)))
    (unless (org-glean-embed-available-p model)
      (error "Semantic model %s is not installed; run M-x org-glean-install" model))
    (org-glean--semantic-ensure-warm db model)
    (let* ((response (org-glean--embed-request-sync
                       "search" `((query . ,query)
                                  (k . ,(min 200 (max 50 (* limit 5))))
                                  (min_z . ,org-glean-semantic-min-z)
                                  (hub_lambda . ,org-glean-semantic-hub-lambda))
                       model))
           (hits (or (alist-get 'results response) []))
           (ranked (org-glean--semantic-chunk-hit-targets db hits))
           (cap (min limit org-glean-semantic-max-hits))
           (items nil))
      (cl-loop for (target-key score . z) in ranked
               while (< (length items) cap)
               do (let ((rows (sqlite-select
                               db "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE key = ?"
                               (vector target-key))))
                    (when (= (length rows) 1)
                      (let ((item (car (org-glean--results rows))))
                        (when (org-glean--eligible-p item filters)
                          (setf (alist-get :score item) score
                                (alist-get :semantic-z item) z
                                (alist-get :source-current item)
                                (and (file-exists-p (alist-get :path item))
                                     (equal (alist-get :digest item)
                                            (org-glean--digest (alist-get :path item)))))
                          (push item items))))))
      (nreverse items))))


(defun org-glean--fusion-weight (mode)
  "Return MODE's configured fusion weight, or 0 if unconfigured."
  (or (cdr (assq mode org-glean-fusion-weights)) 0.0))

(defun org-glean--fusion-contribution (mode rank &optional z)
  "Return one mode's reciprocal-rank fusion contribution at 0-based RANK.
For `semantic' hits, Z (the backend's z-score for that hit) scales the
mode's configured weight by `(clamp (/ Z 5.0) 0.0 1.0)': a hit that only
barely cleared `org-glean-semantic-min-z' contributes noticeably less than
one whose z-score reflects a confident, well-separated match. A nil Z
(every other mode, or a semantic candidate somehow missing one, e.g. a
legacy caller) leaves the mode's weight unscaled, matching prior
behavior."
  (let ((weight (org-glean--fusion-weight mode)))
    (when (and (eq mode 'semantic) z)
      (setq weight (* weight (max 0.0 (min 1.0 (/ z 5.0))))))
    (/ weight (float (+ org-glean-fusion-k rank 1)))))

(defun org-glean--fusion-merge (provider-lists)
  "Merge PROVIDER-LISTS, an alist of (MODE . RANKED-ITEMS), by target key.
Each returned item gains a :modes list of (MODE RANK RAW-SCORE Z) entries,
one per contributing provider, and has its :source-current set exactly
once. Z is the semantic backend's z-score (see `org-glean--fusion-
contribution') for a `semantic' entry, or nil for every other mode. Item
identity/base fields come from whichever provider found the target first;
the fields are the same regardless of which provider's SQL query produced
them, since they all describe the same indexed target."
  (let ((table (make-hash-table :test #'equal)) (order nil))
    (dolist (pair provider-lists)
      (let ((mode (car pair)))
        (cl-loop for item in (cdr pair)
                 for rank from 0
                 do (let* ((key (alist-get :key item))
                           (raw (org-glean--raw-score item mode rank))
                           (z (and (eq mode 'semantic) (alist-get :semantic-z item)))
                           (existing (gethash key table)))
                      (if existing
                          (setf (alist-get :modes existing)
                                (cons (list mode rank raw z) (alist-get :modes existing)))
                        (setf (alist-get :modes item) (list (list mode rank raw z)))
                        ;; org-glean--set-freshness adds a *new* alist key, which
                        ;; only takes effect on the list head it is given back as
                        ;; its return value -- it must be reassigned here, not
                        ;; just called for effect.
                        (setq item (org-glean--set-freshness item))
                        (puthash key item table)
                        (push key order))))))
    (mapcar (lambda (key) (gethash key table)) (nreverse order))))

(defun org-glean--fusion-finalize (item)
  "Compute and set ITEM's fused :score, :pinned and :match-type from :modes."
  (let* ((modes (alist-get :modes item))
         (fused (cl-loop for (mode rank _raw z) in modes
                        sum (org-glean--fusion-contribution mode rank z)))
         (primary (car (cl-reduce
                        (lambda (a b) (if (>= (cdr a) (cdr b)) a b))
                        (mapcar (lambda (m) (cons (car m) (org-glean--fusion-contribution
                                                           (car m) (nth 1 m) (nth 3 m))))
                                modes)))))
    (setf (alist-get :score item) fused
          (alist-get :pinned item) (and (assq 'exact modes) t)
          (alist-get :match-type item) primary)
    item))


(defun org-glean--relevance-before-p (left right)
  "Return non-nil if LEFT has higher display relevance than RIGHT.
Exact matches are pinned above the fused order; otherwise ties are broken
by fused :score, then best single contributing rank, so ordering is
deterministic across runs for the same generation and query."
  (let ((left-pinned (alist-get :pinned left))
        (right-pinned (alist-get :pinned right)))
    (cond
     ((and left-pinned (not right-pinned)) t)
     ((and right-pinned (not left-pinned)) nil)
     (t (let ((left-score (or (alist-get :score left) 0))
              (right-score (or (alist-get :score right) 0)))
          (if (/= left-score right-score)
              (> left-score right-score)
            (< (or (alist-get :rank left) most-positive-fixnum)
               (or (alist-get :rank right) most-positive-fixnum))))))))

(defun org-glean-search-filtered (query limit fuzzy filters &optional modes)
  "Search QUERY, applying FILTERS and :allowed-roots before LIMIT.
MODES, when non-nil, is a list of requested provider modes among `exact',
`lexical', `fuzzy' and `semantic'; it defaults to `(exact lexical)', with
FUZZY as a legacy shorthand for adding `fuzzy'. Every requested mode
collects its own candidate pool independently (see
`org-glean-fusion-pool-size'), so a large lexical result set never
prevents semantic or fuzzy candidates from being considered; results are
then merged by target and ranked by weighted reciprocal-rank fusion (see
`org-glean--fusion-merge' and `org-glean--relevance-before-p')."
  (let* ((db (org-glean--db))
         (filters (org-glean--normalize-filters filters))
         (limit (max 1 (min 100 (or limit org-glean-search-limit))))
         (pool (max limit org-glean-fusion-pool-size))
         (budget (max 1 org-glean-search-work-budget))
         (page-size (max 1 (min 200 org-glean-search-page-size)))
         (remaining budget)
         (org-glean--provider-stale-seen nil)
         (used nil)
         (provider-errors nil)
         (modes (or modes (append '(exact lexical) (when fuzzy '(fuzzy)))))
         (provider-lists nil)
         (any-extra nil) (any-incomplete nil))
    (when (memq 'semantic modes)
      (if org-glean-semantic-provider
          (condition-case err
              (let ((items (funcall org-glean-semantic-provider query filters pool)))
                (push (cons 'semantic items) provider-lists)
                (push 'semantic used))
            (error (push (cons 'semantic (error-message-string err)) provider-errors)))
        ;; Explicitly report the missing capability. Never label lexical results
        ;; as semantic or silently claim the requested mode ran.
        (push (cons 'semantic "No semantic provider is configured") provider-errors)))
    (when (and (memq 'exact modes) (stringp query) (not (string-empty-p query))
               (> remaining 0))
      (let ((org-glean--provider-work-count 0))
        (condition-case err
            (let ((page (org-glean--collect-provider
                        db "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE title=? ORDER BY path,position LIMIT ? OFFSET ?"
                        (vector query) filters pool remaining page-size
                        (make-hash-table :test #'equal))))
              (push (cons 'exact (nth 0 page)) provider-lists)
              (setq remaining (- remaining (nth 1 page))
                    any-incomplete (or any-incomplete (nth 2 page))
                    any-extra (or any-extra (nth 3 page)))
              (push 'exact used))
          (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                  (push (cons 'exact (error-message-string err)) provider-errors)))))
    ;; A configured alias property (org-glean-alias-properties, empty by
    ;; default) is one more exact-match surface, e.g. a file whose ALIASES
    ;; property includes "OD DMS" is found by that query even though it
    ;; never appears in its title. Kept as its own query/candidate pool,
    ;; pushed under the same 'exact mode key so it ranks and reports
    ;; exactly like a title match: `org-glean--fusion-merge' merges
    ;; same-key entries fine (see its own contract), and an agent reading
    ;; `match-reason' should not need to know whether "exact" meant title
    ;; or alias. Skipped entirely, no query issued, when no alias property
    ;; is configured — org-glean has no opinion on what an alias is.
    (when (and org-glean-alias-properties
               (memq 'exact modes) (stringp query) (not (string-empty-p (string-trim query)))
               (> remaining 0))
      (let ((org-glean--provider-work-count 0))
        (condition-case err
            (let ((page (org-glean--collect-alias
                        db query filters pool remaining page-size
                        (make-hash-table :test #'equal))))
              (push (cons 'exact (nth 0 page)) provider-lists)
              (setq remaining (- remaining (nth 1 page))
                    any-incomplete (or any-incomplete (nth 2 page))
                    any-extra (or any-extra (nth 3 page)))
              (push 'exact used))
          (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                  (push (cons 'exact (error-message-string err)) provider-errors)))))
    (when (and (memq 'lexical modes) (> remaining 0))
      (let ((fts (org-glean--fts-pattern query)))
        (when fts
          (let ((org-glean--provider-work-count 0))
            (condition-case err
                (let ((page (org-glean--collect-provider
                            db "SELECT t.key,t.path,t.kind,t.title,t.org_id,t.position,t.digest,snippet(target_fts,1,'[',']','…',16),t.capture_policy,t.level,t.outline_path,t.properties FROM target_fts JOIN targets t ON t.rowid=target_fts.rowid WHERE target_fts MATCH ? ORDER BY bm25(target_fts),t.path,t.position LIMIT ? OFFSET ?"
                            (vector fts) filters pool remaining page-size
                            (make-hash-table :test #'equal))))
                  (push (cons 'lexical (nth 0 page)) provider-lists)
                  (setq remaining (- remaining (nth 1 page))
                        any-incomplete (or any-incomplete (nth 2 page))
                        any-extra (or any-extra (nth 3 page)))
                  (push 'lexical used))
              (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                      (push (cons 'lexical (error-message-string err)) provider-errors)))))))
    (when (and (or fuzzy (memq 'fuzzy modes))
               (stringp query) (not (string-empty-p (string-trim query)))
               (> remaining 0))
      (let ((org-glean--provider-work-count 0))
        (condition-case err
            (let ((page (org-glean--collect-fuzzy
                        db query filters pool remaining page-size
                        (make-hash-table :test #'equal))))
              (push (cons 'fuzzy (nth 0 page)) provider-lists)
              (setq remaining (- remaining (nth 1 page))
                    any-incomplete (or any-incomplete (nth 2 page))
                    any-extra (or any-extra (nth 3 page)))
              (push 'fuzzy used))
          (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                  (push (cons 'fuzzy (error-message-string err)) provider-errors)))))
    (let* ((merged (mapcar #'org-glean--fusion-finalize
                           (org-glean--fusion-merge (nreverse provider-lists))))
           (sorted (sort merged #'org-glean--relevance-before-p))
           (has-extra (> (length sorted) limit))
           (stale (or org-glean--provider-stale-seen
                      (cl-some (lambda (item) (not (alist-get :source-current item))) sorted)))
           (results (cl-subseq sorted 0 (min limit (length sorted))))
           (truncated (or any-extra any-incomplete provider-errors has-extra)))
      (setq org-glean--last-search-completeness
            (cond ((or any-incomplete provider-errors) 'incomplete)
                   ((or any-extra has-extra) 'truncated)
                   (t 'complete))
            ;; delete-dups: the ALIASES lookup runs as its own candidate
            ;; pool but is reported under the same 'exact mode key as the
            ;; title lookup (see its call site above), so both can push
            ;; 'exact independently when both ran.
            org-glean--last-search-used (delete-dups (nreverse used))
            org-glean--last-search-provider-errors (nreverse provider-errors))
      (setq org-glean--last-search-examined (- budget remaining))
      (list results truncated stale))))

(defun org-glean-search-api (query &optional limit fuzzy filters modes)
  "Return a versioned, bounded result-set for QUERY.
FUZZY enables bounded title/heading matching. FILTERS is a plist supporting
:exclude-property-values, :max-heading-level, :exclude-titles, and
:allowed-roots. MODES, when non-nil, is a list of requested provider modes
among `exact', `lexical', `fuzzy' and `semantic'; a mode that could not be
served (for example `semantic' with no provider configured) is absent from
`used' and reported in `provider-errors' rather than silently dropped."
  (let* ((limit (max 1 (min 100 (or limit org-glean-search-limit))))
         (modes (or modes (append '(exact lexical) (when fuzzy '(fuzzy)))))
         (search (org-glean-search-filtered query limit fuzzy filters modes))
         (all-results (nth 0 search))
         (truncated (nth 1 search))
         (stale-p (nth 2 search))
         ;; org-glean-search-filtered already returns its results sorted by
         ;; fusion order; re-sorting here would be redundant but harmless,
         ;; kept for callers that construct a result list some other way.
         (results (sort (copy-sequence all-results) #'org-glean--relevance-before-p))
          (results (cl-loop for item in results for rank from 1
                           for next = (nth rank results)
                           for score = (or (alist-get :score item) 0)
                           for next-score = (or (alist-get :score next) 0)
                           collect (append item
                                            `((:rank . ,rank)
                                              (:margin . ,(- score next-score))
                                             (:match-reason . ,(mapconcat
                                                                (lambda (m)
                                                                  (if (nth 3 m)
                                                                      (format "%s #%d z%.1f" (car m) (1+ (nth 1 m)) (nth 3 m))
                                                                    (format "%s #%d" (car m) (1+ (nth 1 m)))))
                                                                (sort (copy-sequence (alist-get :modes item))
                                                                      (lambda (a b)
                                                                        (> (org-glean--fusion-contribution (car a) (nth 1 a) (nth 3 a))
                                                                           (org-glean--fusion-contribution (car b) (nth 1 b) (nth 3 b)))))
                                                                " + "))
                                             (:link . ,(if (alist-get :org-id item)
                                                           (format "[[id:%s][%s]]"
                                                                   (alist-get :org-id item)
                                                                   (alist-get :title item))
                                                         (format "[[file:%s::%d][%s]]"
                                                                 (alist-get :path item)
                                                                 (alist-get :position item)
                                                                 (alist-get :title item))))))))
          (freshness (cond (stale-p 'stale-source-present)
                           ((null all-results) 'index-checked)
                           (t 'sources-checked-current)))
          (completeness org-glean--last-search-completeness))
    `((schema-version . 1)
      (query . ,query)
      (requested . ,(mapcar (lambda (mode) (cons mode t)) modes))
       (used . ,org-glean--last-search-used)
        (degraded . ,(cond (org-glean--last-search-provider-errors 'provider-error)
                           ((eq completeness 'incomplete) 'incomplete)
                           (t :false)))
       (freshness . ,freshness)
       (limit . ,limit)
       (candidate-count . ,(length results))
        (completeness . ,completeness)
        (truncated . ,(if truncated t :false))
        (work-examined . ,org-glean--last-search-examined)
        (provider-errors . ,(vconcat
                             (mapcar (lambda (failure)
                                       `((provider . ,(car failure))
                                         (message . ,(cdr failure))))
                                     org-glean--last-search-provider-errors)))
        (results . ,(vconcat results)))))

;; org-glean-semantic-provider defaults to nil (semantic mode explicitly
;; unavailable) until this file defines a real implementation. Now that it
;; does, wire it in as the default -- but only if nothing has already
;; customized the hook, so an explicit nil (or a caller's own provider) is
;; never silently overridden by loading this file.
(unless org-glean-semantic-provider
  (setq org-glean-semantic-provider #'org-glean--semantic-search-provider))

(provide 'org-glean-search)
;;; org-glean-search.el ends here
