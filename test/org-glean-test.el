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

(defmacro org-glean-test--fake-backend (&rest body)
  "Run BODY with a managed venv wired to the fake, dependency-free embedder.
`org-glean-embed-available-p' passes because the expected files exist (a
`python3' wrapper that execs the real interpreter, plus placeholder model
files); the real embedding math never runs, only the fake bag-of-hashes
embedder inside org_glean_embed.py, selected by ORG_GLEAN_FAKE_EMBED."
  (declare (indent 0))
  `(let* ((venv (make-temp-file "org-glean-venv-" t))
          (org-glean-semantic-venv-dir venv)
          (org-glean-semantic-model "e5-small")
          (org-glean--embed-process nil)
          (org-glean--embed-process-preset nil)
          (org-glean--embed-responses nil)
          (org-glean--embed-callbacks nil)
          (org-glean--embed-response-buffer "")
          (org-glean--semantic-queue-timer nil)
          (org-glean--semantic-queue-state 'idle)
          (org-glean--semantic-queue-inflight nil)
          (process-environment (cons "ORG_GLEAN_FAKE_EMBED=1" process-environment)))
     (make-directory (expand-file-name "bin" venv) t)
     (let ((python (expand-file-name "bin/python3" venv)))
       (with-temp-file python
         (insert (format "#!/bin/sh\nexec %s \"$@\"\n" (executable-find "python3"))))
       (set-file-modes python #o755))
     (let ((model-dir (org-glean--embed-model-dir "e5-small")))
       (make-directory (expand-file-name "onnx" model-dir) t)
       (with-temp-file (expand-file-name "tokenizer.json" model-dir) (insert "{}"))
       (with-temp-file (expand-file-name "onnx/model.onnx" model-dir) (insert "")))
     (unwind-protect (progn ,@body)
       (org-glean-embed-stop)
       (when (timerp org-glean--semantic-queue-timer)
         (cancel-timer org-glean--semantic-queue-timer))
       (delete-directory venv t))))

(ert-deftest org-glean-test-unchanged-reconcile-never-projects-or-replaces-source ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "steady.org" root)))
      (org-glean-test--write path "* Stable\nsearchable text\n")
      (org-glean-reconcile)
      (let ((before (sqlite-select (org-glean--db)
                                   "SELECT key,title,body,digest FROM targets ORDER BY key")))
        (cl-letf (((symbol-function 'org-glean--project)
                   (lambda (&rest _) (error "unchanged source was projected"))))
          (should (= 1 (plist-get (org-glean-reconcile) :unchanged))))
        (should (equal before
                       (sqlite-select (org-glean--db)
                                       "SELECT key,title,body,digest FROM targets ORDER BY key")))))))

(ert-deftest org-glean-test-healthy-database-open-does-not-rebuild-fts ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root) "* FTS stays put\nneedle\n")
    (org-glean-reconcile)
    (org-glean-close)
    (let ((real-execute (symbol-function 'sqlite-execute))
          (rebuilds 0))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &optional values)
                   (when (string-match-p "target_fts.*rebuild" sql)
                     (cl-incf rebuilds))
                   (funcall real-execute db sql values))))
        (org-glean--db)
        (org-glean-close)
        (org-glean--db))
      (should (= 0 rebuilds))
      (should (= 1 (length (org-glean-search "needle")))))))

(ert-deftest org-glean-test-legacy-database-fts-repair-runs-once ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root) "* Legacy FTS repair\nlegacyneedle\n")
    (let ((real-execute (symbol-function 'sqlite-execute))
          (rebuilds 0))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &optional values)
                   (when (string-match-p "target_fts.*rebuild" sql)
                     (cl-incf rebuilds))
                   (funcall real-execute db sql values))))
        (org-glean-reconcile)
        (org-glean-close)
        (org-glean--db)
        (org-glean-close)
        (org-glean--db))
      (should (= 1 rebuilds))
      (should (= 1 (length (org-glean-search "legacyneedle")))))))

(ert-deftest org-glean-test-status-reports-index-and-reconcile-state ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "status.org" root) "* Status target\n")
    (org-glean-reconcile)
    (let ((status (org-glean-status)))
      (should (= 1 (plist-get status :schema-version)))
      (should (eq 'ready (plist-get status :state)))
      (should (= 1 (plist-get status :indexed-sources)))
      (should (= 2 (plist-get status :indexed-targets)))
      (should (plist-get status :last-reconcile-at))
      (should (eq 'not-installed (plist-get status :semantic-state)))
      (should (equal "e5-small" (plist-get status :semantic-model)))
      (should (= 0 (plist-get status :semantic-coverage-chunks)))
      (should (= 2 (plist-get status :semantic-coverage-total))))))

(ert-deftest org-glean-test-reconcile-populates-chunks ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "chunk.org" root)
                           "#+title: Chunked\n* Heading one\nbody text one\n* Heading two\nbody text two\n")
    (org-glean-reconcile)
    (let* ((db (org-glean--db))
           (chunks (sqlite-select db "SELECT key,target_key,text,text_digest FROM chunks ORDER BY key")))
      ;; One chunk per target: the file record plus each of the two headings.
      (should (= 3 (length chunks)))
      (dolist (row chunks)
        (should (equal (concat (nth 1 row) "#chunk:0") (nth 0 row)))
        (should (stringp (nth 2 row)))
        (should (equal (org-glean--chunk-digest (nth 2 row)) (nth 3 row)))))))

(ert-deftest org-glean-test-chunk-windows-splits-long-body-with-overlap ()
  (let* ((org-glean-chunk-max-chars 40)
         (org-glean-chunk-overlap-chars 10)
         (body (string-join (list "Paragraph one is here." "Paragraph two follows."
                                  "Paragraph three arrives." "Paragraph four ends it.")
                            "\n\n"))
         (windows (org-glean--chunk-windows body)))
    (should (> (length windows) 1))
    ;; Every paragraph's text appears in at least one window: windowing must
    ;; never drop content, only split and duplicate it at the boundary.
    (dolist (paragraph (org-glean--chunk-paragraphs body))
      (should (cl-some (lambda (window) (string-search paragraph window)) windows)))
    ;; The last paragraph of one window recurs as overlap context at the
    ;; start of the next, so a fact near a cut is not siloed into one window.
    (should (cl-some (lambda (pair)
                       (let ((a (nth 0 pair)) (b (nth 1 pair)))
                         (and (> (length a) 0)
                              (string-search (car (last (org-glean--chunk-paragraphs a))) b))))
                     (cl-mapcar #'list windows (cdr windows))))))

(ert-deftest org-glean-test-chunk-windows-empty-body-yields-no-chunks ()
  (should (null (org-glean--chunk-windows "")))
  (should (null (org-glean--chunk-windows "   \n\n  "))))

(ert-deftest org-glean-test-chunk-context-line-uses-outline-path ()
  (should (equal "File > Section > Heading"
                 (org-glean--chunk-context-line
                  (list :kind "heading" :title "Heading"
                        :outline-path '("File" "Section" "Heading")))))
  (should (equal "File Title"
                 (org-glean--chunk-context-line
                  (list :kind "file" :title "File Title")))))

(ert-deftest org-glean-test-chunk-record-text-includes-file-outline ()
  (let* ((heading-a (list :key "a" :kind "heading" :title "Alpha" :level 1
                          :outline-path '("Alpha") :body "alpha body"))
         (heading-b (list :key "b" :kind "heading" :title "Beta" :level 1
                          :outline-path '("Beta") :body "beta body"))
         (file-record (list :key "f" :kind "file" :title "Doc" :body "intro"))
         (records (list file-record heading-a heading-b))
         (file-chunks (org-glean--chunk-record file-record records)))
    (should (= 1 (length file-chunks)))
    (should (string-search "Alpha" (plist-get (car file-chunks) :text)))
    (should (string-search "Beta" (plist-get (car file-chunks) :text)))
    (should (string-search "Doc" (plist-get (car file-chunks) :text)))))

(ert-deftest org-glean-test-chunk-digest-unaffected-by-position ()
  ;; A heading that moved within its file (different :position) but has
  ;; identical context/body must keep the same chunk digest, so its vector
  ;; survives the move instead of being needlessly re-embedded.
  (let* ((records (list (list :key "moved" :kind "heading" :title "Stable"
                              :outline-path '("Stable") :body "same body" :position 1))))
    (let* ((chunk-a (car (org-glean--chunk-records records)))
           (records-moved (list (list :key "moved" :kind "heading" :title "Stable"
                                      :outline-path '("Stable") :body "same body" :position 99)))
           (chunk-b (car (org-glean--chunk-records records-moved))))
      (should (equal (plist-get chunk-a :text-digest) (plist-get chunk-b :text-digest))))))

(ert-deftest org-glean-test-unchanged-reconcile-keeps-chunk-vector ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "vector.org" root) "* Stable heading\nstable body\n")
    (org-glean-reconcile)
    (let* ((db (org-glean--db))
           (digest (caar (sqlite-select
                          db "SELECT text_digest FROM chunks WHERE target_key LIKE '%heading%' LIMIT 1"))))
      (sqlite-execute db "INSERT INTO vectors(model_id,text_digest,dim,vector) VALUES(?,?,?,?)"
                      (vector "fixture-model" digest 3 (unibyte-string 0 0 0)))
      (should (equal (cons 1 2) (org-glean--semantic-coverage db "fixture-model")))
      ;; Reconcile again with nothing changed; the vector must survive because
      ;; org-glean--replace never touches `vectors', only `chunks'.
      (org-glean-reconcile)
      (should (equal (cons 1 2) (org-glean--semantic-coverage db "fixture-model"))))))

