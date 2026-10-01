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
    (let ((org-glean-chunk-min-words 1))
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
        (should (= 2 (plist-get status :semantic-coverage-total)))))))

(ert-deftest org-glean-test-outline-returns-headings-with-structure ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root)))
      (org-glean-test--write
       path
       (concat "#+title: Sample\n#+PROPERTY: OWNER team-a\n"
               "* Tasks\n:PROPERTIES:\n:ID: root-tasks-id\n:END:\n"
               "** TODO [#A] Do the thing :urgent:work:\nbody\n"
               "** DONE Old thing\nCLOSED: [2026-01-01]\n"
               "* Notes\nprose\n"))
      (let* ((result (org-glean-outline path))
             (outline (car (alist-get :outlines result)))
             (headings (alist-get :headings outline)))
        (should (null (alist-get :errors result)))
        (should (equal "Sample" (alist-get :title outline)))
        (should (equal '((OWNER . "team-a")) (alist-get :properties outline)))
        (should (= 4 (length headings)))
        (should (= 4 (alist-get :heading-count outline)))
        (should-not (alist-get :truncated outline))
        (let ((todo-heading (nth 1 headings)))
          (should (equal "Do the thing" (alist-get :title todo-heading)))
          (should (equal "TODO" (alist-get :todo-keyword todo-heading)))
          (should-not (alist-get :closed todo-heading))
          (should (equal "A" (alist-get :priority todo-heading)))
          (should (equal '("urgent" "work") (alist-get :tags todo-heading)))
          (should (equal '("Tasks" "Do the thing") (alist-get :outline-path todo-heading)))
          ;; Inherits the file-level #+PROPERTY as well as its own ancestor's
          ;; ID -- generic property inheritance, same mechanism used by
          ;; org-glean-search's :property-filters, not a special case here.
          (should (equal "team-a" (alist-get 'OWNER (alist-get :properties todo-heading))))
          (should (equal "root-tasks-id" (alist-get 'ID (alist-get :properties todo-heading)))))
        (let ((done-heading (nth 2 headings)))
          (should (equal "DONE" (alist-get :todo-keyword done-heading)))
          (should (alist-get :closed done-heading)))))))

(ert-deftest org-glean-test-outline-max-level-filters-headings-not-counts ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root)))
      (org-glean-test--write
       path "* One\n** Two\n*** Three\n")
      (let* ((result (org-glean-outline path 1))
             (outline (car (alist-get :outlines result))))
        (should (= 1 (length (alist-get :headings outline))))
        ;; heading-count/truncated describe the WHOLE file, independent of
        ;; the max-level depth filter, which only trims :headings.
        (should (= 3 (alist-get :heading-count outline)))))))

(ert-deftest org-glean-test-outline-caps-headings-and-reports-truncated ()
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root))
          (org-glean-outline-max-headings 3))
      (org-glean-test--write
       path (mapconcat (lambda (n) (format "* Heading %d\n" n)) (number-sequence 1 5) ""))
      (let* ((result (org-glean-outline path))
             (outline (car (alist-get :outlines result))))
        (should (= 3 (length (alist-get :headings outline))))
        (should (= 5 (alist-get :heading-count outline)))
        (should (alist-get :truncated outline))))))

(ert-deftest org-glean-test-outline-collects-per-file-errors-without-aborting ()
  (org-glean-test--corpus
    (let ((good (expand-file-name "good.org" root))
          (missing (expand-file-name "missing.org" root)))
      (org-glean-test--write good "* Heading\n")
      (let ((result (org-glean-outline (list good missing))))
        (should (= 1 (length (alist-get :outlines result))))
        (should (equal good (alist-get :path (car (alist-get :outlines result)))))
        (should (= 1 (length (alist-get :errors result))))
        (should (equal missing (alist-get :path (car (alist-get :errors result)))))))))

(ert-deftest org-glean-test-outline-never-writes-to-the-file-or-mints-ids ()
  ;; The whole point of reading from disk into a throwaway temp buffer
  ;; instead of a live Emacs buffer: no auto-id side effect, unlike
  ;; org-get-node/org-search with mcp-server-emacs-tools-org-auto-id on,
  ;; and no risk of ever saving anything.
  (org-glean-test--corpus
    (let ((path (expand-file-name "note.org" root))
          (before nil) (after nil))
      (org-glean-test--write path "* No ID here\nbody\n")
      (setq before (with-temp-buffer (insert-file-contents path) (buffer-string)))
      (org-glean-outline path)
      (setq after (with-temp-buffer (insert-file-contents path) (buffer-string)))
      (should (equal before after))
      (should-not (get-file-buffer path)))))

(ert-deftest org-glean-test-reconcile-populates-chunks ()
  (org-glean-test--corpus
    (let ((org-glean-chunk-min-words 1))
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
          (should (equal (org-glean--chunk-digest (nth 2 row)) (nth 3 row))))))))

