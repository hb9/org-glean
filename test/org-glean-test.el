;;; org-glean-test.el --- Synthetic corpus tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'org-glean)

;; Keep the package tests runnable without installing the optional MCP server.
(unless (require 'mcp-server-tools nil t)
  (cl-defstruct mcp-server-tool name title description input-schema function annotations)
  (defvar mcp-server-tools--registry (make-hash-table :test #'equal))
  (defun mcp-server-register-tool (tool)
    (puthash (mcp-server-tool-name tool) tool mcp-server-tools--registry))
  (provide 'mcp-server-tools))
(require 'org-glean-mcp)

(defmacro org-glean-test--corpus (&rest body)
  "Run BODY in an isolated temporary corpus and database."
  (declare (indent 0))
  `(let* ((root (make-temp-file "org-glean-test-" t))
          (org-glean-roots (list (list "fixture" root nil nil)))
          (org-glean-database-file (expand-file-name "index.sqlite" root))
          (org-glean--database nil))
     (unwind-protect (progn ,@body)
       (org-glean-close)
       (delete-directory root t))))

(defun org-glean-test--write (path text)
  "Write TEXT to PATH, creating its parent directory."
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert text)))

(ert-deftest org-glean-test-reconcile-and-search ()
  (org-glean-test--corpus
    (let* ((nested (expand-file-name "nested/a.org" root))
           (other (expand-file-name "b.org" root)))
      (org-glean-test--write nested "#+title: Fruit\nIntro apple\n* Same\n:PROPERTIES:\n:ID: stable-1\n:END:\nbanana\n* Same\nkiwi\n")
      (org-glean-test--write other "#+title: Other\n* Pear\norange\n")
      (should (equal 2 (plist-get (org-glean-reconcile) :added)))
      (should (equal 2 (plist-get (org-glean-reconcile) :unchanged)))
      (let ((matches (org-glean-search-exact "Same")))
        (should (= 2 (length matches)))
        (should (not (equal (alist-get :key (car matches))
                            (alist-get :key (cadr matches)))))
        (should (equal "stable-1" (alist-get :org-id (car matches))))
        (should-not (alist-get :org-id (cadr matches))))
      (should (= 1 (length (org-glean-search "banana"))))
      (should (= 1 (length (org-glean-search "kiwi"))))
      (should (equal "file" (alist-get :kind (car (org-glean-search "apple")))))
      (should (= 1 (length (org-glean-search "orange" 1))))
      (org-glean-test--write nested "#+title: Fruit\n* Same\n:PROPERTIES:\n:ID: stable-1\n:END:\ngrape\n")
      (should (= 1 (plist-get (org-glean-reconcile) :changed)))
      (should-not (org-glean-search "banana"))
      (should (= 1 (length (org-glean-search "grape"))))
      (delete-file other)
      (should (= 1 (plist-get (org-glean-reconcile) :removed)))
      (should-not (org-glean-search "orange"))
      (should (= 2 (caar (sqlite-select (org-glean--db) "SELECT count(*) FROM targets")))))))

(ert-deftest org-glean-test-property-drawer-after-planning-line ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root)
                           "* Heading\nSCHEDULED: <2026-09-24 Thu>\n:PROPERTIES:\n:ID: scheduled-id\n:END:\nbody\n")
    (org-glean-reconcile)
    (should (equal "scheduled-id"
                   (alist-get :org-id (car (org-glean-search-exact "Heading")))))))

(ert-deftest org-glean-test-properties-inherit-from-ancestor-headings ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "note.org" root)
     "* Project\n:PROPERTIES:\n:PROJECT: blue\n:END:\n** Child\nbodyterm\n")
    (org-glean-reconcile)
    (let* ((response (org-glean-search-api "bodyterm" 10 nil
                                           '(:property-equals (("PROJECT" . "blue")))))
           (results (alist-get 'results response)))
      (should (= 1 (length results)))
      (should (equal '((PROJECT . "blue")) (alist-get :properties (aref results 0)))))))

(ert-deftest org-glean-test-nearest-property-override-and-generic-filter ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "note.org" root)
     "* Project\n:PROPERTIES:\n:PROJECT: blue\n:END:\n** Child\n:PROPERTIES:\n:PROJECT: red\n:END:\nneedleterm\n")
    (org-glean-reconcile)
    (let ((red (org-glean-search-api "needleterm" 10 nil
                                     '(:property-equals (("PROJECT" . "red")))))
          (blue (org-glean-search-api "needleterm" 10 nil
                                      '(:property-equals (("PROJECT" . "blue"))))))
      (should (= 1 (alist-get 'candidate-count red)))
      (should (= 0 (alist-get 'candidate-count blue))))))

(ert-deftest org-glean-test-failed-replacement-preserves-previous ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root)))
      (org-glean-test--write path "* First\noldterm\n")
      (org-glean-reconcile)
      (org-glean-test--write path "* Second\nnewterm\n")
      (cl-letf (((symbol-function 'org-glean--project)
                 (lambda (&rest _) (error "Injected parse failure"))))
        (should (= 1 (length (plist-get (org-glean-reconcile) :failed)))))
      (should (org-glean-search "oldterm"))
      (should-not (org-glean-search "newterm"))
      (should (= 1 (plist-get (org-glean-reconcile) :changed)))
      (should (org-glean-search "newterm")))))

(ert-deftest org-glean-test-failed-database-write-rolls-back ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root)))
      (org-glean-test--write path "* Old\noldterm\n")
      (org-glean-reconcile)
      (org-glean-test--write path "* New\nnewterm\n")
      (let ((original (symbol-function 'sqlite-execute))
            (failed nil))
        (cl-letf (((symbol-function 'sqlite-execute)
                   (lambda (db sql &optional values)
                     (if (and (not failed) (string-prefix-p "INSERT INTO targets" sql))
                         (progn (setq failed t) (error "Injected database write failure"))
                       (funcall original db sql values)))) )
          (should (= 1 (length (plist-get (org-glean-reconcile) :failed))))))
      (should (org-glean-search "oldterm"))
      (should-not (org-glean-search "newterm"))
      (should (= 1 (plist-get (org-glean-reconcile) :changed)))
      (should (org-glean-search "newterm")))))

(ert-deftest org-glean-test-root-selection-and-symlink ()
  (org-glean-test--corpus
    (let* ((external (make-temp-file "org-glean-external-" nil ".org"))
           (org-glean-roots (list (list "fixture" root '("\\`keep/") '("private")))))
      (unwind-protect
          (progn
            (org-glean-test--write (expand-file-name "keep/yes.org" root) "* Yes\n")
            (org-glean-test--write (expand-file-name "keep/private.org" root) "* No\n")
            (org-glean-test--write (expand-file-name "skip.org" root) "* Skip\n")
            (make-symbolic-link external (expand-file-name "keep/link.org" root))
            (should (= 1 (plist-get (org-glean-reconcile) :added)))
            (should (org-glean-search-exact "Yes"))
            (should-not (org-glean-search-exact "No")))
        (delete-file external)))))

(ert-deftest org-glean-test-provisional-navigation-rejects-stale ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root)))
      (org-glean-test--write path "* Repeat\nfirst\n* Repeat\nsecond\n")
      (org-glean-reconcile)
      (let ((second (cadr (org-glean-search-exact "Repeat"))))
        (should (equal 2 (length (org-glean-search-exact "Repeat"))))
        (org-glean-test--write path "* Repeat\ninserted\n* Repeat\nfirst\n* Repeat\nsecond\n")
        (should-error (org-glean-visit second) :type 'user-error)))))

(ert-deftest org-glean-test-stable-id-resolves-after-source-move ()
  (org-glean-test--corpus
    (let* ((old-path (expand-file-name "old.org" root))
           (new-path (expand-file-name "new.org" root)))
      (org-glean-test--write old-path "* Stable\n:PROPERTIES:\n:ID: move-me\n:END:\nbody\n")
      (org-glean-reconcile)
      (let ((result (car (org-glean-search-exact "Stable"))))
        (rename-file old-path new-path)
        (let ((counts (org-glean-reconcile)))
          (should (= 1 (plist-get counts :added)))
          (should (= 1 (plist-get counts :removed))))
        (save-window-excursion
          (org-glean-visit result)
          (should (equal (file-truename new-path) (file-truename buffer-file-name)))
          (should (org-at-heading-p))
          (should (equal "move-me" (org-entry-get nil "ID"))))))))

(ert-deftest org-glean-test-duplicate-org-id-refuses-navigation ()
  (org-glean-test--corpus
    (let ((one (expand-file-name "one.org" root))
          (two (expand-file-name "two.org" root)))
      (org-glean-test--write one "* Duplicate\n:PROPERTIES:\n:ID: same-id\n:END:\n")
      (org-glean-reconcile)
      (let ((result (car (org-glean-search-exact "Duplicate"))))
        (org-glean-test--write two "* Duplicate\n:PROPERTIES:\n:ID: same-id\n:END:\n")
        (org-glean-reconcile)
        (should-error (org-glean-visit result) :type 'user-error)))))

(ert-deftest org-glean-test-invalid-root-scan-does-not-delete-index ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root)))
      (org-glean-test--write path "* Keep\nsearchable\n")
      (org-glean-reconcile)
      (let ((org-glean-roots nil))
        (should (plist-get (org-glean-reconcile) :scan-error)))
      (should (org-glean-search "searchable")))))

(ert-deftest org-glean-test-transient-invalid-root-does-not-remove-sources ()
  (org-glean-test--corpus
    (let* ((path (expand-file-name "note.org" root))
           (original-roots org-glean-roots))
      (org-glean-test--write path "* Keep\npersistentterm\n")
      (org-glean-reconcile)
      (let ((org-glean-roots '(("broken" "/no/such/org-root" nil nil))))
        (should (plist-get (org-glean-reconcile) :scan-error)))
      (let ((org-glean-roots original-roots))
        (should (= 1 (length (org-glean-search "persistentterm"))))))))

(ert-deftest org-glean-test-invalid-fts-query-does-not-disable-fuzzy-search ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root) "* SQLite transactions\nbody\n")
    (org-glean-reconcile)
    (let ((results (org-glean-search "[" 10 t)))
      (should (<= (length results) 10)))))

(ert-deftest org-glean-test-save-hook-updates-one-file ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root)))
      (org-glean-test--write path "#+PROPERTY: CAPTURE_POLICY none\n#+PROPERTY: PROJECT red\n* Heading\noldterm\n")
      (org-glean-reconcile)
      (org-glean-test--write path "#+PROPERTY: CAPTURE_POLICY eligible\n#+PROPERTY: PROJECT blue\n* Heading\nnewterm\n")
      (with-temp-buffer
        (setq buffer-file-name path)
        (org-mode)
        (org-glean--after-save))
      (should (equal (list path) org-glean--pending-files))
      (org-glean--flush-saved-files)
      (should-not (org-glean-search "oldterm"))
      (let* ((response (org-glean-search-api "newterm" 10 nil
                                             '(:property-equals (("PROJECT" . "blue")))))
             (results (alist-get 'results response)))
        (should (= 1 (length results)))
        (should (eq 'sources-checked-current (alist-get 'freshness response)))
        (should (equal "eligible" (alist-get :capture-policy (aref results 0))))
        (let ((none (org-glean-search-api "newterm" 10 nil
                                          '(:property-equals (("PROJECT" . "red"))))))
          (should (= 0 (alist-get 'candidate-count none))))))))

(ert-deftest org-glean-test-fuzzy-search-is-bounded-and-typed ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root) "* Knowledge Graph\nbody\n")
    (org-glean-reconcile)
    (let* ((response (org-glean-search-api "Knowlege Grahp" 10 t))
           (results (alist-get 'results response)))
      (should (= 1 (length results)))
      (should (eq 'fuzzy (alist-get :match-type (aref results 0)))))))

(ert-deftest org-glean-test-mcp-adapter-bounds-root-and-serializes-json ()
  (org-glean-test--corpus
    (let* ((path (expand-file-name "note.org" root))
           (org-glean-mcp-allowed-roots (list root)))
      (org-glean-test--write path "* Heading\nneedle\n")
      (org-glean-reconcile)
      (let* ((json (org-glean-mcp--handler '((query . "needle") (limit . 2))))
             (decoded (json-parse-string json :object-type 'alist)))
        (should (equal "sources-checked-current" (alist-get 'freshness decoded)))
        (should (= 1 (length (alist-get 'results decoded))))
        (should (equal "heading" (alist-get 'kind (aref (alist-get 'results decoded) 0))))))))

(ert-deftest org-glean-test-mcp-handler-fails-closed-with-no-roots ()
  (let ((org-glean-roots nil)
        (org-glean-mcp-allowed-roots nil))
    (should (string-match-p "No Org Glean root is allowed"
                            (org-glean-mcp--handler '((query . "secret")))))))

(ert-deftest org-glean-test-filters-do-not-hide-stale-source-state ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root)))
      (org-glean-test--write path "* Hidden\nstaleterm\n")
      (org-glean-reconcile)
      (org-glean-test--write path "* Changed\nnewbody\n")
      (let ((response (org-glean-search-api "staleterm" 10 nil
                                            '(:exclude-titles ("Hidden")))))
        (should (= 0 (alist-get 'candidate-count response)))
        (should (eq 'stale-source-present (alist-get 'freshness response)))))))

(provide 'org-glean-test)
;;; org-glean-test.el ends here
