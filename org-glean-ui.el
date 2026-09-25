;;; org-glean-ui.el --- Results buffer, picker and navigation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-store)
(require 'org-glean-search)
(require 'org-glean-index)
(require 'org)
(require 'tabulated-list)
(require 'cl-lib)

(defun org-glean--refresh-result (result)
  "Resolve stable RESULT by ID and recheck its database/source snapshot."
  (let* ((db (org-glean--db))
         (id (alist-get :org-id result)))
    (when id
      (let ((matches (sqlite-select db
                                    "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE org_id=? LIMIT 2"
                                    (vector id))))
        (cond
         ((> (length matches) 1)
          (user-error "Org ID %s is ambiguous; refusing navigation" id))
         ((= (length matches) 1)
          (setq result (car (org-glean--results matches))))
         (t (user-error "Org ID %s is no longer indexed; reconcile and search again" id)))))
    (let* ((path (alist-get :path result))
           (digest (alist-get :digest result))
           (current (caar (sqlite-select db "SELECT digest FROM targets WHERE key=?"
                                         (vector (alist-get :key result))))))
      (unless (equal current digest)
        (user-error "Result is no longer indexed; search again"))
      (unless (and (file-exists-p path) (equal digest (org-glean--digest path)))
        (user-error "Source changed; reconcile and search again"))
      result)))

(defun org-glean--target-position (buffer result)
  "Resolve RESULT within BUFFER, returning a validated heading position."
  (with-current-buffer buffer
    (when (and buffer-file-name (not (verify-visited-file-modtime buffer)))
      (user-error "Visited buffer is stale; revert it before navigating"))
    (when (buffer-modified-p)
      (user-error "Source has unsaved changes; save before navigating"))
    (save-restriction
      (widen)
      (if (not (equal (alist-get :kind result) "heading"))
          (or (alist-get :position result) (point-min))
        (let ((id (alist-get :org-id result))
              positions)
          (if id
              (org-map-entries
               (lambda ()
                 (when (equal id (org-entry-get nil "ID"))
                   (push (point) positions))) nil 'file)
            (goto-char (alist-get :position result))
            (when (and (org-at-heading-p)
                       (equal (alist-get :title result) (org-get-heading t t t t)))
              (push (point) positions)))
          (unless (= (length positions) 1)
            (user-error "Heading no longer resolves uniquely; reconcile and search again"))
          (car positions))))))

(defun org-glean-open-result (result &optional preview)
  "Open RESULT. With PREVIEW, show another window and retain selected-window focus."
  (let* ((resolved (org-glean--refresh-result result))
         (path (alist-get :path resolved))
         (buffer (find-file-noselect path))
         (position (org-glean--target-position buffer resolved)))
    (with-current-buffer buffer (goto-char position))
    (if preview
        (let ((window (display-buffer buffer '(display-buffer-pop-up-window)))
              (origin (selected-window)))
          (when (window-live-p window)
            (set-window-point window position))
          (when (window-live-p origin)
            (select-window origin)))
      (let ((window (display-buffer buffer '(display-buffer-pop-up-window))))
        (select-window window)
        (with-current-buffer buffer (goto-char position))))
    buffer))

(defun org-glean-visit (result)
  "Visit RESULT and move point to the resolved target."
  (interactive)
  (org-glean-open-result result nil))

(defvar org-glean-results-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'org-glean-results-visit)
    (define-key map (kbd "TAB") #'org-glean-results-preview)
    (define-key map (kbd "e") #'org-glean-results-toggle-group)
    (define-key map (kbd "g") #'org-glean-results-refresh)
    (define-key map (kbd "s") #'org-glean-results-toggle-semantic-only)
    map))

(define-derived-mode org-glean-results-mode tabulated-list-mode "Org-Glean"
  "Major mode for bounded Org Glean results."
  (setq tabulated-list-format
        [("Title" 34 t) ("Kind" 8 t) ("Source" 22 t) ("Match" 8 t)
         ("Fresh" 6 t) ("Via" 12 t)])
  (setq tabulated-list-padding 2
        tabulated-list-sort-key nil)
  (tabulated-list-init-header))

(defvar-local org-glean--results-query nil)

(defvar-local org-glean--results-filters nil)

(defvar-local org-glean--results-items nil)

(defvar-local org-glean--results-groups nil)

(defvar-local org-glean--results-expanded-groups nil)

(defvar-local org-glean--results-modes nil
  "Provider modes the current results buffer searches with.
Set by `org-glean-search-buffer'; toggled to/from semantic-only by
`org-glean-results-toggle-semantic-only', which remembers the prior
value in `org-glean--results-previous-modes'.")

(defvar-local org-glean--results-previous-modes nil)

(defun org-glean--mode-abbrev (mode)
  "Return a short display label for provider MODE."
  (pcase mode
    ('exact "exact") ('lexical "lex") ('fuzzy "fuzzy") ('semantic "sem")
    (_ (symbol-name mode))))

(defun org-glean--modes-summary (item)
  "Return ITEM's contributing modes as a short \"a+b\" string.
Modes are ordered by their fusion contribution, strongest first, so this
reads the same way `:match-type' (the single strongest contributor) was
chosen. A `semantic' contribution with a z-score is shown as e.g. \"sem6\"
(the z rounded to the nearest integer), so a glance at this column tells
apart a confident semantic hit from one that only barely cleared
`org-glean-semantic-min-z'. Falls back to the bare match-type for an ITEM
built without a `:modes' list (e.g. constructed directly rather than via
`org-glean-search-filtered')."
  (let ((modes (alist-get :modes item)))
    (if (null modes)
        (or (and (alist-get :match-type item) (symbol-name (alist-get :match-type item))) "")
      (mapconcat (lambda (m)
                   (if (and (eq (car m) 'semantic) (nth 3 m))
                       (format "%s%d" (org-glean--mode-abbrev (car m)) (round (nth 3 m)))
                     (org-glean--mode-abbrev (car m))))
                (sort (copy-sequence modes)
                      (lambda (a b) (> (org-glean--fusion-contribution (car a) (nth 1 a) (nth 3 a))
                                      (org-glean--fusion-contribution (car b) (nth 1 b) (nth 3 b)))))
                "+"))))

(defun org-glean--result-groups (items)
  "Group repeated fuzzy headings in the same file from ITEMS."
  (let (groups ordered)
    (dolist (item items)
      (let* ((groupable (and (eq (alist-get :match-type item) 'fuzzy)
                             (equal (alist-get :kind item) "heading")))
             (group-key (and groupable
                             (list (alist-get :path item) (alist-get :title item))))
             (group (and group-key
                         (cl-find-if (lambda (existing)
                                       (equal group-key (car existing)))
                                     groups))))
        (if group
            (setcdr group (append (cdr group) (list item)))
          (let ((entry (cons (or group-key (alist-get :key item)) (list item))))
            (push entry groups)
            (push entry ordered)))))
    (let ((ordered (nreverse ordered)))
      (dolist (group ordered)
        (setcdr group (sort (cdr group) #'org-glean--relevance-before-p)))
      (sort ordered
          (lambda (left right)
            (org-glean--relevance-before-p (cadr left) (cadr right)))))))

(defun org-glean--tabulated-row (item &optional count)
  "Format ITEM as a row, optionally labelling a COUNT of grouped hits."
  (let* ((key (alist-get :key item))
         (title (or (alist-get :title item) ""))
         (title (if (and count (> count 1))
                    (format "%s (%d matches; e expands)" title count)
                  title))
         (kind (or (alist-get :kind item) ""))
         (source (file-name-nondirectory (alist-get :path item)))
         (match (symbol-name (alist-get :match-type item)))
         (fresh (if (alist-get :source-current item) "yes" "stale"))
         (via (org-glean--modes-summary item)))
    (list key (vector title kind source match fresh via))))

(defun org-glean--tabulated-rows ()
  "Build collapsed/expanded tabulated rows from the current search results."
  (let (rows)
    (dolist (group org-glean--results-groups)
      (let* ((items (cdr group))
             (group-key (car group))
             (expanded (member group-key org-glean--results-expanded-groups)))
        (if (and expanded (> (length items) 1))
            (dolist (item items) (push (org-glean--tabulated-row item) rows))
          (push (org-glean--tabulated-row
                 (car (sort (copy-sequence items) #'org-glean--relevance-before-p))
                 (length items)) rows))))
    (nreverse rows)))

(defun org-glean--buffer-result-items ()
  "Return ordered result items for the current results buffer."
  (apply #'append (mapcar #'cdr org-glean--results-groups)))

(defun org-glean--tabulated-row-result ()
  "Resolve the result represented by the current tabulated row."
  (let ((key (tabulated-list-get-id)))
    (or (cl-find key (org-glean--buffer-result-items)
                 :key (lambda (item) (alist-get :key item)) :test #'equal)
        (cl-find-if (lambda (group) (equal key (car group)))
                    org-glean--results-groups)
        (user-error "Result disappeared; refresh the list"))))

(defun org-glean--selected-result-group ()
  "Return the group represented by the currently selected row."
  (let* ((key (tabulated-list-get-id))
         (group (cl-find-if (lambda (candidate)
                              (or (equal key (car candidate))
                                  (cl-some (lambda (item)
                                             (equal key (alist-get :key item)))
                                           (cdr candidate))))
                            org-glean--results-groups)))
    (unless group (user-error "Result disappeared; refresh the list"))
    (cdr group)))

(defun org-glean--selected-result-items ()
  "Return the selected target, or representative target for a collapsed group."
  (let* ((key (tabulated-list-get-id))
         (items (org-glean--selected-result-group))
         (selected (cl-find key items :key (lambda (item) (alist-get :key item))
                            :test #'equal)))
    (list (or selected (car items)))))

(defun org-glean--tabulated-entry (item)
  "Format result ITEM as one Tabulated List entry."
  (org-glean--tabulated-row item))

(defun org-glean-results-refresh ()
  "Refresh the current Org Glean result buffer."
  (interactive)
  (unless org-glean--results-query (user-error "No Org Glean query to refresh"))
  (let* ((modes (or org-glean--results-modes (org-glean--default-modes)))
         (response (org-glean-search-api org-glean--results-query 100 nil
                                         org-glean--results-filters modes))
         (results (alist-get 'results response))
         (coverage (and (memq 'semantic modes)
                       (org-glean-embed-available-p org-glean-semantic-model)
                       (org-glean--semantic-coverage (org-glean--db) org-glean-semantic-model))))
    (setq org-glean--results-modes modes
          org-glean--results-items (append results nil)
          org-glean--results-groups (org-glean--result-groups org-glean--results-items)
          org-glean--results-expanded-groups
          (cl-remove-if-not (lambda (key)
                              (cl-some (lambda (group) (equal key (car group)))
                                       org-glean--results-groups))
                            org-glean--results-expanded-groups)
          tabulated-list-entries (org-glean--tabulated-rows))
    (tabulated-list-print t)
    (setq header-line-format
          (format "Query: %s | modes: %s%s | freshness: %s | %d targets — TAB previews, RET visits, e expands/collapses, s toggles semantic-only, g refreshes"
                  org-glean--results-query
                  (mapconcat #'symbol-name modes ",")
                  (if coverage (format " (semantic %d/%d embedded)" (car coverage) (cdr coverage)) "")
                  (alist-get 'freshness response)
                  (length results)))))

(defun org-glean-results-visit ()
  "Visit the indexed target on the current results row."
  (interactive)
  (org-glean-visit (org-glean--tabulated-row-result)))

(defun org-glean-results-preview ()
  "Preview the selected result in another window without moving focus."
  (interactive)
  (org-glean-open-result (org-glean--tabulated-row-result) t))

(defun org-glean-results-toggle-group ()
  "Expand/collapse repeated fuzzy hits on the selected file/title group."
  (interactive)
  (let* ((selected (org-glean--selected-result-group))
         (key (list (alist-get :path (car selected))
                    (alist-get :title (car selected)))))
    (unless (> (length selected) 1)
      (user-error "Selected row has no repeated matches to expand"))
    (if (member key org-glean--results-expanded-groups)
        (setq org-glean--results-expanded-groups
              (delete key org-glean--results-expanded-groups))
      (push key org-glean--results-expanded-groups))
          (setq tabulated-list-entries (org-glean--tabulated-rows))
    (tabulated-list-print t)))

(defun org-glean--require-semantic-installed ()
  "Signal a `user-error' unless semantic search is ready to use right now."
  (unless (and org-glean-semantic-provider
              (org-glean-embed-available-p org-glean-semantic-model))
    (user-error "Semantic search is not installed for model %s; run M-x org-glean-install"
               org-glean-semantic-model)))

(defun org-glean-results-toggle-semantic-only ()
  "Toggle the current results buffer between its normal modes and semantic-only."
  (interactive)
  (unless org-glean--results-query (user-error "No Org Glean query to refresh"))
  (if (equal org-glean--results-modes '(semantic))
      (setq org-glean--results-modes (or org-glean--results-previous-modes
                                         (org-glean--default-modes)))
    (org-glean--require-semantic-installed)
    (setq org-glean--results-previous-modes org-glean--results-modes
          org-glean--results-modes '(semantic)))
  (org-glean-results-refresh))

(defun org-glean-search-buffer (query &optional filters modes)
  "Show QUERY in an exploration results buffer.
FILTERS is the generic result-filter plist accepted by `org-glean-search-api'.
MODES defaults to `org-glean--default-modes'."
  (interactive "sSearch Org: ")
  (let ((buffer (get-buffer-create "*Org Glean Results*")))
    (with-current-buffer buffer
      (org-glean-results-mode)
      (setq org-glean--results-query query
            org-glean--results-filters filters
            org-glean--results-modes (or modes (org-glean--default-modes))
            org-glean--results-previous-modes nil)
      (org-glean-results-refresh))
    (pop-to-buffer buffer)))

(defun org-glean-search-buffer-semantic (query &optional filters)
  "Show QUERY in an exploration results buffer, semantic candidates only."
  (interactive "sSemantic search Org: ")
  (org-glean--require-semantic-installed)
  (org-glean-search-buffer query filters '(semantic)))

;;;###autoload

(defun org-glean--find-1 (query modes)
  "Pick and visit a bounded result for QUERY using MODES."
  (let* ((results (append (alist-get 'results (org-glean-search-api query nil nil nil modes)) nil))
         (choices (cl-loop for item in results for n from 1
                           collect (cons (format "%d. %s — %s (%s)" n
                                                 (alist-get :title item)
                                                 (file-name-nondirectory (alist-get :path item))
                                                 (alist-get :kind item)) item)))
         (choice (and choices (completing-read "Visit: " choices nil t))))
    (unless choice (user-error "No matches"))
    (org-glean-visit (cdr (assoc choice choices)))))

(defun org-glean-find (query)
  "Pick and visit a bounded result for QUERY using the default provider modes."
  (interactive "sSearch Org: ")
  (org-glean--find-1 query (org-glean--default-modes)))

(defun org-glean-find-semantic (query)
  "Pick and visit a semantic-only result for QUERY."
  (interactive "sSemantic search Org: ")
  (org-glean--require-semantic-installed)
  (org-glean--find-1 query '(semantic)))

(defvar org-glean-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'org-glean-find)
    (define-key map "G" #'org-glean-search-buffer)
    (define-key map "s" #'org-glean-find-semantic)
    (define-key map "S" #'org-glean-search-buffer-semantic)
    (define-key map "r" #'org-glean-reconcile)
    (define-key map "i" #'org-glean-status)
    (define-key map "e" #'org-glean-show-errors)
    (define-key map "p" #'org-glean-semantic-toggle)
    map)
  "Command map for Org Glean, bound under `org-glean-keymap-prefix'.
\\{org-glean-command-map}")

(defvar org-glean--keymap-prefix-installed nil
  "The key sequence last installed by `org-glean-keymap-prefix', if any.")

(defun org-glean--install-keymap-prefix (symbol value)
  "Custom :set function for `org-glean-keymap-prefix': (re)bind the map."
  (set-default symbol value)
  (when org-glean--keymap-prefix-installed
    (define-key global-map org-glean--keymap-prefix-installed nil))
  (setq org-glean--keymap-prefix-installed nil)
  (when value
    (define-key global-map (kbd value) org-glean-command-map)
    (setq org-glean--keymap-prefix-installed (kbd value))))

(defcustom org-glean-keymap-prefix "M-s g"
  "Key sequence `org-glean-command-map' is bound under.
Nil disables the global binding; the map is still available to bind
yourself, e.g. `(define-key some-map (kbd \"C-c g\") org-glean-command-map)'.

Default bindings: `g' find, `G' search buffer, `s' semantic-only find,
`S' semantic-only search buffer, `r' reconcile, `i' status, `e' show
errors, `p' pause/resume the background embedding queue. Inside a
results buffer, `s' additionally toggles that buffer between its normal
modes and semantic-only."
  :type '(choice (const :tag "Disabled" nil) string)
  :set #'org-glean--install-keymap-prefix
  :group 'org-glean)

(provide 'org-glean-ui)
;;; org-glean-ui.el ends here