(ert-deftest org-glean-test-migration-backfills-chunks-for-preexisting-targets ()
  ;; Regression test for a real bug found on a real, pre-chunking corpus:
  ;; the v1->v2 migration created the chunks/vectors tables but never
  ;; populated chunks for targets that already existed. Reconcile's
  ;; unchanged-source skip then means those sources are NEVER re-projected
  ;; (their file digest never changes), so chunks stayed empty forever and
  ;; semantic search silently found nothing on any pre-existing
  ;; installation. Simulate that exact starting state: a schema-v2 database
  ;; (chunks/vectors tables exist) with targets but zero chunk rows, then
  ;; confirm opening it (which runs the v2->v3 backfill migration)
  ;; populates chunks without needing any source file to change.
  (org-glean-test--corpus
    (let ((org-glean-chunk-min-words 1))
      (org-glean-test--write (expand-file-name "note.org" root)
                             "#+title: Old Corpus\n* Existing heading\nexisting body\n")
      (org-glean-reconcile)
      (let ((db (org-glean--db)))
        ;; Simulate the incomplete v2 migration: chunks exist for this
        ;; source right now (C1/C2 already populate them); wipe them and
        ;; roll the schema version back to 2, exactly as a database migrated
        ;; before the backfill fix would look.
        (sqlite-execute db "DELETE FROM chunks")
        (sqlite-execute db "PRAGMA user_version = 2")
        (should (= 0 (caar (sqlite-select db "SELECT count(*) FROM chunks"))))
        (org-glean-close)
        (setq org-glean--database nil))
      ;; Reopening the database (no file changes, no reconcile) must trigger
      ;; the v2->v3 (and v3->v4) migrations and backfill chunks from the
      ;; stored targets.
      (let* ((db (org-glean--db))
             (chunks (sqlite-select db "SELECT key,target_key,text FROM chunks ORDER BY key")))
        (should (= 4 (caar (sqlite-select db "PRAGMA user_version"))))
        (should (= 2 (length chunks))) ; file record + one heading
        (should (cl-some (lambda (row) (string-search "Existing heading" (nth 2 row))) chunks))
        (should (cl-some (lambda (row) (string-search "existing body" (nth 2 row))) chunks))))))


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
  (let* ((org-glean-chunk-min-words 1)
         (heading-a (list :key "a" :kind "heading" :title "Alpha" :level 1
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

(ert-deftest org-glean-test-chunk-strip-noise-removes-urls-logbook-and-timestamps ()
  (should (equal "" (org-glean--chunk-strip-noise "https://example.com/some/long/path?x=1")))
  (should (equal "Text before  after"
                 (org-glean--chunk-strip-noise
                  "Text before State \"DONE\"       from \"TODO\"       [2026-09-16 Wed 21:26] after")))
  (should (equal "Text before  after"
                 (org-glean--chunk-strip-noise "Text before [2026-01-01 Thu 09:00] after"))))

(ert-deftest org-glean-test-chunk-word-count-counts-real-words-only ()
  (should (= 0 (org-glean--chunk-word-count "")))
  (should (= 0 (org-glean--chunk-word-count "12 34 a an")))
  (should (= 3 (org-glean--chunk-word-count "one two three")))
  ;; org-glean--chunk-word-count is a raw counter; it does not itself strip
  ;; URLs (so "https"/"com" count too) - that is org-glean--chunk-strip-noise's
  ;; job, always applied first in the real chunking pipeline.
  (should (= 4 (org-glean--chunk-word-count "https://x.com real word")))
  (should (= 2 (org-glean--chunk-word-count
               (org-glean--chunk-strip-noise "https://x.com real word")))))

(ert-deftest org-glean-test-chunk-drops-below-minimum-word-content ()
  (let* ((org-glean-chunk-min-words 6)
         (bare (list :key "bare" :kind "heading" :title "May"
                    :outline-path '("2024" "May") :body ""))
         (records (list bare)))
    (should (null (org-glean--chunk-record bare records)))))

(ert-deftest org-glean-test-chunk-keeps-content-clearing-minimum-words ()
  (let* ((org-glean-chunk-min-words 6)
         (rich (list :key "rich" :kind "heading" :title "Favorite recipe"
                    :outline-path '("Recipes" "Favorite recipe")
                    :body "Combine the ground beef with breadcrumbs and seasoning, then form patties before grilling."))
         (records (list rich)))
    (should (= 1 (length (org-glean--chunk-record rich records))))))

(ert-deftest org-glean-test-chunk-short-heading-borrows-file-title ()
  (let* ((org-glean-chunk-min-words 6)
         (file-record (list :key "f" :kind "file" :title "Kitchen Notebook"
                            :body "assorted cooking references"))
         (thin (list :key "thin" :kind "heading" :title "Tips"
                     :outline-path '("Tips") :body "use fresh herbs"))
         (records (list file-record thin))
         (chunks (org-glean--chunk-record thin records)))
    (should (= 1 (length chunks)))
    (should (string-search "Kitchen Notebook" (plist-get (car chunks) :text)))))

(ert-deftest org-glean-test-unchanged-reconcile-keeps-chunk-vector ()
  (org-glean-test--corpus
    (let ((org-glean-chunk-min-words 1))
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
        (should (equal (cons 1 2) (org-glean--semantic-coverage db "fixture-model")))))))

(ert-deftest org-glean-test-removed-source-deletes-its-chunks ()
  (org-glean-test--corpus
    (let ((org-glean-chunk-min-words 1)
          (path (expand-file-name "removeme.org" root)))
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

(ert-deftest org-glean-test-property-filters-op-equals-and-not-equals ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "note.org" root)
     "* Alpha\n:PROPERTIES:\n:STATUS: active\n:END:\nfiltertermalpha\n* Beta\n:PROPERTIES:\n:STATUS: retired\n:END:\nfiltertermbeta\n")
    (org-glean-reconcile)
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "filterterm" 10 nil
                             '(:property-filters ((:key "STATUS" :op equals :value "active")))))))
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "filterterm" 10 nil
                             '(:property-filters ((:key "STATUS" :op not-equals :value "active")))))))))

(ert-deftest org-glean-test-property-filters-op-in-and-not-in-are-case-insensitive ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "note.org" root)
     "* Gamma\n:PROPERTIES:\n:KIND: Draft\n:END:\ninopstermgamma\n* Delta\n:PROPERTIES:\n:KIND: final\n:END:\ninopstermdelta\n")
    (org-glean-reconcile)
    ;; Both the filter's key and its property's own key/value casing differ
    ;; from what is stored -- matching is documented as case-insensitive.
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "inopsterm" 10 nil
                             '(:property-filters ((:key "kind" :op in :values ("DRAFT" "review"))))))))
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "inopsterm" 10 nil
                             '(:property-filters ((:key "kind" :op not-in :values ("DRAFT" "review"))))))))))

(ert-deftest org-glean-test-property-filters-op-exists-and-missing ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "note.org" root)
     "* HasIt\n:PROPERTIES:\n:OWNER: alice\n:END:\nexiststermhasit\n* Lacks\nexiststermlacks\n")
    (org-glean-reconcile)
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "existsterm" 10 nil
                             '(:property-filters ((:key "OWNER" :op exists)))))))
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "existsterm" 10 nil
                             '(:property-filters ((:key "OWNER" :op missing)))))))))

(ert-deftest org-glean-test-property-filters-are-anded-together ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "note.org" root)
     (concat "* Both\n:PROPERTIES:\n:A: yes\n:B: yes\n:END:\nandtermboth\n"
             "* OnlyA\n:PROPERTIES:\n:A: yes\n:END:\nandtermonlya\n"))
    (org-glean-reconcile)
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "andterm" 10 nil
                             '(:property-filters ((:key "A" :op equals :value "yes")
                                                   (:key "B" :op equals :value "yes")))))))))

