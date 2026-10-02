;;; org-glean-mcp.el --- MCP adapter for Org Glean -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Optional adapter for rhblind/emacs-mcp-server. It exposes bounded read-only
;; search and delegates indexing/search semantics to org-glean.

;;; Code:

(require 'org-glean)
(require 'mcp-server-tools)
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup org-glean-mcp nil "MCP adapter for Org Glean." :group 'org-glean)

  (defcustom org-glean-mcp-allowed-roots nil
   "Allowed root directories for MCP search.
An empty value falls back to the configured Org Glean roots."
  :type '(repeat directory)
  :group 'org-glean)

(defun org-glean-mcp--property-filter-from-args (entry)
  "Convert one MCP `property_filters' array ENTRY into an internal filter
plist. ENTRY is an alist with `key' (string), `op' (string, snake_case:
one of \"equals\", \"not_equals\", \"in\", \"not_in\", \"exists\",
\"missing\"), and `value' (string, for `equals'/`not_equals') or
`values' (array of strings, for `in'/`not_in'). See
`org-glean--property-filter-match-p' for exact semantics, in particular
that a property never set anywhere on a target is absent, not defaulted
to any value."
  (list :key (alist-get 'key entry)
        :op (intern (replace-regexp-in-string "_" "-" (or (alist-get 'op entry) "")))
        :value (alist-get 'value entry)
        :values (append (alist-get 'values entry) nil)))

(defun org-glean-mcp--handler (args)
  "Handle MCP search ARGS and return JSON result-set."
  (condition-case err
      (let* ((query (alist-get 'query args))
             (limit (alist-get 'limit args))
             (max-level (alist-get 'max_heading_level args))
             (exclude-values (append (alist-get 'exclude_property_values args) nil))
             (exclude-titles (append (alist-get 'exclude_titles args) nil))
             (property-key (alist-get 'property_key args))
             (property-value (alist-get 'property_value args))
             (property-key (and (stringp property-key)
                                 (not (string-empty-p property-key))
                                 property-key))
             (property-value (and (stringp property-value)
                                   (not (string-empty-p property-value))
                                   property-value))
             (property-filters (mapcar #'org-glean-mcp--property-filter-from-args
                                       (append (alist-get 'property_filters args) nil)))
              (modes (let ((requested (mapcar #'intern (append (alist-get 'modes args) nil))))
                       (or requested (org-glean--default-modes))))
              (roots (or org-glean-mcp-allowed-roots
                         (mapcar #'cadr org-glean-roots)))
              (filters (list :allowed-roots roots
                             :exclude-property-values exclude-values
                            :property-equals (when (and property-key property-value)
                                               (list (cons property-key property-value)))
                            :property-filters property-filters
                            :max-heading-level max-level
                            :exclude-titles exclude-titles))
             response)
        (unless (stringp query) (error "`query' string is required"))
         (unless roots (error "No Org Glean root is allowed for MCP search"))
         (setq response (org-glean-search-api query limit (memq 'fuzzy modes) filters modes))
        (json-encode (org-glean-mcp--json-normalize response)))
    (error (json-encode `((schema-version . 1)
                          (error . ,(error-message-string err)))))))

(defun org-glean-mcp--restrict (response roots)
  "Restrict RESPONSE results to one of ROOTS."
   (let* ((roots (mapcar (lambda (root)
                           (file-name-as-directory (file-truename root))) roots))
         (results (append (alist-get 'results response) nil))
         (allowed (cl-remove-if-not
                   (lambda (item)
                     (let ((path (alist-get :path item)))
                       (and (cl-some (lambda (root) (file-in-directory-p path root)) roots)
                            (not (file-symlink-p path))))) results)))
    (setf (alist-get 'results response) (vconcat allowed)
          (alist-get 'candidate-count response) (length allowed))
    response))

(defun org-glean-mcp--json-normalize (value)
  "Normalize Org Glean VALUE to JSON-safe object keys and values."
  (cond
   ((and (consp value) (consp (car value))
         (or (symbolp (caar value)) (stringp (caar value))))
    (mapcar (lambda (pair)
              (cons (intern (string-remove-prefix ":" (format "%s" (car pair))))
                    (org-glean-mcp--json-normalize (cdr pair)))) value))
   ((and (consp value) (symbolp (car value)))
    (cons (intern (string-remove-prefix ":" (symbol-name (car value))))
          (org-glean-mcp--json-normalize (cdr value))))
   ((and (listp value) (not (stringp value)))
    (mapcar #'org-glean-mcp--json-normalize value))
   ((vectorp value)
    (vconcat (mapcar #'org-glean-mcp--json-normalize (append value nil))))
   ((memq value '(t :false :null)) value)
   ((symbolp value) (symbol-name value))
   (t value)))

(defconst org-glean-mcp--input-schema
  '((type . "object")
    (properties . ((query . ((type . "string")))
                   (limit . ((type . "integer") (minimum . 1) (maximum . 100)))
                   (max_heading_level . ((type . "integer") (minimum . 1)))
                   (property_filters
                    . ((type . "array")
                       (description . "Constrain results by any inherited Org property (file-level #+PROPERTY, or a heading's own property drawer) — this tool has no built-in knowledge of any particular property name, CAPTURE_POLICY included. Every entry must match (they are ANDed together). A property never set anywhere on a target is simply absent, not defaulted to any value: `equals'/`in'/`exists' fail on it, `not_equals'/`not_in'/`missing' pass.")
                       (items
                        . ((type . "object")
                           (properties
                            . ((key . ((type . "string")
                                       (description . "Property name, matched case-insensitively, e.g. \"CAPTURE_POLICY\"")))
                               (op . ((type . "string")
                                      (enum . ["equals" "not_equals" "in" "not_in" "exists" "missing"])))
                               (value . ((type . "string")
                                         (description . "Required for equals/not_equals")))
                               (values . ((type . "array") (items . ((type . "string")))
                                          (description . "Required for in/not_in")))))
                           (required . ["key" "op"])))))
                   (exclude_property_values . ((type . "array")
                                               (items . ((type . "string")))
                                               (description . "Deprecated: use property_filters with key CAPTURE_POLICY and op not_in instead. Kept working for existing callers.")))
                   (exclude_titles . ((type . "array")
                                      (items . ((type . "string")))))
                   (property_key . ((type . "string")
                                     (description . "Deprecated: use property_filters with op equals instead. Kept working for existing callers.")))
                   (property_value . ((type . "string")))
                   (modes . ((type . "array")
                             (description . "Retrieval strategies to run, merged into one ranked list. \"semantic\" finds meaning-based matches with no shared words with the query and is usually the most useful mode for a topical question; omit this field entirely to use every mode the corpus currently supports.")
                             (items . ((type . "string")
                                       (enum . ["exact" "lexical" "fuzzy" "semantic"])))))))
    (required . ["query"]))
  "MCP input schema for bounded Org Glean search.")

(mcp-server-register-tool
 (make-mcp-server-tool
   :name "org-glean_search"
  :title "Search Org with Org Glean"
  :description
   "Search configured Org roots with bounded exact, lexical, fuzzy AND semantic (meaning-based) retrieval; semantic search is this tool's main reason to exist, not an afterthought — it finds a target with no shared words with the query (e.g. querying \"food\" finds a recipe that never uses that word). Pass `modes' to select which retrieval strategies run (any of \"exact\", \"lexical\", \"fuzzy\", \"semantic\"); omit it to get every mode the corpus currently supports, semantic included once a model is installed. `exact' also checks a file's ALIASES property (capture-workflow note §7.1), e.g. \"OD DMS\" finding aistore even though neither word appears in its title. Results from every requested mode are merged into one ranked list; each result's `match-reason' names its best-scoring mode(s) and, for a semantic contribution, a z-score (e.g. \"semantic #1 z5.8\") — roughly, how much better this match is than a typical candidate for this query, not an absolute similarity number. A query with no strong match anywhere in the corpus can legitimately return few or no results; that is a correct answer, not a sign to keep guessing at rephrasing it. `property_filters' constrains results by any inherited Org property this corpus happens to use (e.g. CAPTURE_POLICY, but nothing about this tool is specific to that one) — pass it explicitly whenever you want that constraint; nothing is filtered by property implicitly. `max_heading_level' caps heading depth; `exclude_titles' omits generic headings by name. Returns provisional or Org-ID targets with file, outline path, score, reason, source freshness, a location link, and completeness/truncation metadata. This tool never modifies Org files. Use org-get-node to resolve/read a target before capture, or org-glean_outline for a whole file's structure at once."
   :input-schema org-glean-mcp--input-schema
  :function #'org-glean-mcp--handler
  :annotations '((readOnlyHint . t)
                 (destructiveHint . :false)
                 (idempotentHint . t)
                 (openWorldHint . :false))))

(defun org-glean-mcp--outline-handler (args)
  "Handle MCP outline ARGS and return JSON per-file outline structure."
  (condition-case err
      (let* ((files (or (append (alist-get 'files args) nil)
                        (and (alist-get 'file args) (list (alist-get 'file args)))))
             (max-level (alist-get 'max_heading_level args))
             (roots (or org-glean-mcp-allowed-roots
                       (mapcar #'cadr org-glean-roots)))
             (allowed nil) (denied nil))
        (unless files (error "`file' or `files' is required"))
        (unless roots (error "No Org Glean root is allowed for MCP outline"))
        (dolist (file files)
          (if (org-glean--path-in-roots-p file roots)
              (push file allowed)
            (push file denied)))
        (let* ((result (org-glean-outline (nreverse allowed) max-level))
               (errors (append (alist-get :errors result)
                               (mapcar (lambda (file)
                                         `((:path . ,file)
                                           (:message . "Path is outside every allowed root")))
                                       (nreverse denied)))))
          (json-encode (org-glean-mcp--json-normalize
                        `((:outlines . ,(vconcat (alist-get :outlines result)))
                          (:errors . ,(vconcat errors)))))))
    (error (json-encode `((error . ,(error-message-string err)))))))

(defconst org-glean-mcp--outline-input-schema
  '((type . "object")
    (properties . ((file . ((type . "string")
                             (description . "Absolute path to one Org file")))
                   (files . ((type . "array") (items . ((type . "string")))
                             (description . "Absolute paths to several Org files, e.g. the top few candidate files from org-glean_search")))
                   (max_heading_level . ((type . "integer") (minimum . 1)
                                          (description . "Omit headings deeper than this from the response; the file's true heading count is still reported")))))
    (required . []))
  "MCP input schema for the read-only Org Glean outline tool.")

(mcp-server-register-tool
 (make-mcp-server-tool
   :name "org-glean_outline"
  :title "Get whole-file Org outline with Org Glean"
  :description
   "Return one or more Org files' whole outline structure in a single call: every heading's level, title, TODO keyword, whether that keyword is a 'done' state, priority, tags, org-id (if it has one), outline path and inherited properties. Meant to follow org-glean_search: once search has named a plausible destination file, this tool gives an agent what it needs to decide WHERE within that file to place something — an existing task section, an existing cluster of active TODOs, or a new heading at the end — org-glean makes no placement decision itself, an agent using this tool does. Always reads fresh from disk into a throwaway buffer, never a live Emacs buffer: it never mints an Org ID as a side effect (unlike org-get-node/org-search with auto-id enabled) and never reflects unsaved edits in an open buffer. A path outside the allowed roots is reported as a per-file error, not silently dropped or a reason to fail every other requested file."
   :input-schema org-glean-mcp--outline-input-schema
  :function #'org-glean-mcp--outline-handler
  :annotations '((readOnlyHint . t)
                 (destructiveHint . :false)
                 (idempotentHint . t)
                 (openWorldHint . :false))))

(provide 'org-glean-mcp)
;;; org-glean-mcp.el ends here