(ert-deftest org-glean-test-removed-source-deletes-its-chunks ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "removeme.org" root)))
      (org-glean-test--write path "* Doomed\nbody\n")
      (org-glean-reconcile)
      (should (> (caar (sqlite-select (org-glean--db) "SELECT count(*) FROM chunks")) 0))
      (delete-file path)
      (org-glean-reconcile)
      (should (= 0 (caar (sqlite-select (org-glean--db) "SELECT count(*) FROM chunks")))))))

(ert-deftest org-glean-test-status-reports-degraded-root-configuration ()
  (org-glean-test--corpus
    (let ((org-glean-roots '(("missing" "/no/such/root" nil nil))))
      (let ((counts (org-glean-reconcile)))
        (should (plist-get counts :scan-error)))
      (should (eq 'degraded (plist-get (org-glean-status) :state)))
      (should (= 1 (length org-glean--last-errors))))))

(ert-deftest org-glean-test-reconcile-records-failed-source-for-diagnostics ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "diagnostic.org" root)))
      (org-glean-test--write path "* Before\n")
      (org-glean-reconcile)
      (org-glean-test--write path "* After\n")
      (cl-letf (((symbol-function 'org-glean--project)
                 (lambda (&rest _) (error "fixture projection error"))))
        (org-glean-reconcile))
      (should (equal path (caar org-glean--last-errors)))
      (should (string-match-p "fixture projection error"
                              (cdar org-glean--last-errors))))))

