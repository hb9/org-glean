;;; org-glean-search.el --- Exact, lexical and fuzzy candidate providers and fusion -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-store)
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

(defun org-glean--filtered-out-p (item filters)
  "Return non-nil if ITEM does not satisfy FILTERS."
  (or (member (downcase (or (alist-get :capture-policy item) "eligible"))
              (mapcar #'downcase (plist-get filters :exclude-property-values)))
      (and (plist-get filters :max-heading-level)
           (equal (alist-get :kind item) "heading")
           (> (or (alist-get :level item) 0) (plist-get filters :max-heading-level)))
      (member (downcase (or (alist-get :title item) ""))
              (mapcar #'downcase (plist-get filters :exclude-titles)))
       (not (org-glean--properties-match-p
             (alist-get :properties item) (plist-get filters :property-equals)))))

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
      (list matches examined
            (and (not done) (not extra) (>= examined scan-cap))
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
  "Return (TARGET-KEY . SCORE) pairs from HITS, highest score first, deduped
by owning target. HITS is a vector of alists with `digest' and `score',
already sorted by the backend descending by score; the first hit seen for
a given target is therefore its best-scoring chunk, so later duplicate
occurrences of the same target are simply skipped rather than compared."
  (let ((best (make-hash-table :test #'equal)) (order nil))
    (cl-loop for hit across hits
             for digest = (alist-get 'digest hit)
             for score = (alist-get 'score hit)
             for target-key = (caar (sqlite-select
                                     db "SELECT target_key FROM chunks WHERE text_digest = ? LIMIT 1"
                                     (vector digest)))
             when (and target-key (not (gethash target-key best)))
             do (progn (puthash target-key score best)
                       (push target-key order)))
    (mapcar (lambda (key) (cons key (gethash key best))) (nreverse order))))

(defun org-glean--semantic-search-provider (query filters limit)
  "Return generic typed semantic candidates for QUERY, FILTERS and LIMIT.
Embeds QUERY, scores it against the backend's in-memory vectors (warming
it from SQLite first if this is a fresh process), aggregates chunk hits up
to their owning target by max score, applies FILTERS the same way every
other provider does, and returns at most LIMIT target items with :score
and :source-current set. Signals if the active model's backend is not
installed; the caller (`org-glean-search-filtered') turns that into a
`provider-errors' entry rather than a crash, exactly like any other
provider's failure."
  (let ((model org-glean-semantic-model)
        (db (org-glean--db)))
    (unless (org-glean-embed-available-p model)
      (error "Semantic model %s is not installed; run M-x org-glean-install" model))
    (org-glean--semantic-ensure-warm db model)
    (let* ((response (org-glean--embed-request-sync
                      "search" `((query . ,query) (k . ,(min 200 (max 50 (* limit 5)))))
                      model))
           (hits (or (alist-get 'results response) []))
           (ranked (org-glean--semantic-chunk-hit-targets db hits))
           (items nil))
      (cl-loop for (target-key . score) in ranked
               while (< (length items) limit)
               do (let ((rows (sqlite-select
                              db "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE key = ?"
                              (vector target-key))))
                    (when (= (length rows) 1)
                      (let ((item (car (org-glean--results rows))))
                        (when (org-glean--eligible-p item filters)
                          (setf (alist-get :score item) score
                                (alist-get :source-current item)
                                (and (file-exists-p (alist-get :path item))
                                     (equal (alist-get :digest item)
                                           (org-glean--digest (alist-get :path item)))))
                          (push item items))))))
      (nreverse items))))

(defun org-glean--fusion-weight (mode)
  "Return MODE's configured fusion weight, or 0 if unconfigured."
  (or (cdr (assq mode org-glean-fusion-weights)) 0.0))

(defun org-glean--fusion-contribution (mode rank)
  "Return one mode's reciprocal-rank fusion contribution at 0-based RANK."
  (/ (org-glean--fusion-weight mode) (float (+ org-glean-fusion-k rank 1))))

(defun org-glean--fusion-merge (provider-lists)
  "Merge PROVIDER-LISTS, an alist of (MODE . RANKED-ITEMS), by target key.
Each returned item gains a :modes list of (MODE RANK RAW-SCORE) entries,
one per contributing provider, and has its :source-current set exactly
once. Item identity/base fields come from whichever provider found the
target first; the fields are the same regardless of which provider's SQL
query produced them, since they all describe the same indexed target."
  (let ((table (make-hash-table :test #'equal)) (order nil))
    (dolist (pair provider-lists)
      (let ((mode (car pair)))
        (cl-loop for item in (cdr pair)
                 for rank from 0
                 do (let* ((key (alist-get :key item))
                           (raw (org-glean--raw-score item mode rank))
                           (existing (gethash key table)))
                      (if existing
                          (setf (alist-get :modes existing)
                                (cons (list mode rank raw) (alist-get :modes existing)))
                        (setf (alist-get :modes item) (list (list mode rank raw)))
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
         (fused (cl-loop for (mode rank _raw) in modes
                        sum (org-glean--fusion-contribution mode rank)))
         (primary (car (cl-reduce
                        (lambda (a b) (if (>= (cdr a) (cdr b)) a b))
                        (mapcar (lambda (m) (cons (car m) (org-glean--fusion-contribution (car m) (nth 1 m))))
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
            org-glean--last-search-used (nreverse used)
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
                                                                  (format "%s #%d" (car m) (1+ (nth 1 m))))
                                                                (sort (copy-sequence (alist-get :modes item))
                                                                      (lambda (a b)
                                                                        (> (org-glean--fusion-contribution (car a) (nth 1 a))
                                                                           (org-glean--fusion-contribution (car b) (nth 1 b)))))
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
