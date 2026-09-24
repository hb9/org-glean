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

(defgroup org-glean-mcp nil "MCP adapter for Org Glean." :group 'org-glean)

  (defcustom org-glean-mcp-allowed-roots nil
   "Allowed root directories for MCP search.
An empty value falls back to the configured Org Glean roots."
  :type '(repeat directory)
  :group 'org-glean)

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
             (filters (list :exclude-property-values exclude-values
                            :property-equals (when (and property-key property-value)
                                               (list (cons property-key property-value)))
                            :max-heading-level max-level
                            :exclude-titles exclude-titles))
             response)
        (unless (stringp query) (error "`query' string is required"))
         (setq response (org-glean-search-api query limit t filters))
          (let ((roots (or org-glean-mcp-allowed-roots
                            (mapcar #'cadr org-glean-roots))))
           (unless roots (error "No Org Glean root is allowed for MCP search"))
           (setq response (org-glean-mcp--restrict response roots)))
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
                   (exclude_property_values . ((type . "array")
                                               (items . ((type . "string")))))
                   (exclude_titles . ((type . "array")
                                      (items . ((type . "string")))))
                   (property_key . ((type . "string")))
                   (property_value . ((type . "string")))))
    (required . ["query"]))
  "MCP input schema for bounded Org Glean search.")

(mcp-server-register-tool
 (make-mcp-server-tool
   :name "org-glean_search"
  :title "Search Org with Org Glean"
  :description
  "Search configured Org roots with bounded exact, lexical, and fuzzy retrieval. Optional filters exclude property values, require exact metadata property pairs, cap heading depth, or omit titles. Returns provisional or Org-ID targets with file, outline path, score, reason, source freshness, and a location link. This tool never modifies Org files. Use org-get-node to resolve/read a target before capture."
   :input-schema org-glean-mcp--input-schema
  :function #'org-glean-mcp--handler
  :annotations '((readOnlyHint . t)
                 (destructiveHint . :false)
                 (idempotentHint . t)
                 (openWorldHint . :false))))

(provide 'org-glean-mcp)
;;; org-glean-mcp.el ends here
