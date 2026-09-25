;;; org-glean.el --- Local semantic retrieval for Org -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Version: 0.1.0
;; Keywords: outlines, search, matching

;;; Commentary:
;; Entry point. See DESIGN.md for the architecture and ROADMAP.md for
;; current status. The database is disposable; all corpus files are read,
;; never modified.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-embed)
(require 'org-glean-chunk)
(require 'org-glean-store)
(require 'org-glean-project)
(require 'org-glean-semantic)
(require 'org-glean-index)
(require 'org-glean-search)
(require 'org-glean-ui)

(defun org-glean-install-defaults ()
  "Start background freshness updates when package is loaded in a user session."
  (when (and (not noninteractive) org-glean-roots)
    (org-glean-start)))

(add-hook 'emacs-startup-hook #'org-glean-install-defaults)

(provide 'org-glean)
;;; org-glean.el ends here