(ert-deftest org-glean-test-semantic-mode-is-explicitly-unavailable ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "semantic.org" root)
                           "* Information retrieval\nsearchable text\n")
    (org-glean-reconcile)
    (let* ((response (org-glean-search-api "searchable" 10 nil nil
                                           '(exact lexical fuzzy semantic)))
           (errors (alist-get 'provider-errors response)))
      (should (eq t (alist-get 'semantic (alist-get 'requested response))))
      (should (equal '(exact lexical fuzzy) (alist-get 'used response)))
      (should (eq 'incomplete (alist-get 'completeness response)))
      (should (eq 'provider-error (alist-get 'degraded response)))
      (should (= 1 (length errors)))
      (should (eq 'semantic (alist-get 'provider (aref errors 0)))))))

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
  ;; Fusion ranks by :score, but an exact match is always pinned above the
  ;; fused order regardless of its own score (see org-glean--relevance-before-p).
  (let* ((fuzzy '((:match-type . fuzzy) (:score . 10) (:pinned)))
         (lexical '((:match-type . lexical) (:score . 70) (:pinned)))
         (exact '((:match-type . exact) (:score . 1) (:pinned . t)))
         (sorted (sort (list fuzzy lexical exact) #'org-glean--relevance-before-p)))
    (should (eq exact (nth 0 sorted)))
    (should (eq lexical (nth 1 sorted)))
    (should (eq fuzzy (nth 2 sorted)))))

(ert-deftest org-glean-test-result-sort-retains-lexical-bm25-order ()
  (let* ((lexical-best '((:match-type . lexical) (:score . 94.0) (:pinned)))
         (lexical-next '((:match-type . lexical) (:score . 93.99) (:pinned)))
         (fuzzy '((:match-type . fuzzy) (:score . 80.0) (:pinned)))
         (sorted (sort (list lexical-next fuzzy lexical-best)
                       #'org-glean--relevance-before-p)))
    (should (eq lexical-best (nth 0 sorted)))
    (should (eq lexical-next (nth 1 sorted)))
    (should (eq fuzzy (nth 2 sorted)))))

(ert-deftest org-glean-test-result-sort-semantic-can-outrank-lexical ()
  ;; The whole point of fusion: a strong semantic hit competes on score with
  ;; a weak lexical one instead of being fixed below it by mode alone.
  (let* ((semantic '((:match-type . semantic) (:score . 5.0) (:pinned)))
         (lexical '((:match-type . lexical) (:score . 1.0) (:pinned)))
         (sorted (sort (list lexical semantic) #'org-glean--relevance-before-p)))
    (should (eq semantic (nth 0 sorted)))
    (should (eq lexical (nth 1 sorted)))))

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

(ert-deftest org-glean-test-embed-available-p-requires-venv-and-model ()
  (let* ((venv (make-temp-file "org-glean-venv-empty-" t))
         (org-glean-semantic-venv-dir venv))
    (unwind-protect
        (should-not (org-glean-embed-available-p "e5-small"))
      (delete-directory venv t))))

(ert-deftest org-glean-test-embed-sync-round-trip-hello-and-embed ()
  (org-glean-test--fake-backend
    (let ((hello (org-glean--embed-request-sync "hello" nil)))
      (should (equal "intfloat/multilingual-e5-small" (alist-get 'model_id hello)))
      (should (= 384 (alist-get 'dimension hello))))
    (let ((response (org-glean--embed-request-sync
                     "embed" '((texts . ["one" "two"]) (kind . "passage")))))
      (should (= 2 (length (alist-get 'vectors response)))))))

(ert-deftest org-glean-test-embed-sync-reports-backend-error-without-crashing ()
  (org-glean-test--fake-backend
    (should-error (org-glean--embed-request-sync "not-a-real-op" nil))
    ;; The process must still be usable after a bad request.
    (should (org-glean--embed-request-sync "hello" nil))))

(ert-deftest org-glean-test-embed-async-callback-receives-result ()
  (org-glean-test--fake-backend
    (let (received)
      (org-glean--embed-request "hello" nil (lambda (response) (setq received response)))
      (let ((deadline (+ (float-time) 5)))
        (while (and (not received) (< (float-time) deadline))
          (accept-process-output org-glean--embed-process 0.05)))
      (should received)
      (should (alist-get 'result received)))))

(ert-deftest org-glean-test-embed-restarts-process-on-preset-change ()
  (org-glean-test--fake-backend
    (org-glean--embed-request-sync "hello" nil)
    (let ((first (process-id org-glean--embed-process)))
      ;; Requesting the same preset again must not spawn a new process.
      (org-glean--embed-request-sync "hello" nil)
      (should (equal first (process-id org-glean--embed-process))))))

(ert-deftest org-glean-test-embed-process-exit-fails-pending-callback ()
  (org-glean-test--fake-backend
    (org-glean--embed-start-process "e5-small")
    (let (received)
      (push (cons 999 (lambda (response) (setq received response)))
            org-glean--embed-callbacks)
      (delete-process org-glean--embed-process)
      (let ((deadline (+ (float-time) 2)))
        (while (and (not received) (< (float-time) deadline))
          (sit-for 0.05)))
      (should received)
      (should (alist-get 'error received)))))

(ert-deftest org-glean-test-embed-presets-are-well-formed ()
  (let ((presets (org-glean--embed-presets)))
    (dolist (name '(e5-small e5-base bge-m3))
      (let ((info (alist-get name presets)))
        (should info)
        (should (stringp (alist-get 'model_id info)))
        (should (integerp (alist-get 'dimension info)))
        (should (integerp (alist-get 'approx_size_mb info)))))))

(ert-deftest org-glean-test-install-self-test-runs-protocol-without-erroring ()
  (org-glean-test--fake-backend
    ;; The fake embedder proves the self-test's plumbing (restart, embed,
    ;; load with the expected digests, search) runs end to end without
    ;; erroring; it deliberately does not assert the paraphrase ranks
    ;; correctly, since the fake bag-of-hashes embedder shares no tokens
    ;; between "Schweißnahtprüfung" and "weld inspection" and proves nothing
    ;; about cross-language relevance (that is make test-model's job).
    (should (memq (org-glean--install-self-test "e5-small") '(nil t)))))

(ert-deftest org-glean-test-install-self-test-detects-correct-ranking ()
  ;; Exercise the same load+search shape org-glean--install-self-test uses,
  ;; but with texts the fake embedder's bag-of-hashes CAN rank correctly
  ;; (they share tokens with the query), proving the ranking logic itself
  ;; is sound independent of any real model's language quality.
  (org-glean-test--fake-backend
    (let* ((embedded (alist-get 'vectors
                                (org-glean--embed-request-sync
                                 "embed" '((texts . ["weld inspection procedure"
                                                     "totally unrelated content"])
                                           (kind . "passage"))
                                 "e5-small")))
           (positive (aref embedded 0))
           (distractor (aref embedded 1)))
      (org-glean--embed-request-sync
       "load" `((items . (((digest . "pos") (vector . ,positive))
                          ((digest . "neg") (vector . ,distractor)))))
       "e5-small")
      (let ((results (alist-get 'results
                                (org-glean--embed-request-sync
                                 "search" '((query . "weld inspection") (k . 1)) "e5-small"))))
        (should (equal "pos" (alist-get 'digest (aref results 0))))))))

(ert-deftest org-glean-test-install-declines-without-consent ()
  (let ((venv (make-temp-file "org-glean-venv-noconsent-" t))
        (ensure-called nil))
    (unwind-protect
        (let ((org-glean-semantic-venv-dir venv))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                    ((symbol-function 'org-glean--install-ensure-venv)
                     (lambda (&rest _) (setq ensure-called t))))
            (should-error (org-glean-install "e5-small")))
          (should-not ensure-called))
      (delete-directory venv t))))

(ert-deftest org-glean-test-install-runs-steps-in-order-and-reports-self-test-failure ()
  (let ((venv (make-temp-file "org-glean-venv-pipeline-" t))
        (steps nil))
    (unwind-protect
        (let ((org-glean-semantic-venv-dir venv))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                    ((symbol-function 'org-glean--install-ensure-venv)
                     (lambda (&rest _) (push 'venv steps)))
                    ((symbol-function 'org-glean--install-download-model)
                     (lambda (&rest _) (push 'download steps)))
                    ((symbol-function 'org-glean--install-self-test)
                     (lambda (&rest _) (push 'self-test steps) nil))
                    ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
            (should-error (org-glean-install "e5-small") :type 'error)
            (should (equal '(self-test download venv) steps))))
      (delete-directory venv t))))

(ert-deftest org-glean-test-install-unknown-preset-is-rejected ()
  (let ((venv (make-temp-file "org-glean-venv-badpreset-" t)))
    (unwind-protect
        (let ((org-glean-semantic-venv-dir venv))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (should-error (org-glean-install "not-a-real-preset"))))
      (delete-directory venv t))))

(defun org-glean-test--wait-for (predicate &optional seconds)
  "Pump the Emacs event loop until PREDICATE is non-nil or SECONDS elapse."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (sit-for 0.05))
    (funcall predicate)))

(ert-deftest org-glean-test-semantic-queue-embeds-pending-chunks-in-a-batch ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody text\n")
      (org-glean-reconcile)
      (let* ((db (org-glean--db))
             (before (org-glean--semantic-coverage db "e5-small")))
        (should (= 0 (car before)))
        (should (> (cdr before) 0))
        (let (done)
          (org-glean--semantic-queue-process-batch (lambda (n) (setq done n)))
          (should (org-glean-test--wait-for (lambda () done)))
          (should (> done 0)))
        (let ((after (org-glean--semantic-coverage db "e5-small")))
          (should (equal after (cons (cdr before) (cdr before)))))))))

(ert-deftest org-glean-test-semantic-queue-batch-is-noop-when-nothing-pending ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody text\n")
      (org-glean-reconcile)
      (let (first-done)
        (org-glean--semantic-queue-process-batch (lambda (n) (setq first-done n)))
        (org-glean-test--wait-for (lambda () first-done)))
      (let (second-done)
        (org-glean--semantic-queue-process-batch (lambda (n) (setq second-done n)))
        (should (org-glean-test--wait-for (lambda () second-done)))
        (should (= 0 second-done))))))

(ert-deftest org-glean-test-semantic-queue-skips-batch-while-one-in-flight ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody text\n")
      (org-glean-reconcile)
      (let (first-done second-done)
        (org-glean--semantic-queue-process-batch (lambda (n) (setq first-done n)))
        ;; A second call while the first is still in flight must not race it.
        (org-glean--semantic-queue-process-batch (lambda (n) (setq second-done n)))
        (should (= 0 second-done))
        (should (org-glean-test--wait-for (lambda () first-done)))
        (should (> first-done 0))))))

(ert-deftest org-glean-test-semantic-queue-batch-noop-when-backend-unavailable ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody\n")
    (org-glean-reconcile)
    (let (done)
      (org-glean--semantic-queue-process-batch (lambda (n) (setq done n)))
      (should (equal 0 done)))))

(ert-deftest org-glean-test-semantic-queue-start-is-idempotent-and-pausable ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody\n")
      (org-glean-reconcile)
      (should (timerp org-glean--semantic-queue-timer))
      (let ((first-timer org-glean--semantic-queue-timer))
        (org-glean-semantic-queue-start)
        (should (eq first-timer org-glean--semantic-queue-timer)))
      (org-glean-semantic-pause)
      (should (eq 'paused org-glean--semantic-queue-state))
      (should-not (timerp org-glean--semantic-queue-timer))
      (org-glean-semantic-queue-start)
      (should-not (timerp org-glean--semantic-queue-timer))
      (org-glean-semantic-resume)
      (should (timerp org-glean--semantic-queue-timer)))))

(ert-deftest org-glean-test-status-reports-semantic-queue-state ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody\n")
      (org-glean-reconcile)
      (should (memq (plist-get (org-glean-status) :semantic-queue-state)
                    '(idle running paused))))))

(ert-deftest org-glean-test-status-semantic-state-reflects-install-and-provider ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody\n")
    (org-glean-reconcile)
    (should (eq 'not-installed (plist-get (org-glean-status) :semantic-state)))
    (let ((org-glean-semantic-provider nil))
      (should (eq 'unavailable (plist-get (org-glean-status) :semantic-state))))
    (org-glean-test--fake-backend
      (should (eq 'ready (plist-get (org-glean-status) :semantic-state))))))

(ert-deftest org-glean-test-semantic-provider-returns-matching-targets ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "weld.org" root)
                             "* Weld inspection procedure\ncheck the seam\n")
      (org-glean-test--write (expand-file-name "sales.org" root)
                             "* Quarterly sales report\ntotally unrelated content\n")
      (org-glean-reconcile)
      (let (done)
        (org-glean--semantic-queue-process-batch (lambda (n) (setq done n)))
        (should (org-glean-test--wait-for (lambda () done))))
      (let ((items (org-glean--semantic-search-provider "weld inspection" nil 5)))
        (should items)
        (should (cl-some (lambda (item) (equal "Weld inspection procedure"
                                               (alist-get :title item)))
                         items))
        (should (cl-every (lambda (item) (alist-get :score item)) items))
        (should (cl-every (lambda (item) (memq (alist-get :source-current item) '(t nil)))
                          items))))))

(ert-deftest org-glean-test-semantic-provider-survives-backend-restart ()
  ;; Regression test: org-glean--semantic-ensure-warm reloads every stored
  ;; vector from SQLite into a fresh backend process. A vector's `vector'
  ;; column must round-trip byte-for-byte through sqlite-select for this to
  ;; work; storing it as decoded raw bytes previously corrupted it (Emacs's
  ;; sqlite reader can silently merge/reinterpret arbitrary binary BLOB
  ;; bytes as if they were UTF-8), which only ever showed up once a fresh
  ;; process actually needed to reload from SQL rather than from the batch
  ;; that had just embedded and loaded it directly. Storing the base64 TEXT
  ;; itself (pure ASCII, immune to that corruption) fixed it; this test
  ;; forces exactly that reload path.
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "weld.org" root)
                             "* Weld inspection procedure\ncheck the seam\n")
      (org-glean-test--write (expand-file-name "sales.org" root)
                             "* Quarterly sales report\ntotally unrelated content\n")
      (org-glean-reconcile)
      (let (done)
        (org-glean--semantic-queue-process-batch (lambda (n) (setq done n)))
        (should (org-glean-test--wait-for (lambda () done))))
      ;; Force a brand new backend process with an empty in-memory cache,
      ;; so the next search can only succeed via the SQL reload path.
      (org-glean-embed-stop)
      (let ((items (org-glean--semantic-search-provider "weld inspection" nil 5)))
        (should items)
        (should (cl-some (lambda (item) (equal "Weld inspection procedure"
                                               (alist-get :title item)))
                         items))))))

(ert-deftest org-glean-test-semantic-provider-errors-when-not-installed ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody\n")
    (org-glean-reconcile)
    (should-error (org-glean--semantic-search-provider "anything" nil 5))))

(ert-deftest org-glean-test-search-api-semantic-mode-succeeds-when-installed ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "weld.org" root)
                             "* Weld inspection procedure\ncheck the seam\n")
      (org-glean-reconcile)
      (let (done)
        (org-glean--semantic-queue-process-batch (lambda (n) (setq done n)))
        (should (org-glean-test--wait-for (lambda () done))))
      (let ((response (org-glean-search-api "weld inspection" 5 nil nil
                                            '(exact lexical semantic))))
        (should (eq t (alist-get 'semantic (alist-get 'requested response))))
        (should (memq 'semantic (alist-get 'used response)))
        (should (= 0 (length (alist-get 'provider-errors response))))))))

(defun org-glean-test--fusion-item (key &rest fields)
  "Build a minimal target item alist with KEY and FIELDS for fusion tests."
  (append (list (cons :key key) (cons :path (format "/tmp/%s.org" key))
               (cons :kind "heading") (cons :title key) (cons :digest "d")
               (cons :position 1))
          fields))

(ert-deftest org-glean-test-fusion-merge-combines-multi-mode-contributions ()
  (cl-letf (((symbol-function 'file-exists-p) (lambda (_) nil)))
    (let* ((a (org-glean-test--fusion-item "a"))
           (b (org-glean-test--fusion-item "b"))
           (merged (org-glean--fusion-merge
                    (list (cons 'exact (list a))
                          (cons 'lexical (list (org-glean-test--fusion-item "a") b)))))
           (found-a (cl-find "a" merged :key (lambda (i) (alist-get :key i)) :test #'equal))
           (found-b (cl-find "b" merged :key (lambda (i) (alist-get :key i)) :test #'equal)))
      (should (= 2 (length merged)))
      (should (= 2 (length (alist-get :modes found-a))))
      (should (cl-some (lambda (m) (eq 'exact (car m))) (alist-get :modes found-a)))
      (should (cl-some (lambda (m) (eq 'lexical (car m))) (alist-get :modes found-a)))
      (should (= 1 (length (alist-get :modes found-b)))))))

(ert-deftest org-glean-test-fusion-merge-sets-source-current-once ()
  ;; Regression test: org-glean--set-freshness adds a *new* alist key, whose
  ;; effect only survives via its return value; a caller that calls it only
  ;; for effect (without capturing the return) silently loses the field.
  (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t))
            ((symbol-function 'org-glean--digest) (lambda (_) "d")))
    (let* ((merged (org-glean--fusion-merge
                    (list (cons 'lexical (list (org-glean-test--fusion-item "a"))))))
           (item (car merged)))
      (should (assq :source-current item))
      (should (eq t (alist-get :source-current item))))))

(ert-deftest org-glean-test-fusion-score-lets-semantic-outrank-weak-lexical ()
  ;; The whole point of rank fusion: a rank-0 semantic hit must be able to
  ;; outscore a merely-mediocre-ranked lexical hit, not be fixed below every
  ;; lexical result by mode alone.
  (cl-letf (((symbol-function 'file-exists-p) (lambda (_) nil)))
    (let* ((weak-lexical (org-glean-test--fusion-item "weak"))
           (strong-semantic (org-glean-test--fusion-item "strong"))
           (lexical-list (append (cl-loop for n below 40
                                          collect (org-glean-test--fusion-item (format "filler%d" n)))
                                 (list weak-lexical)))
           (merged (mapcar #'org-glean--fusion-finalize
                          (org-glean--fusion-merge
                           (list (cons 'lexical lexical-list)
                                 (cons 'semantic (list strong-semantic))))))
           (weak-item (cl-find "weak" merged :key (lambda (i) (alist-get :key i)) :test #'equal))
           (strong-item (cl-find "strong" merged :key (lambda (i) (alist-get :key i)) :test #'equal)))
      (should (> (alist-get :score strong-item) (alist-get :score weak-item))))))

(ert-deftest org-glean-test-search-filtered-pool-lets-semantic-compete-with-lexical-crowd ()
  ;; Integration-level version of the fusion-score test: even with dozens of
  ;; lexical matches for a query, a semantic candidate must still be able to
  ;; reach the top of the final, limit-truncated result list.
  (org-glean-test--corpus
    (let* ((lexical-items (cl-loop for n below 60
                                  collect (org-glean-test--fusion-item (format "lex%d" n))))
           (semantic-items (list (org-glean-test--fusion-item "sem0")))
           (org-glean-semantic-provider (lambda (&rest _) semantic-items)))
      (cl-letf (((symbol-function 'org-glean--collect-provider)
                 (lambda (_db sql &rest _)
                   (if (string-match-p "target_fts MATCH" sql)
                       (list lexical-items (length lexical-items) nil nil)
                     (list nil 0 nil nil))))
                ((symbol-function 'file-exists-p) (lambda (_) nil)))
        (let* ((search (org-glean-search-filtered "anything" 5 nil nil '(lexical semantic)))
               (results (nth 0 search)))
          (should (equal "sem0" (alist-get :key (car results)))))))))

(ert-deftest org-glean-test-search-filtered-semantic-failure-preserves-other-modes ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root) "* Findable heading\nneedletext\n")
    (org-glean-reconcile)
    (let ((org-glean-semantic-provider (lambda (&rest _) (error "boom"))))
      (let* ((response (org-glean-search-api "needletext" 5 nil nil '(exact lexical semantic)))
             (results (alist-get 'results response)))
        (should (= 1 (length results)))
        (should (equal '(exact lexical) (alist-get 'used response)))
        (should (eq 'semantic (alist-get 'provider (aref (alist-get 'provider-errors response) 0))))))))

(provide 'org-glean-test)
;;; org-glean-test.el ends here
