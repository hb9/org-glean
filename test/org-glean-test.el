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

(ert-deftest org-glean-test-preview-keeps-results-window-selected ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "preview.org" root)
                           "* Preview heading\npreviewterm\n")
    (org-glean-reconcile)
    (let* ((item (car (org-glean-search "previewterm")))
           (results (get-buffer-create "*Org Glean Preview Test*"))
           (origin-window (selected-window)))
      (unwind-protect
          (progn
            (switch-to-buffer results)
            (org-glean-open-result item t)
            (should (eq results (window-buffer origin-window)))
            (let ((preview-window (get-buffer-window
                                   (get-file-buffer (alist-get :path item)))))
              (should (window-live-p preview-window))
              (should (not (eq preview-window origin-window)))
              (with-current-buffer (window-buffer preview-window)
                (should (org-at-heading-p)))))
        (when (buffer-live-p results) (kill-buffer results))
        (let ((source (get-file-buffer (expand-file-name "preview.org" root))))
          (when (buffer-live-p source) (kill-buffer source)))))))

(ert-deftest org-glean-test-tab-previews-selected-member-in-expanded-group ()
  (org-glean-test--corpus
    (let* ((path-a (expand-file-name "a.org" root))
           (path-b (expand-file-name "b.org" root))
           (key-b nil))
      (org-glean-test--write path-a "* ServiceOps\nA\n")
      (org-glean-test--write path-b "* ServiceOps\nB\n")
      (org-glean-reconcile)
      (let* ((items (mapcar (lambda (item)
                              (org-glean--alist-put :match-type 'fuzzy
                               (org-glean--alist-put :score 91 item)))
                            (org-glean--results
                             (sqlite-select (org-glean--db)
                                            "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE kind='heading' ORDER BY path"))))
             (a (car items))
             (b (cadr items))
             (key-b (alist-get :key b))
             (group-key (list (alist-get :path a) (alist-get :title a)))
             (results-buffer (get-buffer-create "*Org Glean Expanded Preview*"))
             (origin (selected-window)))
        (set-window-buffer origin results-buffer)
        (with-current-buffer results-buffer
          (org-glean-results-mode)
          (setq org-glean--results-query "ServiceOps"
                org-glean--results-groups (list (cons group-key (list a b)))
                org-glean--results-expanded-groups (list group-key)
                tabulated-list-entries (mapcar #'org-glean--tabulated-row (list a b)))
           (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () key-b)))
             (should (equal path-b (alist-get :path (org-glean--tabulated-row-result))))
             (org-glean-results-preview))
           (let ((window (get-buffer-window (get-file-buffer path-b))))
             (should (window-live-p window))
             (should (= (window-point window) (alist-get :position b))))
          (should (eq results-buffer (window-buffer origin)))
          (save-window-excursion
            (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () key-b)))
              (org-glean-results-visit)
              (should (equal "ServiceOps" (string-trim (org-get-heading t t t t)))))))
        (when (buffer-live-p results-buffer) (kill-buffer results-buffer))
        (dolist (path (list path-a path-b))
          (let ((buffer (get-file-buffer path)))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest org-glean-test-stable-id-navigation-locates-heading-after-edits ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "stable.org" root)))
      (org-glean-test--write path
                             "* Stable target\n:PROPERTIES:\n:ID: stable-target\n:END:\nbodyterm\n")
      (org-glean-reconcile)
      (let ((result (car (org-glean-search "bodyterm"))))
        (org-glean-test--write path
                               "* New heading before\ntext\n* Stable target\n:PROPERTIES:\n:ID: stable-target\n:END:\nbodyterm\n")
        ;; The indexed target is stale; reconciliation updates its point. A
        ;; previously held ID result should then navigate to the moved heading.
        (org-glean-reconcile)
        (org-glean-visit result)
        (should (equal "stable-target" (org-entry-get nil "ID")))
        (should (equal "Stable target" (org-get-heading t t t t)))))))

(ert-deftest org-glean-test-result-groups-collapse-repeated-fuzzy-headings ()
  (let* ((first '((:key . "one") (:path . "/notes/hours.org")
                  (:title . "ServiceOps") (:kind . "heading") (:match-type . fuzzy)
                  (:score . 91) (:source-current . t)))
         (second '((:key . "two") (:path . "/notes/hours.org")
                   (:title . "ServiceOps") (:kind . "heading") (:match-type . fuzzy)
                   (:score . 90) (:source-current . t)))
         (other '((:key . "other") (:path . "/notes/service.org")
                  (:title . "service ops") (:kind . "file") (:match-type . exact)
                  (:score . 100) (:source-current . t)))
         (groups (org-glean--result-groups (list first other second)))
         (repeated (cl-find-if (lambda (group) (> (length (cdr group)) 1)) groups))
         (org-glean--results-groups groups)
         (org-glean--results-expanded-groups nil))
    (should (= 2 (length groups)))
    (should (= 2 (length (cdr repeated))))
    (should (= 2 (length (org-glean--tabulated-rows))))
    (should (equal "service ops" (aref (cadar (org-glean--tabulated-rows)) 0)))
    (should (equal "ServiceOps (2 matches; e expands)"
                   (aref (cadr (car (last (org-glean--tabulated-rows)))) 0)))
    (setq org-glean--results-expanded-groups (list (car repeated)))
    (should (= 3 (length (org-glean--tabulated-rows))))))

