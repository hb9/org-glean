;;; org-glean-model-test.el --- Opt-in real-model semantic tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Run with `make test-model'. Requires a real installed model (default
;; e5-small; run M-x org-glean-install first). Not part of `make test': it
;; needs network-free but real ONNX inference, which is slow and requires
;; the managed venv to actually exist. See ROADMAP.md phase 1.

(require 'ert)
(require 'cl-lib)
(require 'org-glean)

(defvar org-glean-model-test-preset "e5-small")

(when (getenv "ORG_GLEAN_VENV_DIR")
  (setq org-glean-semantic-venv-dir (getenv "ORG_GLEAN_VENV_DIR")))

(unless (org-glean-embed-available-p org-glean-model-test-preset)
  (error "org-glean-model-test: preset %s is not installed under %s; run M-x org-glean-install first, or set ORG_GLEAN_VENV_DIR"
         org-glean-model-test-preset org-glean-semantic-venv-dir))

(defmacro org-glean-model-test--corpus (&rest body)
  (declare (indent 0))
  `(let* ((root (make-temp-file "org-glean-model-test-" t))
          (org-glean-roots (list (list "fixture" root nil nil)))
          (org-glean-database-file (expand-file-name "index.sqlite" root))
          (org-glean--database nil)
          (org-glean-semantic-model org-glean-model-test-preset))
     (unwind-protect (progn ,@body)
       (org-glean-close)
       (org-glean-embed-stop)
       (delete-directory root t))))

(defun org-glean-model-test--write (path text)
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert text)))

(defun org-glean-model-test--drain-queue ()
  (let (done)
    (while (not done)
      (org-glean--semantic-queue-process-batch (lambda (n) (setq done (= n 0))))
      (let ((deadline (+ (float-time) 60)))
        (while (and org-glean--semantic-queue-inflight (< (float-time) deadline))
          (accept-process-output nil 0.05))))))

(ert-deftest org-glean-model-test-self-test-passes ()
  (should (org-glean--install-self-test org-glean-model-test-preset)))

(ert-deftest org-glean-model-test-cross-language-weld-inspection ()
  (org-glean-model-test--corpus
    (org-glean-model-test--write
     (expand-file-name "welds.org" root)
     "#+title: Manufacturing Quality\n* Schweißnahtprüfung Protokoll\nDokumentation der Prüfung an Baugruppe 12. Sichtprüfung und Ultraschall durchgeführt.\n")
    (org-glean-model-test--write
     (expand-file-name "sales.org" root)
     "#+title: Sales\n* Quarterly sales figures\nRevenue grew 12 percent this quarter across all regions.\n")
    (org-glean-reconcile)
    (org-glean-model-test--drain-queue)
    (org-glean-embed-stop) ; force the SQL-reload path, not the just-embedded cache
    (let ((items (org-glean--semantic-search-provider "weld inspection" nil 5)))
      (should items)
      ;; The file- and heading-level chunks for welds.org are close in score
      ;; and either may legitimately rank first (no file/heading tie-break
      ;; exists yet; see ROADMAP.md phase 2 aggregation); what matters is
      ;; that the correct file, not the distractor, is the top result.
      (should (equal "welds.org" (file-name-nondirectory (alist-get :path (car items))))))))

(ert-deftest org-glean-model-test-no-term-overlap-revenue ()
  (org-glean-model-test--corpus
    (org-glean-model-test--write
     (expand-file-name "sales.org" root)
     "#+title: Sales\n* Quarterly sales figures\nRevenue grew 12 percent this quarter across all regions.\n")
    (org-glean-model-test--write
     (expand-file-name "recipe.org" root)
     "#+title: Kitchen\n* Bread recipe\nMix flour water yeast and salt, let it rise overnight.\n")
    (org-glean-reconcile)
    (org-glean-model-test--drain-queue)
    (let ((items (org-glean--semantic-search-provider "how is revenue trending" nil 5)))
      (should items)
      (should (equal "Quarterly sales figures" (alist-get :title (car items)))))))

(ert-deftest org-glean-model-test-search-api-semantic-mode-end-to-end ()
  (org-glean-model-test--corpus
    (org-glean-model-test--write
     (expand-file-name "recipe.org" root)
     "#+title: Kitchen\n* Bread recipe\nMix flour water yeast and salt, let it rise overnight.\n")
    (org-glean-reconcile)
    (org-glean-model-test--drain-queue)
    (let ((response (org-glean-search-api "baking bread at home" 5 nil nil
                                          '(exact lexical semantic))))
      (should (memq 'semantic (alist-get 'used response)))
      (should (= 0 (length (alist-get 'provider-errors response))))
      (should (> (alist-get 'candidate-count response) 0)))))

(provide 'org-glean-model-test)
;;; org-glean-model-test.el ends here
