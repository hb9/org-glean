;;; org-glean-eligibility.el --- Capture-eligibility classification -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.
;;
;; A capture agent, once org-glean-search has named plausible destination
;; files, needs to know whether writing to each of them is actually a good
;; idea: a closed project's main note and a retired yearly task file are
;; real search hits, but neither is somewhere new material should land.
;; This module answers exactly that question, from the KIND/STATUS/ROLE
;; file-header convention (see org-knowledge's
;; docs/agentic-setup-ii/20261001T195659--capture-workflow__agentic.org
;; §6.3/§6.5/§7), which replaces the older standalone CAPTURE_POLICY
;; property. It never writes anything, anywhere, ever.
;;
;; The one thing this needs that a single file's own header cannot answer
;; is a SIDE file's status: a side file deliberately carries no STATUS of
;; its own (§7.3) and inherits it from its project's main file. Finding
;; that main file is the one piece of cross-file lookup this module adds;
;; everything else is a single file's own properties, exactly as
;; `org-glean-outline' already returns them.
;;
;; Reads every file fresh from disk via a throwaway temp buffer, exactly
;; like `org-glean-outline.el' and `org-glean-project.el''s own indexing
;; pass: no live buffer, no auto-id side effect, no unsaved-edit
;; staleness.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-outline)
(require 'cl-lib)

(defun org-glean--eligibility-project-token (path)
  "Return PATH's pr_<token> project token from its Denote filename, or nil.
Mirrors org-knowledge's `extract_denote_metadata': the token immediately
following a \"pr\" component in the filename's __tag1_tag2 suffix,
regardless of any further qualifying tags after it (so
\"flat-aquisition-contract__pr_flat_legal.org\" and
\"flat-finckensteinallee-89__pr_flat.org\" both resolve to \"flat\")."
  (let* ((stem (file-name-base path))
         (dash (string-search "--" stem)))
    (when dash
      (let ((remainder (substring stem (+ dash 2))))
        (when (string-match "__\\(.+\\)\\'" remainder)
          (let* ((tags (split-string (match-string 1 remainder) "_" t))
                 (pos (cl-position "pr" tags :test #'equal)))
            (when (and pos (< (1+ pos) (length tags)))
              (nth (1+ pos) tags))))))))

(defun org-glean--eligibility-file-properties (path)
  "Return PATH's own file-level properties, read fresh from disk."
  (alist-get :properties (org-glean--outline-file path)))

(defun org-glean--eligibility-sibling-paths (path token)
  "Return PATH's siblings sharing project TOKEN, within PATH's own root.
Scoped to the same `org-glean-roots' entry PATH belongs to, by filename
only (never opens a file this does not already plan to read). PATH
itself is excluded from the result."
  (let ((root (cdr (org-glean--root-for path))))
    (when root
      (cl-remove-if-not
       (lambda (candidate)
         (and (not (equal (expand-file-name candidate) (expand-file-name path)))
              (equal token (org-glean--eligibility-project-token candidate))))
       (directory-files-recursively root "\\.org\\'")))))

(defun org-glean--eligibility-find-main (path)
  "Find PATH's project main file by shared pr_<token>, within the same root.
Returns (MAIN-PATH . nil) when exactly one sibling has ROLE main,
(nil . REASON) otherwise, where REASON explains why none could be used:
no project token, no main sibling, or more than one (ambiguous)."
  (let ((token (org-glean--eligibility-project-token path)))
    (if (not token)
        (cons nil "file name carries no pr_<token>")
      (let* ((siblings (org-glean--eligibility-sibling-paths path token))
             (mains (cl-remove-if-not
                     (lambda (sibling)
                       (equal "main" (org-glean--property-value
                                      (org-glean--eligibility-file-properties sibling)
                                      "ROLE")))
                     siblings)))
        (cond
         ((= (length mains) 1) (cons (car mains) nil))
         ((= (length mains) 0) (cons nil (format "no ROLE main file found for project \"%s\"" token)))
         (t (cons nil (format "more than one ROLE main file found for project \"%s\"" token))))))))

(defun org-glean--eligibility-classify-one (path)
  "Return one eligibility alist for PATH.
`:result' is `preferred', `eligible' or `none'; `:reason' is a short
human-readable explanation. Never writes anything."
  (let* ((properties (org-glean--eligibility-file-properties path))
         (kind (org-glean--property-value properties "KIND"))
         (status (org-glean--property-value properties "STATUS"))
         (role (org-glean--property-value properties "ROLE")))
    (cond
     ((member kind '("log" "archive" "inbox"))
      `((:path . ,path) (:result . none)
        (:reason . ,(format "KIND is \"%s\": never a capture destination" kind))))
     ((and (member kind '("project" "area")) (equal status "closed"))
      `((:path . ,path) (:result . none)
        (:reason . ,(format "KIND is \"%s\" and STATUS is closed" kind))))
     ((equal kind "area")
      (if (equal status "active")
          `((:path . ,path) (:result . preferred)
            (:reason . "KIND is area and STATUS is active"))
        `((:path . ,path) (:result . eligible)
          (:reason . "KIND is area with no STATUS; treated as eligible, not preferred, until its status is confirmed"))))
     ((and (equal kind "project") (equal role "main"))
      (if (equal status "active")
          `((:path . ,path) (:result . preferred)
            (:reason . "KIND is project, ROLE is main, STATUS is active"))
        `((:path . ,path) (:result . eligible)
          (:reason . "KIND is project, ROLE is main, but STATUS is neither active nor closed"))))
     ((and (equal kind "project") (equal role "side"))
      (pcase-let ((`(,main . ,no-main-reason) (org-glean--eligibility-find-main path)))
        (if (not main)
            `((:path . ,path) (:result . eligible)
              (:reason . ,(format "ROLE is side, but its main file could not be resolved (%s); treated as eligible rather than guessing" no-main-reason)))
          (let ((main-status (org-glean--property-value
                               (org-glean--eligibility-file-properties main) "STATUS")))
            (if (equal main-status "closed")
                `((:path . ,path) (:result . none)
                  (:reason . ,(format "ROLE is side; its main file %s has STATUS closed" main)))
              `((:path . ,path) (:result . eligible)
                (:reason . ,(format "ROLE is side; its main file %s is not closed" main))))))))
     ((and (equal kind "project") (not role))
      `((:path . ,path) (:result . eligible)
        (:reason . "KIND is project but ROLE is unset; treated as eligible pending convention cleanup, not assumed main")))
     (t
      `((:path . ,path) (:result . eligible)
        (:reason . ,(if kind
                        (format "KIND is \"%s\": eligible, not preferred" kind)
                      "no KIND set: eligible by default, today's unchanged behavior")))))))

(defun org-glean-eligibility (files)
  "Return capture eligibility for FILES, a path or list of paths.
Never writes to any file, and never touches any live buffer: each file
and any main-file lookup it needs is read fresh from disk into a
throwaway temp buffer, matching `org-glean-outline'.

Returns `((:classifications . LIST) (:errors . (((:path . PATH)
(:message . STRING)) ...)))' — one bad path never prevents
classification of the others."
  (let ((files (if (listp files) files (list files)))
        (classifications nil) (errors nil))
    (dolist (path files)
      (condition-case err
          (push (org-glean--eligibility-classify-one path) classifications)
        (error (push `((:path . ,path) (:message . ,(error-message-string err))) errors))))
    `((:classifications . ,(nreverse classifications)) (:errors . ,(nreverse errors)))))

(provide 'org-glean-eligibility)
;;; org-glean-eligibility.el ends here
