;;; org-glean-core.el --- Configuration, shared state and root resolution -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup org-glean nil "Local search for Org files." :group 'org)

(defcustom org-glean-roots nil
  "Named root specifications (NAME DIRECTORY INCLUDES EXCLUDES).
INCLUDES and EXCLUDES are lists of regexps against root-relative paths.
An empty INCLUDES list accepts every .org file."
  :type '(repeat (list string directory (repeat regexp) (repeat regexp)))
  :group 'org-glean)

(defcustom org-glean-database-file
  (expand-file-name "org-glean.sqlite" user-emacs-directory)
  "Path to the disposable search index."
  :type 'file
  :group 'org-glean)

(defcustom org-glean-reconcile-interval 600
  "Seconds between authoritative full-tree reconciliations; nil disables timer."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'org-glean)

(defcustom org-glean-search-limit 20
  "Default maximum number of results returned by a search."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-search-work-budget 2000
  "Maximum index rows examined by all providers in one search."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-search-page-size 100
  "Maximum number of candidate rows requested in one SQLite page."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-fuzzy-candidate-limit 500
  "Maximum trigram candidates scored by fuzzy search."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-semantic-provider nil
  "Optional function implementing semantic candidate retrieval.
The function is called with QUERY, FILTERS and LIMIT, and must return a list
of target result plists using the active target generation, with FILTERS
applied before LIMIT. Nil means semantic retrieval is unavailable: a request
for the `semantic' mode is reported as unavailable in `provider-errors'
rather than silently dropped or served from another provider."
  :type '(choice (const :tag "Unavailable" nil) function)
  :group 'org-glean)

(defcustom org-glean-semantic-model "e5-small"
  "Active semantic model preset name.
Chunk vectors are keyed on this identifier, so switching presets never
invalidates other presets' cached vectors; it only changes which are
consulted. See ROADMAP.md phase 1 for the preset table and backend."
  :type 'string
  :group 'org-glean)

(defvar org-glean--last-search-completeness 'complete)

(defvar org-glean--last-search-examined 0)

(defvar org-glean--last-search-used nil)

(defvar org-glean--last-search-provider-errors nil)

(defvar org-glean--provider-stale-seen nil)

(defvar org-glean--provider-work-count 0)

(defvar org-glean--last-reconcile-at nil
  "Time of the most recently completed `org-glean-reconcile' call.")

(defvar org-glean--last-reconcile-counts nil
  "Count plist returned by the most recently completed reconciliation.")

(defvar org-glean--last-errors nil
  "Alist of (SOURCE-PATH . MESSAGE) for the latest reconciliation failures.")

(defvar org-glean-install-hook nil
  "Hook run after `org-glean-install' completes with a passing self-test.
Lets modules that depend on org-glean-embed (which cannot itself depend on
them, to avoid a require cycle) react to a fresh install - for example
starting the background embedding queue immediately rather than waiting
for the next reconcile or save.")

(defvar org-glean--database nil)

(defvar org-glean--database-path nil)

(defvar org-glean--fts5-supported nil)

(defvar org-glean--save-timer nil)

(defvar org-glean--reconcile-timer nil)

(defvar org-glean--initial-timer nil)

(defvar org-glean--pending-files nil)

(defconst org-glean--package-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the org-glean package files, for locating
bundled scripts such as semantic/org_glean_embed.py.")

(defun org-glean--digest (path)
  "Hash the literal saved bytes in PATH."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun org-glean--root-for (path)
  "Return (ROOT-NAME . ABSOLUTE-ROOT) for PATH, if it is selected."
  (let* ((absolute (expand-file-name path))
         (truename (and (file-exists-p absolute) (file-truename absolute)))
         match)
    (dolist (spec org-glean-roots)
      (pcase-let ((`(,name ,directory ,includes ,excludes) spec))
        (when (and (file-directory-p directory)
                   (not (file-symlink-p absolute))
                   (or (not truename) (equal truename absolute)))
          (let* ((root (file-name-as-directory (file-truename directory)))
                 (relative (file-relative-name absolute root)))
            (when (and (file-in-directory-p absolute root)
                       (string-suffix-p ".org" absolute t)
                       (or (null includes)
                           (cl-some (lambda (rx) (string-match-p rx relative)) includes))
                       (not (cl-some (lambda (rx) (string-match-p rx relative)) excludes)))
              (when match (error "File belongs to multiple org-glean roots: %s" path))
              (setq match (cons name root)))))))
    match))

(defun org-glean--path-in-roots-p (path roots)
  "Return non-nil when PATH belongs to one of ROOTS, without symlink escape."
  (or (null roots)
      (and path (file-exists-p path)
           (cl-some (lambda (root)
                      (let ((root (file-name-as-directory (file-truename root)))
                            (true-path (file-truename path)))
                        (and (file-directory-p root) (file-in-directory-p true-path root))))
                    roots))))

(defun org-glean--in-roots-p (item roots)
  "Return non-nil when ITEM belongs to one of ROOTS, without symlink escape."
  (org-glean--path-in-roots-p (alist-get :path item) roots))

(provide 'org-glean-core)
;;; org-glean-core.el ends here
