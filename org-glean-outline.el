;;; org-glean-outline.el --- Read-only whole-file Org outline -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.
;;
;; A capture agent, once org-glean-search has told it WHICH file(s) look
;; like a plausible destination, needs the file's actual outline structure
;; to decide WHERE within it to place something: an existing task section,
;; an existing active-TODO cluster, or a new top-level heading at the end.
;; org-glean does not attempt that placement decision itself (see
;; ROADMAP.md's explicit scope note); this module only returns the
;; structure an agent needs to make it.
;;
;; Reads files from disk via a throwaway temp buffer, exactly like
;; org-glean-project.el's own indexing pass: never a live Emacs buffer, so
;; there is no auto-id side effect, no possibility of picking up unsaved
;; edits a user is mid-way through, and no interaction with any other
;; buffer-local state. This is a read tool: it returns structure, it never
;; writes anything, anywhere, ever.
;;
;; Every entry here is an alist of (:key . value) conses, not a plist —
;; matching the convention `org-glean-search.el' result items and
;; `org-glean-mcp--json-normalize' both expect, unlike
;; `org-glean-project.el''s own internal projection records (which are
;; plists, consumed by `plist-get' in `org-glean-store.el' and never
;; cross the JSON boundary directly).

;;; Code:

(require 'org-glean-core)
(require 'org-glean-project)
(require 'org)
(require 'org-element)
(require 'cl-lib)

(defcustom org-glean-outline-max-headings 500
  "Maximum headings returned per file by `org-glean-outline'.
A hard cap on one file's response size, not a normal limit: existing
corpus files are far smaller than this in practice. A file with more
headings than this returns exactly this many, in document order, with
`:truncated' set so the caller knows the outline is not the whole file."
  :type 'integer
  :group 'org-glean)

(defun org-glean--outline-closed-p (todo-keyword)
  "Return non-nil when TODO-KEYWORD is one of Org's done keywords.
Uses `org-done-keywords', which requires TODO-KEYWORD to have been read
in a buffer where Org's keyword faces/settings are active — true here,
since this is only ever called from within the `org-mode' temp buffer
`org-glean--outline-file' parses."
  (and todo-keyword (member todo-keyword org-done-keywords) t))

(defun org-glean--outline-heading (headline file-properties)
  "Return one outline entry alist for HEADLINE, inheriting FILE-PROPERTIES."
  (let ((todo (org-element-property :todo-keyword headline)))
    `((:level . ,(org-element-property :level headline))
      (:title . ,(org-element-property :raw-value headline))
      (:todo-keyword . ,todo)
      (:closed . ,(org-glean--outline-closed-p todo))
      (:priority . ,(let ((p (org-element-property :priority headline)))
                      (and p (char-to-string p))))
      (:tags . ,(append (org-element-property :tags headline) nil))
      (:org-id . ,(org-glean--heading-id headline))
      (:outline-path . ,(let ((parent (org-element-property :parent headline)) path-parts)
                          (while (and parent (eq (org-element-type parent) 'headline))
                            (push (org-element-property :raw-value parent) path-parts)
                            (setq parent (org-element-property :parent parent)))
                          (nconc path-parts (list (org-element-property :raw-value headline)))))
      (:properties . ,(org-glean--properties headline file-properties)))))

(defun org-glean--outline-file (path)
  "Return one whole-file outline alist for PATH, read fresh from disk.
Signals on a missing or unparseable file; callers collect per-file
errors the same way `org-glean-search-api' collects `provider-errors',
rather than letting one bad path abort every other requested file."
  (unless (file-exists-p path) (error "No such file: %s" path))
  (with-temp-buffer
    (insert-file-contents path)
    (org-mode)
    (let* ((tree (org-element-parse-buffer))
           (title (or (org-element-map tree 'keyword
                        (lambda (kw)
                          (when (string= (org-element-property :key kw) "TITLE")
                            (org-element-property :value kw))) nil t)
                      (file-name-base path)))
           (file-properties (org-element-map tree 'keyword
                              (lambda (kw)
                                (when (and (equal "PROPERTY" (org-element-property :key kw))
                                           (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.*\\)\\'"
                                                         (org-element-property :value kw)))
                                  (cons (match-string 1 (org-element-property :value kw))
                                        (match-string 2 (org-element-property :value kw)))))
                              nil nil '(headline)))
           (all-headings (org-element-map tree 'headline #'identity))
           (truncated (> (length all-headings) org-glean-outline-max-headings))
           (headings (cl-subseq all-headings 0 (min (length all-headings)
                                                     org-glean-outline-max-headings))))
      `((:path . ,path)
        (:title . ,title)
        (:properties . ,(org-glean--properties nil file-properties))
        (:headings . ,(mapcar (lambda (h) (org-glean--outline-heading h file-properties))
                              headings))
        (:heading-count . ,(length all-headings))
        (:truncated . ,truncated)))))

(defun org-glean-outline (files &optional max-level)
  "Return whole-file outlines for FILES, a path or list of paths.
Never writes to any file, and never touches any live buffer: each file
is read fresh from disk into a throwaway temp buffer, so unsaved edits
in an open buffer for the same file are not reflected, matching what
`org-glean-search' itself returns (the last saved+reconciled state).

Returns `((:outlines . OUTLINE-LIST) (:errors . (((:path . PATH)
(:message . STRING)) ...)))' — one bad path never prevents outlines for
the others. When MAX-LEVEL is given, an outline's `:headings' omit any
heading deeper than it, but `:heading-count'/`:truncated' still
describe the whole file, since the cap in
`org-glean-outline-max-headings' is against response size, not the
depth filter."
  (let ((files (if (listp files) files (list files)))
        (outlines nil) (errors nil))
    (dolist (path files)
      (condition-case err
          (let* ((outline (org-glean--outline-file path))
                 (headings (alist-get :headings outline)))
            (when max-level
              (setq headings (cl-remove-if (lambda (h) (> (alist-get :level h) max-level))
                                           headings))
              (setf (alist-get :headings outline) headings))
            (push outline outlines))
        (error (push `((:path . ,path) (:message . ,(error-message-string err))) errors))))
    `((:outlines . ,(nreverse outlines)) (:errors . ,(nreverse errors)))))

(provide 'org-glean-outline)
;;; org-glean-outline.el ends here
