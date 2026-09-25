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

(defun org-glean--mark-result (item match-type rank)
  "Add match metadata and source freshness to ITEM."
  (setf (alist-get :match-type item) (or (alist-get :match-type item) match-type)
        (alist-get :score item) (or (alist-get :score item)
                                    (if (eq match-type 'exact) 100.0
                                      (max 85.0 (- 94.0 (* rank 0.01)))))
        (alist-get :source-current item)
        (and (file-exists-p (alist-get :path item))
             (equal (alist-get :digest item) (org-glean--digest (alist-get :path item)))))
  item)

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

(defun org-glean-search-filtered (query limit fuzzy filters &optional modes)
  "Search QUERY, applying FILTERS and :allowed-roots before LIMIT.
MODES, when non-nil, is a list of requested provider modes among
`exact', `lexical', `fuzzy' and `semantic'; it defaults to
`(exact lexical)', with FUZZY as a legacy shorthand for adding `fuzzy'."
  (let* ((db (org-glean--db))
         (limit (max 1 (min 100 (or limit org-glean-search-limit))))
         (budget (max 1 org-glean-search-work-budget))
         (page-size (max 1 (min 200 org-glean-search-page-size)))
         (remaining budget)
         (seen (make-hash-table :test #'equal))
         (org-glean--provider-stale-seen nil)
         (used nil)
         (provider-errors nil)
         (modes (or modes '(exact lexical)))
         (semantic-requested (memq 'semantic modes))
         exact lexical fuzzy-results semantic-results
         (extra nil) (incomplete nil))
    (when semantic-requested
      (if org-glean-semantic-provider
          (condition-case err
              (let ((semantic-items
                     (funcall org-glean-semantic-provider query filters limit)))
                (setq semantic-results
                      (mapcar (lambda (item)
                                (setf (alist-get :match-type item) 'semantic)
                                item)
                              semantic-items))
                (push 'semantic used))
            (error (push (cons 'semantic (error-message-string err)) provider-errors)))
        ;; Explicitly report the missing capability. Never label lexical results
        ;; as semantic or silently claim the requested mode ran.
        (push (cons 'semantic "No semantic provider is configured") provider-errors)))
    (when (and (memq 'exact modes) (stringp query) (not (string-empty-p query)))
      (let ((org-glean--provider-work-count 0))
        (condition-case err
            (progn
              (let ((page (org-glean--collect-provider
                           db "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE title=? ORDER BY path,position LIMIT ? OFFSET ?"
                           (vector query) filters (1+ limit) remaining page-size seen)))
                (setq exact (nth 0 page) remaining (- remaining (nth 1 page))
                      incomplete (nth 2 page) extra (nth 3 page)))
              (push 'exact used))
          (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                  (push (cons 'exact (error-message-string err)) provider-errors)))))
    (when (and (memq 'lexical modes) (not extra) (not incomplete) (> remaining 0))
      (let ((fts (org-glean--fts-pattern query)))
        (when fts
          (let ((org-glean--provider-work-count 0))
            (condition-case err
                (progn
                  (let ((page (org-glean--collect-provider
                               db "SELECT t.key,t.path,t.kind,t.title,t.org_id,t.position,t.digest,snippet(target_fts,1,'[',']','…',16),t.capture_policy,t.level,t.outline_path,t.properties FROM target_fts JOIN targets t ON t.rowid=target_fts.rowid WHERE target_fts MATCH ? ORDER BY bm25(target_fts),t.path,t.position LIMIT ? OFFSET ?"
                               (vector fts) filters (1+ (- limit (length exact)))
                               remaining page-size seen)))
                    (setq lexical (nth 0 page) remaining (- remaining (nth 1 page))
                          incomplete (nth 2 page) extra (nth 3 page)))
                  (push 'lexical used))
              (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                      (push (cons 'lexical (error-message-string err)) provider-errors)))))))
    (when (and (or fuzzy (memq 'fuzzy modes))
               (stringp query) (not (string-empty-p (string-trim query)))
               (not extra) (not incomplete) (> remaining 0)
               (< (+ (length exact) (length lexical)) (1+ limit)))
      (let ((org-glean--provider-work-count 0))
        (condition-case err
            (progn
              (let ((page (org-glean--collect-fuzzy
                           db query filters (1+ (- limit (length exact) (length lexical)))
                           remaining page-size seen)))
                (setq fuzzy-results (nth 0 page) remaining (- remaining (nth 1 page))
                      incomplete (nth 2 page) extra (nth 3 page)))
              (push 'fuzzy used))
          (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                  (push (cons 'fuzzy (error-message-string err)) provider-errors)))))
    (let* ((all (append (mapcar (lambda (item) (org-glean--mark-result item 'exact 0)) exact)
                        (cl-loop for item in lexical for rank from 0
                                 collect (org-glean--mark-result item 'lexical rank))
                        (mapcar (lambda (item) (org-glean--mark-result item 'fuzzy 0))
                                fuzzy-results)
                        (mapcar (lambda (item) (org-glean--mark-result item 'semantic 0))
                                semantic-results)))
           (has-extra (> (length all) limit))
           (all (cl-subseq all 0 (min (length all) (1+ limit))))
           (truncated (or extra incomplete provider-errors has-extra))
           (stale (or org-glean--provider-stale-seen
                      (cl-some (lambda (item) (not (alist-get :source-current item))) all)))
           (results (cl-subseq all 0 (min limit (length all)))))
      (setq org-glean--last-search-completeness
            (cond ((or incomplete provider-errors) 'incomplete)
                  ((or extra has-extra) 'truncated)
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
         (results (sort all-results #'org-glean--relevance-before-p))
          (results (cl-loop for item in results for rank from 1
                           for next = (nth rank results)
                           for score = (or (alist-get :score item) 0)
                           for next-score = (or (alist-get :score next) 0)
                           collect (append item
                                            `((:rank . ,rank)
                                              (:margin . ,(- score next-score))
                                             (:match-reason . ,(pcase (alist-get :match-type item)
                                                                 ('exact "exact title")
                                                                 ('fuzzy "fuzzy title or heading")
                                                                 ('semantic "semantic similarity")
                                                                 (_ "FTS5 lexical match")))
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

(defun org-glean--result-sort-key (item)
  "Return the results-buffer order key for ITEM.
This is priority-tier ordering (exact, then lexical, then semantic, then
fuzzy), not a calibrated fused score across providers; see ROADMAP.md
phase 2 for deterministic rank fusion."
  (list (or (cdr (assq (alist-get :match-type item)
                       '((exact . 0) (lexical . 1) (semantic . 2) (fuzzy . 3)))) 4)))

(defun org-glean--relevance-before-p (left right)
  "Return non-nil if LEFT has higher display relevance than RIGHT."
  (let ((left-key (org-glean--result-sort-key left))
        (right-key (org-glean--result-sort-key right)))
    (if (= (car left-key) (car right-key))
        (let ((left-score (or (alist-get :score left) 0))
              (right-score (or (alist-get :score right) 0)))
          (if (= left-score right-score)
              (< (or (alist-get :rank left) most-positive-fixnum)
                 (or (alist-get :rank right) most-positive-fixnum))
            (> left-score right-score)))
      (< (car left-key) (car right-key)))))

;; org-glean-semantic-provider defaults to nil (semantic mode explicitly
;; unavailable) until this file defines a real implementation. Now that it
;; does, wire it in as the default -- but only if nothing has already
;; customized the hook, so an explicit nil (or a caller's own provider) is
;; never silently overridden by loading this file.
(unless org-glean-semantic-provider
  (setq org-glean-semantic-provider #'org-glean--semantic-search-provider))

(provide 'org-glean-search)
;;; org-glean-search.el ends here