(ert-deftest org-glean-test-result-sort-prioritizes-exact-then-lexical-then-fuzzy ()
  (let* ((fuzzy '((:match-type . fuzzy) (:score . 99)))
         (lexical '((:match-type . lexical) (:score . 70)))
         (exact '((:match-type . exact) (:score . 10)))
         (sorted (sort (list fuzzy lexical exact) #'org-glean--relevance-before-p)))
    (should (eq exact (nth 0 sorted)))
    (should (eq lexical (nth 1 sorted)))
    (should (eq fuzzy (nth 2 sorted)))))

(ert-deftest org-glean-test-result-sort-retains-lexical-bm25-order ()
  (let* ((lexical-best '((:match-type . lexical) (:score . 94.0)))
         (lexical-next '((:match-type . lexical) (:score . 93.99)))
         (fuzzy '((:match-type . fuzzy) (:score . 80.0)))
         (sorted (sort (list lexical-next fuzzy lexical-best)
                       #'org-glean--relevance-before-p)))
    (should (eq lexical-best (nth 0 sorted)))
    (should (eq lexical-next (nth 1 sorted)))
    (should (eq fuzzy (nth 2 sorted)))))

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

(ert-deftest org-glean-test-lexical-provider-failure-is-explicit ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root)
                           "* Fallback subject\nlexicalfailureprobe\n")
    (org-glean-reconcile)
    (let ((real-select (symbol-function 'sqlite-select)))
      (cl-letf (((symbol-function 'sqlite-select)
                 (lambda (db sql &optional values)
                   (if (string-match-p "target_fts MATCH" sql)
                       (error "injected FTS provider failure")
                     (funcall real-select db sql values)))))
        (let ((response (org-glean-search-api "lexicalfailureprobe" 5 nil)))
          (should (= 0 (alist-get 'candidate-count response)))
          (should (equal '(exact) (alist-get 'used response)))
          (should (eq 'incomplete (alist-get 'completeness response)))
          (should (eq t (alist-get 'truncated response)))
          (should (eq 'provider-error (alist-get 'degraded response)))
          (should (= 1 (length (alist-get 'provider-errors response))))
          (should (eq 'lexical
                      (alist-get 'provider
                                 (aref (alist-get 'provider-errors response) 0)))))))))

(ert-deftest org-glean-test-fuzzy-provider-runs-after-lexical-failure ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root)
                           "* Knowledge Graph\nbody\n")
    (org-glean-reconcile)
    (let ((real-select (symbol-function 'sqlite-select)))
      (cl-letf (((symbol-function 'sqlite-select)
                 (lambda (db sql &optional values)
                   (if (string-match-p "target_fts MATCH" sql)
                       (error "injected FTS provider failure")
                     (funcall real-select db sql values)))))
        (let* ((response (org-glean-search-api "Knowlege Grahp" 5 t))
               (results (alist-get 'results response)))
          (should (= 1 (length results)))
          (should (eq 'fuzzy (alist-get :match-type (aref results 0))))
          (should (equal '(exact fuzzy) (alist-get 'used response)))
          (should (eq 'incomplete (alist-get 'completeness response)))
          (should (eq 'provider-error (alist-get 'degraded response))))))))

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

(ert-deftest org-glean-test-results-buffer-renders-and-visits-rows ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "service-ops.org" root)
                           "* Fix AADSTS70011 invalid scope error during token refresh\nneedleterm\n")
    (org-glean-reconcile)
    (let ((buffer (get-buffer-create "*Org Glean Test Results*")))
      (unwind-protect
          (with-current-buffer buffer
            (org-glean-results-mode)
            (setq org-glean--results-query "needleterm")
            (org-glean-results-refresh)
            (should (eq #'org-glean-results-preview
                        (lookup-key org-glean-results-mode-map (kbd "TAB"))))
            (should (eq #'org-glean-results-visit
                        (lookup-key org-glean-results-mode-map (kbd "RET"))))
            (should (= 1 (length tabulated-list-entries)))
            (should (equal '("id-key" ["title" "heading" "source.org" "lexical" "yes"])
                           (org-glean--tabulated-entry
                            '((:key . "id-key") (:title . "title") (:kind . "heading")
                               (:path . "/tmp/source.org") (:match-type . lexical)
                               (:source-current . t)))))
            (should (listp (car tabulated-list-entries)))
            (should (vectorp (cadr (car tabulated-list-entries))))
            (goto-char (point-min))
            (while (and (not (tabulated-list-get-id))
                        (= 0 (forward-line 1)))
              nil)
            (should (equal (tabulated-list-get-id) (car (car tabulated-list-entries))))
            (save-window-excursion
              (org-glean-results-visit)
              (should (equal (file-truename (expand-file-name "service-ops.org" root))
                             (file-truename buffer-file-name)))
              (should (org-at-heading-p))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

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

(ert-deftest org-glean-test-search-pages-past-excluded-prefix-before-filling-limit ()
  (org-glean-test--corpus
    (dotimes (n 105)
      (org-glean-test--write
       (expand-file-name (format "a%03d.org" n) root)
       "#+PROPERTY: CAPTURE_POLICY none\n* Hidden match\nsharedneedle\n"))
    (org-glean-test--write (expand-file-name "z-eligible.org" root)
                           "* Eligible destination\nsharedneedle\n")
    (let ((org-glean-search-page-size 20))
      (org-glean-reconcile)
      (let* ((response (org-glean-search-api
                        "sharedneedle" 1 nil '(:exclude-property-values ("none"))))
             (results (alist-get 'results response)))
        (should (= 1 (length results)))
        (should (equal "Eligible destination" (alist-get :title (aref results 0))))
        (should (eq 'sources-checked-current (alist-get 'freshness response)))
        (should (eq 'complete (alist-get 'completeness response)))))))

(ert-deftest org-glean-test-mcp-root-filter-applied-before-result-limit ()
  (org-glean-test--corpus
    (let* ((allowed (expand-file-name "allowed" root))
           (other (expand-file-name "other" root))
           (org-glean-roots (list (list "all" root nil nil)))
           (org-glean-mcp-allowed-roots (list allowed)))
      (org-glean-test--write (expand-file-name "a.org" other) "* Outside\nrootneedle\n")
      (org-glean-test--write (expand-file-name "z.org" allowed) "* Inside\nrootneedle\n")
      (org-glean-reconcile)
      (let* ((decoded (json-parse-string
                       (org-glean-mcp--handler '((query . "rootneedle") (limit . 1)))
                       :object-type 'alist))
             (results (alist-get 'results decoded)))
        (should (= 1 (length results)))
        (should (string-prefix-p allowed (alist-get 'path (aref results 0))))))))

(ert-deftest org-glean-test-search-work-budget-reports-incomplete-empty ()
  (org-glean-test--corpus
    (dotimes (n 12)
      (org-glean-test--write
       (expand-file-name (format "%02d.org" n) root)
       "#+PROPERTY: CAPTURE_POLICY none\n* Hidden\nrareprobe\n"))
    (org-glean-reconcile)
    (let* ((org-glean-search-work-budget 5)
           (response (org-glean-search-api
                      "rareprobe" 2 nil '(:exclude-property-values ("none")))))
      (should (= 0 (alist-get 'candidate-count response)))
      (should (eq 'incomplete (alist-get 'completeness response)))
      (should (eq t (alist-get 'truncated response)))
      (should (eq 'incomplete (alist-get 'degraded response))))))

(ert-deftest org-glean-test-result-limit-reports-truncation ()
  (org-glean-test--corpus
    (dotimes (n 4)
      (org-glean-test--write (expand-file-name (format "%d.org" n) root)
                             (format "* Hit %d\nlimitneedle\n" n)))
    (org-glean-reconcile)
    (let ((response (org-glean-search-api "limitneedle" 2)))
      (should (= 2 (alist-get 'candidate-count response)))
      (should (eq t (alist-get 'truncated response)))
      (should (eq 'truncated (alist-get 'completeness response)))
      (should (eq :false (alist-get 'degraded response))))))

(ert-deftest org-glean-test-search-api-reports-used-modes-and-work ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "api.org" root)
                           "* API contract\napiworkneedle\n")
    (org-glean-reconcile)
    (let ((response (org-glean-search-api "apiworkneedle" 5 nil)))
      (should (= 1 (alist-get 'schema-version response)))
      (should (equal '(exact lexical) (alist-get 'used response)))
      (should (eq 'complete (alist-get 'completeness response)))
      (should (= 1 (alist-get 'work-examined response)))
      (should (= 1 (alist-get 'candidate-count response)))))
  )

(ert-deftest org-glean-test-explicit-empty-allowed-roots-fail-closed ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root)
                           "* Private heading\nprivateprobe\n")
    (org-glean-reconcile)
    (let ((response (org-glean-search-api "privateprobe" 5 nil
                                          '(:allowed-roots nil))))
      (should (= 0 (alist-get 'candidate-count response)))
      (should (eq 'complete (alist-get 'completeness response))))))

(ert-deftest org-glean-test-exactly-one-over-limit-candidate-is-truncated ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "a.org" root)
                           "* Shared title\nlimitprobe\n")
    (org-glean-test--write (expand-file-name "b.org" root)
                           "* Shared title\nlimitprobe\n")
    (org-glean-reconcile)
    (let ((response (org-glean-search-api "limitprobe" 1)))
      (should (= 1 (alist-get 'candidate-count response)))
      (should (eq t (alist-get 'truncated response)))
      (should (eq 'truncated (alist-get 'completeness response)))))
  )

(provide 'org-glean-test)
;;; org-glean-test.el ends here