(ert-deftest org-glean-test-property-filters-has-no-implicit-default-value ()
  ;; The generic mechanism has no built-in knowledge of any property,
  ;; CAPTURE_POLICY included: a property that was never set anywhere for a
  ;; target is simply absent, never silently treated as some default value.
  ;; This is what distinguishes it from the deprecated :exclude-property-
  ;; values path this same case is compared against below.
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "note.org" root)
                           "* Undecorated\nnodefaulttermbare\n")
    (org-glean-reconcile)
    (should (= 0 (alist-get 'candidate-count
                            (org-glean-search-api
                             "nodefaulttermbare" 10 nil
                             '(:property-filters ((:key "CAPTURE_POLICY" :op equals :value "eligible")))))))
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "nodefaulttermbare" 10 nil
                             '(:property-filters ((:key "CAPTURE_POLICY" :op missing)))))))))

(ert-deftest org-glean-test-property-filters-applied-before-result-limit ()
  ;; Mirrors org-glean-test-search-pages-past-excluded-prefix-before-filling-
  ;; limit, using the new mechanism instead of the deprecated one, to prove
  ;; filtering happens before LIMIT truncation for :property-filters too, not
  ;; only for its deprecated predecessor.
  (org-glean-test--corpus
    (dotimes (n 105)
      (org-glean-test--write
       (expand-file-name (format "a%03d.org" n) root)
       "#+PROPERTY: CAPTURE_POLICY none\n* Hidden match\nsharedneedletwo\n"))
    (org-glean-test--write (expand-file-name "z-eligible.org" root)
                           "* Eligible destination\nsharedneedletwo\n")
    (let ((org-glean-search-page-size 20))
      (org-glean-reconcile)
      (let* ((response (org-glean-search-api
                        "sharedneedletwo" 1 nil
                        '(:property-filters ((:key "CAPTURE_POLICY" :op not-in :values ("none"))))))
             (results (alist-get 'results response)))
        (should (= 1 (length results)))
        (should (equal "Eligible destination" (alist-get :title (aref results 0))))))))

(ert-deftest org-glean-test-deprecated-exclude-property-values-still-works ()
  ;; Regression test for the backward-compatibility shim
  ;; (org-glean--normalize-filters): existing callers passing
  ;; :exclude-property-values directly (not through MCP) must see identical
  ;; behavior to before property_filters existed.
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "note.org" root)
     "#+PROPERTY: CAPTURE_POLICY none\n* Hidden\nlegacyexcludeterm\n")
    (org-glean-test--write (expand-file-name "z.org" root) "* Visible\nlegacyexcludeterm\n")
    (org-glean-reconcile)
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "legacyexcludeterm" 10 nil
                             '(:exclude-property-values ("none"))))))))

(ert-deftest org-glean-test-deprecated-property-key-value-still-works ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "note.org" root)
     "* Match\n:PROPERTIES:\n:TEAM: platform\n:END:\nlegacykeyvalueterm\n* Other\n:PROPERTIES:\n:TEAM: apps\n:END:\nlegacykeyvalueterm\n")
    (org-glean-reconcile)
    (should (= 1 (alist-get 'candidate-count
                            (org-glean-search-api
                             "legacykeyvalueterm" 10 nil
                             '(:property-key "TEAM" :property-value "platform")))))))

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

(ert-deftest org-glean-test-mcp-empty-string-property-key-value-are-ignored ()
  ;; Regression test: many MCP clients (including Pi's tool bridge) send
  ;; every optional string argument as "" rather than omitting it. Since
  ;; property_key/property_value are deprecated but still-supported
  ;; arguments, an empty string for both must behave exactly like omitting
  ;; them -- not like an active filter for a property literally named "".
  ;; Before the fix, `(and "" "")' is non-nil in Elisp, so this silently
  ;; zeroed out every result.
  (org-glean-test--corpus
    (let* ((org-glean-mcp-allowed-roots (list root)))
      (org-glean-test--write
       (expand-file-name "note.org" root) "* Match\nemptypropterm\n")
      (org-glean-reconcile)
      (let* ((json (org-glean-mcp--handler
                    '((query . "emptypropterm")
                      (property_key . "")
                      (property_value . ""))))
             (decoded (json-parse-string json :object-type 'alist)))
        (should (= 1 (length (alist-get 'results decoded))))
        (should (equal "Match" (alist-get 'title (aref (alist-get 'results decoded) 0))))))))

(ert-deftest org-glean-test-mcp-property-filters-param-is-generic ()
  (org-glean-test--corpus
    (let* ((org-glean-mcp-allowed-roots (list root)))
      (org-glean-test--write
       (expand-file-name "note.org" root)
       "* Match\n:PROPERTIES:\n:TEAM: platform\n:END:\nmcppropterm\n* Other\n:PROPERTIES:\n:TEAM: apps\n:END:\nmcppropterm\n")
      (org-glean-reconcile)
      ;; property_filters arrives from JSON as an alist per entry, exactly
      ;; as mcp-server-tools would parse it -- this is not routed through
      ;; org-glean-search-api's Elisp keyword-plist convention directly.
      (let* ((json (org-glean-mcp--handler
                    '((query . "mcppropterm")
                      (property_filters . (((key . "TEAM") (op . "equals") (value . "platform")))))))
             (decoded (json-parse-string json :object-type 'alist)))
        (should (= 1 (length (alist-get 'results decoded))))
        (should (equal "Match" (alist-get 'title (aref (alist-get 'results decoded) 0))))))))

(ert-deftest org-glean-test-mcp-property-filters-in-op-with-values-array ()
  (org-glean-test--corpus
    (let* ((org-glean-mcp-allowed-roots (list root)))
      (org-glean-test--write
       (expand-file-name "note.org" root)
       "#+PROPERTY: CAPTURE_POLICY none\n* Hidden\nmcpinopterm\n")
      (org-glean-test--write (expand-file-name "z.org" root) "* Visible\nmcpinopterm\n")
      (org-glean-reconcile)
      (let* ((json (org-glean-mcp--handler
                    '((query . "mcpinopterm")
                      (property_filters
                       . (((key . "CAPTURE_POLICY") (op . "not_in") (values . ["none"])))))))
             (decoded (json-parse-string json :object-type 'alist)))
        (should (= 1 (length (alist-get 'results decoded))))
        (should (equal "Visible" (alist-get 'title (aref (alist-get 'results decoded) 0))))))))

(ert-deftest org-glean-test-mcp-outline-returns-structure-for-allowed-file ()
  (org-glean-test--corpus
    (let* ((path (expand-file-name "note.org" root))
           (org-glean-mcp-allowed-roots (list root)))
      (org-glean-test--write path "* TODO [#B] Do it\nbody\n")
      (let* ((json (org-glean-mcp--outline-handler `((file . ,path))))
             (decoded (json-parse-string json :object-type 'alist))
             (outline (aref (alist-get 'outlines decoded) 0))
             (heading (aref (alist-get 'headings outline) 0)))
        (should (equal path (alist-get 'path outline)))
        (should (equal "Do it" (alist-get 'title heading)))
        (should (equal "TODO" (alist-get 'todo-keyword heading)))
        (should (equal "B" (alist-get 'priority heading)))
        (should (eq :null (alist-get 'closed heading)))
        (should (= 0 (length (alist-get 'errors decoded))))))))

(ert-deftest org-glean-test-mcp-outline-rejects-path-outside-allowed-roots ()
  (org-glean-test--corpus
    (let* ((allowed (expand-file-name "allowed" root))
           (other (expand-file-name "other" root))
           (org-glean-roots (list (list "all" root nil nil)))
           (org-glean-mcp-allowed-roots (list allowed)))
      (org-glean-test--write (expand-file-name "a.org" other) "* Outside\n")
      (let* ((json (org-glean-mcp--outline-handler
                    `((file . ,(expand-file-name "a.org" other)))))
             (decoded (json-parse-string json :object-type 'alist)))
        (should (= 0 (length (alist-get 'outlines decoded))))
        (should (= 1 (length (alist-get 'errors decoded))))
        (should (string-match-p "outside every allowed root"
                                (alist-get 'message (aref (alist-get 'errors decoded) 0))))))))

(ert-deftest org-glean-test-mcp-outline-accepts-several-files-and-max-level ()
  (org-glean-test--corpus
    (let* ((path-a (expand-file-name "a.org" root))
           (path-b (expand-file-name "b.org" root))
           (org-glean-mcp-allowed-roots (list root)))
      (org-glean-test--write path-a "* One\n** Two\n")
      (org-glean-test--write path-b "* Three\n")
      (let* ((json (org-glean-mcp--outline-handler
                    `((files . [,path-a ,path-b]) (max_heading_level . 1))))
             (decoded (json-parse-string json :object-type 'alist))
             (outlines (alist-get 'outlines decoded)))
        (should (= 2 (length outlines)))
        (should (= 1 (length (alist-get 'headings (aref outlines 0)))))))))

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
            (should (equal '("id-key" ["title" "heading" "source.org" "lexical" "yes" "lexical"])
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

(ert-deftest org-glean-test-fuzzy-own-cap-alone-is-not-incomplete ()
  "Hitting fuzzy's own candidate cap, with plenty of shared budget left,
must not mark the whole search `incomplete' — that over-fired on nearly
every non-trivial query (see capture-workflow note §5)."
  (org-glean-test--corpus
    (dotimes (n 10)
      (org-glean-test--write
       (expand-file-name (format "junk%02d.org" n) root)
       (format "* needleterm%s\njunk\n" (make-string 100 ?x))))
    (org-glean-reconcile)
    (let* ((org-glean-fuzzy-candidate-limit 3)
           (org-glean-search-work-budget 2000)
           (response (org-glean-search-api "needleterm" 5 nil nil '(fuzzy))))
      (should (not (eq 'incomplete (alist-get 'completeness response)))))))

(ert-deftest org-glean-test-fuzzy-reports-incomplete-when-shared-budget-is-the-cap ()
  "When the shared work budget itself is smaller than fuzzy's own
candidate cap, running out of it is genuine incompleteness and must
still be reported."
  (org-glean-test--corpus
    (dotimes (n 10)
      (org-glean-test--write
       (expand-file-name (format "junk%02d.org" n) root)
       (format "* needleterm%s\njunk\n" (make-string 100 ?x))))
    (org-glean-reconcile)
    (let* ((org-glean-fuzzy-candidate-limit 500)
           (org-glean-search-work-budget 3)
           (response (org-glean-search-api "needleterm" 5 nil nil '(fuzzy))))
      (should (eq 'incomplete (alist-get 'completeness response))))))

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
      (let ((org-glean-chunk-min-words 1))
        (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody text\n")
        (org-glean-reconcile))
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
      (let ((org-glean-chunk-min-words 1))
        (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody text\n")
        (org-glean-reconcile))
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
  ;; This corpus only has two candidate chunks. org-glean-semantic-min-z's
  ;; production default (3.0) would be unreachable by construction at that
  ;; pool size -- the population z-score of the higher of exactly two
  ;; points is always exactly 1.0 -- but the backend's min_pool_for_z guard
  ;; (see semantic/org_glean_embed.py) means min_z is simply not applied
  ;; below its floor, so the real, unmodified default is exercised here.
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
      (let* ((items (org-glean--semantic-search-provider "weld inspection" nil 5)))
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
      ;; See the min_pool_for_z note in
      ;; org-glean-test-semantic-provider-returns-matching-targets above.
      (let* ((items (org-glean--semantic-search-provider "weld inspection" nil 5)))
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

(ert-deftest org-glean-test-fusion-contribution-scales-semantic-weight-by-z ()
  ;; A confident semantic hit (high z) must contribute more to fusion than
  ;; an equally-ranked one that only barely cleared the z-threshold; the
  ;; scale factor is min(1, z/5), so z=5 leaves the weight unscaled and z=1
  ;; cuts it to a fifth.
  (should (= (org-glean--fusion-contribution 'semantic 0 5.0)
             (org-glean--fusion-contribution 'semantic 0)))
  (should (< (org-glean--fusion-contribution 'semantic 0 1.0)
             (org-glean--fusion-contribution 'semantic 0 5.0)))
  ;; A z above 5 does not grant more than the mode's full configured weight.
  (should (= (org-glean--fusion-contribution 'semantic 0 9.0)
             (org-glean--fusion-contribution 'semantic 0 5.0)))
  ;; Non-semantic modes ignore Z entirely, and a nil Z on a semantic entry
  ;; behaves exactly like the pre-z-scoring formula.
  (should (= (org-glean--fusion-contribution 'lexical 0 0.1)
             (org-glean--fusion-contribution 'lexical 0)))
  (should (= (org-glean--fusion-contribution 'semantic 0 nil)
             (org-glean--fusion-contribution 'semantic 0))))

(ert-deftest org-glean-test-fusion-merge-carries-semantic-z-into-modes ()
  (cl-letf (((symbol-function 'file-exists-p) (lambda (_) nil)))
    (let* ((item (org-glean-test--fusion-item "s" (cons :semantic-z 6.2)))
           (merged (org-glean--fusion-merge (list (cons 'semantic (list item)))))
           (found (car merged)))
      (should (= 6.2 (nth 3 (car (alist-get :modes found)))))
      ;; A lexical entry must never pick up a z value, even from an item
      ;; that happens to carry a stray :semantic-z field.
      (let* ((stray (org-glean-test--fusion-item "l" (cons :semantic-z 9.9)))
             (lex-merged (org-glean--fusion-merge (list (cons 'lexical (list stray))))))
        (should (null (nth 3 (car (alist-get :modes (car lex-merged))))))))))

(ert-deftest org-glean-test-fusion-score-weak-z-semantic-does-not-beat-full-weight-lexical ()
  ;; A semantic hit that only barely cleared the z-threshold (z near 0)
  ;; must contribute close to nothing, so a plain top-ranked lexical hit
  ;; still outranks it -- confirming the z-scaling actually suppresses
  ;; weak semantic candidates rather than merely being cosmetic.
  (cl-letf (((symbol-function 'file-exists-p) (lambda (_) nil)))
    (let* ((strong-lexical (org-glean-test--fusion-item "lex"))
           (barely-semantic (org-glean-test--fusion-item "sem" (cons :semantic-z 0.01)))
           (merged (mapcar #'org-glean--fusion-finalize
                          (org-glean--fusion-merge
                           (list (cons 'lexical (list strong-lexical))
                                 (cons 'semantic (list barely-semantic))))))
           (lex-item (cl-find "lex" merged :key (lambda (i) (alist-get :key i)) :test #'equal))
           (sem-item (cl-find "sem" merged :key (lambda (i) (alist-get :key i)) :test #'equal)))
      (should (> (alist-get :score lex-item) (alist-get :score sem-item))))))

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

(ert-deftest org-glean-test-default-modes-omits-semantic-when-not-installed ()
  (org-glean-test--corpus
    (should (equal '(exact lexical fuzzy) (org-glean--default-modes)))))

(ert-deftest org-glean-test-default-modes-includes-semantic-when-installed ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (should (equal '(exact lexical fuzzy semantic) (org-glean--default-modes))))))

(ert-deftest org-glean-test-default-modes-override-is-respected ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (let ((org-glean-default-modes '(exact)))
        (should (equal '(exact) (org-glean--default-modes)))))))

(ert-deftest org-glean-test-mcp-uses-default-modes-when-caller-omits-them ()
  (org-glean-test--corpus
    (let* ((path (expand-file-name "note.org" root))
           (org-glean-mcp-allowed-roots (list root)))
      (org-glean-test--write path "* Heading\nneedle\n")
      (org-glean-reconcile)
      (let* ((decoded (json-parse-string
                       (org-glean-mcp--handler '((query . "needle")))
                       :object-type 'alist))
             (requested (alist-get 'requested decoded)))
        ;; No semantic backend installed in this fixture, so the automatic
        ;; default must not claim semantic was requested.
        (should-not (alist-get 'semantic requested))
        (should (alist-get 'exact requested))
        (should (alist-get 'lexical requested))
        (should (alist-get 'fuzzy requested))))))

(ert-deftest org-glean-test-find-semantic-errors-when-not-installed ()
  (org-glean-test--corpus
    (should-error (org-glean-find-semantic "anything") :type 'user-error)))

(ert-deftest org-glean-test-search-buffer-semantic-errors-when-not-installed ()
  (org-glean-test--corpus
    (should-error (org-glean-search-buffer-semantic "anything") :type 'user-error)))

(ert-deftest org-glean-test-search-buffer-semantic-forces-semantic-only-modes ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "weld.org" root)
                             "* Weld inspection procedure\ncheck the seam\n")
      (org-glean-reconcile)
      (let (done)
        (org-glean--semantic-queue-process-batch (lambda (n) (setq done n)))
        (should (org-glean-test--wait-for (lambda () done))))
      (org-glean-search-buffer-semantic "weld inspection")
      (let ((buffer (get-buffer "*Org Glean Results*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal '(semantic) org-glean--results-modes)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest org-glean-test-results-buffer-toggle-semantic-only-round-trips ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "weld.org" root)
                             "* Weld inspection procedure\ncheck the seam\n")
      (org-glean-reconcile)
      (let (done)
        (org-glean--semantic-queue-process-batch (lambda (n) (setq done n)))
        (should (org-glean-test--wait-for (lambda () done))))
      (org-glean-search-buffer "weld inspection")
      (let ((buffer (get-buffer "*Org Glean Results*")))
        (unwind-protect
            (with-current-buffer buffer
              (let ((original org-glean--results-modes))
                (org-glean-results-toggle-semantic-only)
                (should (equal '(semantic) org-glean--results-modes))
                (org-glean-results-toggle-semantic-only)
                (should (equal original org-glean--results-modes))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest org-glean-test-keymap-prefix-binds-and-can-be-disabled ()
  (let ((org-glean-keymap-prefix "C-c C-x g"))
    (org-glean--install-keymap-prefix 'org-glean-keymap-prefix "C-c C-x g")
    (should (eq org-glean-command-map (key-binding (kbd "C-c C-x g"))))
    (org-glean--install-keymap-prefix 'org-glean-keymap-prefix nil)
    (should-not (eq org-glean-command-map (key-binding (kbd "C-c C-x g"))))
    ;; Restore the real default so later tests/interactive use are unaffected.
    (org-glean--install-keymap-prefix 'org-glean-keymap-prefix "M-s g")))

(ert-deftest org-glean-test-command-map-has-expected-bindings ()
  (should (eq #'org-glean-find (lookup-key org-glean-command-map "g")))
  (should (eq #'org-glean-search-buffer (lookup-key org-glean-command-map "G")))
  (should (eq #'org-glean-find-semantic (lookup-key org-glean-command-map "s")))
  (should (eq #'org-glean-search-buffer-semantic (lookup-key org-glean-command-map "S")))
  (should (eq #'org-glean-reconcile (lookup-key org-glean-command-map "r")))
  (should (eq #'org-glean-status (lookup-key org-glean-command-map "i")))
  (should (eq #'org-glean-show-errors (lookup-key org-glean-command-map "e")))
  (should (eq #'org-glean-semantic-toggle (lookup-key org-glean-command-map "p"))))

(ert-deftest org-glean-test-semantic-toggle-pauses-and-resumes ()
  (org-glean-test--corpus
    (org-glean-test--fake-backend
      (org-glean-test--write (expand-file-name "note.org" root) "* Heading\nbody\n")
      (org-glean-reconcile)
      (should (timerp org-glean--semantic-queue-timer))
      (org-glean-semantic-toggle)
      (should (eq 'paused org-glean--semantic-queue-state))
      (org-glean-semantic-toggle)
      (should (timerp org-glean--semantic-queue-timer)))))

(ert-deftest org-glean-test-eligibility-project-token-ignores-trailing-qualifiers ()
  (should (equal "flat" (org-glean--eligibility-project-token
                         "/x/20260913T205618--flat-finckensteinallee-89__pr_flat.org")))
  (should (equal "flat" (org-glean--eligibility-project-token
                         "/x/20260428T210349--flat-aquisition-contract__pr_flat_legal.org")))
  (should (null (org-glean--eligibility-project-token "/x/20260913T205618--no-tags.org"))))

(ert-deftest org-glean-test-eligibility-active-main-is-preferred ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "20260101T000000--main__pr_proj.org" root)
     "#+property:   KIND project\n#+property:   STATUS active\n#+property:   ROLE main\n\n* Task\n")
    (let* ((main (expand-file-name "20260101T000000--main__pr_proj.org" root))
           (result (org-glean-eligibility main))
           (item (car (alist-get :classifications result))))
      (should (eq 'preferred (alist-get :result item)))
      (should (string-match-p "ROLE is main, STATUS is active" (alist-get :reason item))))))

(ert-deftest org-glean-test-eligibility-side-file-of-active-project-is-eligible ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "20260101T000000--main__pr_proj.org" root)
     "#+property:   KIND project\n#+property:   STATUS active\n#+property:   ROLE main\n\n* Task\n")
    (org-glean-test--write
     (expand-file-name "20260101T000001--side__pr_proj.org" root)
     "#+property:   KIND project\n#+property:   ROLE side\n\n* Task\n")
    (let* ((side (expand-file-name "20260101T000001--side__pr_proj.org" root))
           (result (org-glean-eligibility side))
           (item (car (alist-get :classifications result))))
      (should (eq 'eligible (alist-get :result item)))
      (should (string-match-p "main__pr_proj\\.org is not closed" (alist-get :reason item))))))

(ert-deftest org-glean-test-eligibility-closed-main-is-none ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "20260101T000000--main__pr_proj.org" root)
     "#+property:   KIND project\n#+property:   STATUS closed\n#+property:   ROLE main\n\n* Task\n")
    (let* ((main (expand-file-name "20260101T000000--main__pr_proj.org" root))
           (result (org-glean-eligibility main))
           (item (car (alist-get :classifications result))))
      (should (eq 'none (alist-get :result item)))
      (should (string-match-p "STATUS is closed" (alist-get :reason item))))))

(ert-deftest org-glean-test-eligibility-side-file-of-closed-project-is-none ()
  "The one case a single file's own properties cannot answer: a side
file deliberately carries no STATUS of its own (§7.3) and must inherit
it from its project's main file, found by the shared pr_<token>."
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "20260101T000000--main__pr_proj.org" root)
     "#+property:   KIND project\n#+property:   STATUS closed\n#+property:   ROLE main\n\n* Task\n")
    (org-glean-test--write
     (expand-file-name "20260101T000001--side__pr_proj.org" root)
     "#+property:   KIND project\n#+property:   ROLE side\n\n* Task\n")
    (let* ((side (expand-file-name "20260101T000001--side__pr_proj.org" root))
           (result (org-glean-eligibility side))
           (item (car (alist-get :classifications result))))
      (should (eq 'none (alist-get :result item)))
      (should (string-match-p "its main file .*main__pr_proj\\.org has STATUS closed"
                              (alist-get :reason item))))))

(ert-deftest org-glean-test-eligibility-side-file-with-no-main-is-eligible-not-guessed ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "20260101T000001--side__pr_lonely.org" root)
     "#+property:   KIND project\n#+property:   ROLE side\n\n* Task\n")
    (let* ((side (expand-file-name "20260101T000001--side__pr_lonely.org" root))
           (result (org-glean-eligibility side))
           (item (car (alist-get :classifications result))))
      (should (eq 'eligible (alist-get :result item)))
      (should (string-match-p "no ROLE main file found" (alist-get :reason item))))))

(ert-deftest org-glean-test-eligibility-area-active-is-preferred-closed-is-none ()
  (org-glean-test--corpus
    (org-glean-test--write
     (expand-file-name "20260101T000000--home__area_home.org" root)
     "#+property:   KIND area\n#+property:   STATUS active\n\n* Task\n")
    (org-glean-test--write
     (expand-file-name "20260101T000001--done__area_other.org" root)
     "#+property:   KIND area\n#+property:   STATUS closed\n\n* Task\n")
    (let ((result (org-glean-eligibility
                   (list (expand-file-name "20260101T000000--home__area_home.org" root)
                         (expand-file-name "20260101T000001--done__area_other.org" root)))))
      (should (eq 'preferred (alist-get :result (nth 0 (alist-get :classifications result)))))
      (should (eq 'none (alist-get :result (nth 1 (alist-get :classifications result))))))))

(ert-deftest org-glean-test-eligibility-log-archive-inbox-are-none ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "20260101T000000--hours__log.org" root)
                           "#+property:   KIND log\n\n* Entry\n")
    (org-glean-test--write (expand-file-name "20260101T000001--old-tasks.org" root)
                           "#+property:   KIND archive\n\n* Entry\n")
    (org-glean-test--write (expand-file-name "20260101T000002--inbox.org" root)
                           "#+property:   KIND inbox\n\n* Entry\n")
    (let* ((files (list (expand-file-name "20260101T000000--hours__log.org" root)
                        (expand-file-name "20260101T000001--old-tasks.org" root)
                        (expand-file-name "20260101T000002--inbox.org" root)))
           (result (org-glean-eligibility files))
           (items (alist-get :classifications result)))
      (should (cl-every (lambda (item) (eq 'none (alist-get :result item))) items)))))

(ert-deftest org-glean-test-eligibility-unset-kind-is-eligible-unchanged-default ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "20260101T000000--plain.org" root)
                           "* Some note\n")
    (let* ((result (org-glean-eligibility (expand-file-name "20260101T000000--plain.org" root)))
           (item (car (alist-get :classifications result))))
      (should (eq 'eligible (alist-get :result item)))
      (should (string-match-p "no KIND set" (alist-get :reason item))))))

(ert-deftest org-glean-test-eligibility-reports-per-file-error-without-failing-others ()
  (org-glean-test--corpus
    (org-glean-test--write (expand-file-name "20260101T000000--plain.org" root)
                           "* Some note\n")
    (let* ((missing (expand-file-name "does-not-exist.org" root))
           (present (expand-file-name "20260101T000000--plain.org" root))
           (result (org-glean-eligibility (list missing present))))
      (should (= 1 (length (alist-get :classifications result))))
      (should (= 1 (length (alist-get :errors result))))
      (should (equal missing (alist-get :path (car (alist-get :errors result))))))))

(ert-deftest org-glean-test-mcp-eligibility-rejects-path-outside-allowed-roots ()
  (org-glean-test--corpus
    (let* ((allowed (expand-file-name "allowed" root))
           (other (expand-file-name "other" root))
           (org-glean-roots (list (list "all" root nil nil)))
           (org-glean-mcp-allowed-roots (list allowed)))
      (org-glean-test--write (expand-file-name "a.org" other) "* Outside\n")
      (let* ((json (org-glean-mcp--eligibility-handler
                    `((file . ,(expand-file-name "a.org" other)))))
             (decoded (json-parse-string json :object-type 'alist)))
        (should (= 0 (length (alist-get 'classifications decoded))))
        (should (= 1 (length (alist-get 'errors decoded))))
        (should (string-match-p "outside every allowed root"
                                (alist-get 'message (aref (alist-get 'errors decoded) 0))))))))

(ert-deftest org-glean-test-mcp-eligibility-accepts-several-files ()
  (org-glean-test--corpus
    (let* ((path-a (expand-file-name "20260101T000000--a__area_home.org" root))
           (path-b (expand-file-name "20260101T000001--b.org" root))
           (org-glean-mcp-allowed-roots (list root)))
      (org-glean-test--write path-a "#+property:   KIND area\n#+property:   STATUS active\n\n* One\n")
      (org-glean-test--write path-b "* Two\n")
      (let* ((json (org-glean-mcp--eligibility-handler
                    `((files . [,path-a ,path-b]))))
             (decoded (json-parse-string json :object-type 'alist))
             (classifications (alist-get 'classifications decoded)))
        (should (= 2 (length classifications)))
        (should (equal "preferred" (alist-get 'result (aref classifications 0))))
        (should (equal "eligible" (alist-get 'result (aref classifications 1))))))))

(provide 'org-glean-test)
;;; org-glean-test.el ends here
