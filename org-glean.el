;;; org-glean.el --- Read-only Org indexing and search -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Version: 0.1.0
;; Keywords: outlines, search

;;; Commentary:
;; The database is disposable.  All corpus files are read, never modified.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-element)
(require 'sqlite)
(require 'subr-x)
(require 'tabulated-list)

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

(defvar org-glean--database nil)
(defvar org-glean--database-path nil)
(defvar org-glean--fts5-supported nil)
(defvar org-glean--save-timer nil)
(defvar org-glean--reconcile-timer nil)
(defvar org-glean--initial-timer nil)
(defvar org-glean--pending-files nil)

(defun org-glean--fts5-available-p ()
  "Return non-nil if this Emacs SQLite library supports FTS5."
  (or (eq org-glean--fts5-supported t)
      (setq org-glean--fts5-supported
            (let* ((path (make-temp-file "org-glean-fts5-" nil ".sqlite"))
                   (db nil)
                   (available nil))
              (unwind-protect
                  (setq db (sqlite-open path)
                        available (progn
                                    (sqlite-execute db "CREATE VIRTUAL TABLE fts_probe USING fts5(value)")
                                    t))
                (when db (sqlite-close db))
                (when (file-exists-p path) (delete-file path)))
              available))))

(defun org-glean--migrate-database (db)
  "Migrate DB from the original lexical schema to current schema.
Rebuild the external-content FTS table only once when upgrading databases
created before migration version 1; healthy opens do not rewrite the index."
  (let ((version (or (caar (sqlite-select db "PRAGMA user_version")) 0)))
    (sqlite-transaction db)
    (condition-case err
        (progn
          (sqlite-execute db "CREATE TABLE IF NOT EXISTS sources (path TEXT PRIMARY KEY, root TEXT NOT NULL, digest TEXT NOT NULL)")
          (sqlite-execute db "CREATE TABLE IF NOT EXISTS targets (key TEXT PRIMARY KEY, path TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, org_id TEXT, position INTEGER NOT NULL, digest TEXT NOT NULL, capture_policy TEXT NOT NULL DEFAULT 'eligible', level INTEGER NOT NULL DEFAULT 0, outline_path TEXT NOT NULL DEFAULT '', properties TEXT NOT NULL DEFAULT 'nil', FOREIGN KEY(path) REFERENCES sources(path))")
          (dolist (migration '("ALTER TABLE targets ADD COLUMN capture_policy TEXT NOT NULL DEFAULT 'eligible'"
                               "ALTER TABLE targets ADD COLUMN level INTEGER NOT NULL DEFAULT 0"
                               "ALTER TABLE targets ADD COLUMN outline_path TEXT NOT NULL DEFAULT ''"
                               "ALTER TABLE targets ADD COLUMN properties TEXT NOT NULL DEFAULT 'nil'"))
            (condition-case nil (sqlite-execute db migration) (error nil)))
          (sqlite-execute db "CREATE INDEX IF NOT EXISTS targets_path ON targets(path)")
          (sqlite-execute db "CREATE INDEX IF NOT EXISTS targets_title ON targets(title)")
          (sqlite-execute db "CREATE VIRTUAL TABLE IF NOT EXISTS target_fts USING fts5(title, body, content='targets', content_rowid='rowid')")
          (sqlite-execute db "CREATE TRIGGER IF NOT EXISTS targets_ai AFTER INSERT ON targets BEGIN INSERT INTO target_fts(rowid,title,body) VALUES (new.rowid,new.title,new.body); END")
          (sqlite-execute db "CREATE TRIGGER IF NOT EXISTS targets_ad AFTER DELETE ON targets BEGIN INSERT INTO target_fts(target_fts,rowid,title,body) VALUES ('delete',old.rowid,old.title,old.body); END")
          (when (< version 1)
            ;; Older databases could have an absent or incomplete external-content
            ;; index. Repair once as part of migration, not on every connection.
            (sqlite-execute db "INSERT INTO target_fts(target_fts) VALUES('rebuild')")
            (sqlite-execute db "PRAGMA user_version = 1"))
          (sqlite-commit db)
          t)
      (error
       (sqlite-rollback db)
       (signal (car err) (cdr err))))))

(defun org-glean--digest (path)
  "Hash the literal saved bytes in PATH."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun org-glean--db ()
  "Return the open database, checking required capabilities first."
  (unless (org-glean--fts5-available-p)
    (error "org-glean requires Emacs SQLite with FTS5 support"))
  (when (and org-glean--database
             (not (equal org-glean--database-path
                         (expand-file-name org-glean-database-file))))
    (org-glean-close))
  (unless org-glean--database
    (make-directory (file-name-directory (expand-file-name org-glean-database-file)) t)
    (let ((db (sqlite-open org-glean-database-file)))
      (condition-case err
          (progn
            (org-glean--migrate-database db)
            (setq org-glean--database db
                  org-glean--database-path (expand-file-name org-glean-database-file)))
        (error (sqlite-close db)
               (error "org-glean requires SQLite FTS5: %s" (error-message-string err))))))
  org-glean--database)

(defun org-glean-close ()
  "Close the current index connection."
  (interactive)
  (when org-glean--database
    (sqlite-close org-glean--database)
    (setq org-glean--database nil org-glean--database-path nil)))

(defun org-glean--sources ()
  "Return discovered (PATH . ROOT-NAME) pairs under configured roots."
  (unless org-glean-roots
    (user-error "Configure org-glean-roots before reconciling"))
  (dolist (spec org-glean-roots)
    (unless (and (listp spec) (= (length spec) 4)
                 (stringp (nth 0 spec)) (stringp (nth 1 spec))
                 (listp (nth 2 spec)) (listp (nth 3 spec))
                 (file-directory-p (nth 1 spec)))
      (user-error "Invalid or missing Org Glean root specification: %S" spec)))
  (let ((owners (make-hash-table :test #'equal)) found)
    (dolist (spec org-glean-roots)
      (pcase-let ((`(,name ,directory ,includes ,excludes) spec))
        (let ((root (file-name-as-directory (file-truename directory))))
          (cl-labels ((walk (dir)
                        (dolist (entry (directory-files dir t directory-files-no-dot-files-regexp))
                          (unless (file-symlink-p entry)
                            (cond
                             ((file-directory-p entry) (walk entry))
                             ((and (file-regular-p entry)
                                   (string-suffix-p ".org" entry t))
                              (let ((relative (file-relative-name entry root)))
                                (when (and (or (null includes)
                                               (cl-some (lambda (rx) (string-match-p rx relative)) includes))
                                           (not (cl-some (lambda (rx) (string-match-p rx relative)) excludes)))
                                  (when (gethash entry owners)
                                    (error "Source belongs to multiple roots: %s" entry))
                                  (puthash entry name owners)
                                  (push (cons entry name) found)))))))))
            (walk root)))))
    (nreverse found)))

(defun org-glean--paragraphs (node)
  "Extract direct paragraph text from NODE, not nested headlines."
  (when node
    (string-join
     (org-element-map node 'paragraph
       (lambda (p) (string-trim (org-no-properties
                                  (buffer-substring-no-properties
                                   (org-element-property :begin p)
                                   (org-element-property :end p)))))
       nil nil '(headline paragraph))
     "\n")))

(defun org-glean--section (node)
  "Return the direct section of NODE, if any."
  (car (org-element-contents node)))

(defun org-glean--heading-id (headline)
  "Return an explicit ID property on HEADLINE, if present."
  (let ((section (cl-find-if (lambda (element)
                               (eq (org-element-type element) 'section))
                             (org-element-contents headline))))
    (when section
      (org-element-map section 'node-property
        (lambda (property)
          (when (string= "ID" (org-element-property :key property))
            (org-element-property :value property))) nil t))))

(defun org-glean--properties (headline file-properties)
  "Return generic property pairs for HEADLINE over FILE-PROPERTIES."
  (let ((properties (copy-tree (org-glean--parse-properties
                                (org-glean--sql-properties file-properties))))
        (ancestors nil)
        (parent headline)
        (depth 0))
    (while (and parent (< depth 100)
                (eq (org-element-type parent) 'headline))
      (push parent ancestors)
      (setq parent (org-element-property :parent parent)
            depth (1+ depth)))
    (dolist (node ancestors)
      (let ((section (cl-find-if (lambda (child)
                                  (eq (org-element-type child) 'section))
                                (org-element-contents node))))
        (when section
          (dolist (drawer (cl-remove-if-not
                           (lambda (child) (eq (org-element-type child) 'property-drawer))
                           (org-element-contents section)))
            (dolist (property (org-element-contents drawer))
              (when (eq (org-element-type property) 'node-property)
                (setf (alist-get (intern (org-element-property :key property))
                                 properties nil nil #'equal)
                      (org-element-property :value property))))))))
    properties))

(defun org-glean--capture-policy (headline inherited)
  "Return HEADLINE's inherited CAPTURE_POLICY, overriding INHERITED."
  (let ((local (org-glean--property-value
                (org-glean--properties headline nil) "CAPTURE_POLICY")))
    (or local inherited "eligible")))

(defun org-glean--property-value (properties key)
  "Return KEY's value from generic PROPERTIES, handling string/symbol keys."
  (cdr (cl-find key properties
                :key (lambda (pair)
                       (let ((name (car pair)))
                         (if (symbolp name) (symbol-name name) name)))
                :test #'equal)))

(defun org-glean--project (path digest)
  "Project saved PATH at DIGEST into target property lists."
  (with-temp-buffer
    (insert-file-contents path)
    (org-mode)
    (let* ((tree (org-element-parse-buffer))
           (title (or (org-element-map tree 'keyword
                        (lambda (kw)
                          (when (string= (org-element-property :key kw) "TITLE")
                            (org-element-property :value kw))) nil t)
                      (file-name-base path)))
           (file-policy (or (org-element-map tree 'keyword
                              (lambda (kw)
                                (when (and (equal "PROPERTY" (org-element-property :key kw))
                                           (string-match "\\`CAPTURE_POLICY[ \t]+\\(none\\|preferred\\|eligible\\)\\b"
                                                         (org-element-property :value kw)))
                                  (match-string 1 (org-element-property :value kw)))) nil t)
                             "eligible"))
           (file-properties (org-element-map tree 'keyword
                             (lambda (kw)
                               (when (and (equal "PROPERTY" (org-element-property :key kw))
                                          (string-match "\\`\\([^ \t]+\\)[ \t]+\\(.*\\)\\'"
                                                        (org-element-property :value kw)))
                                 (cons (match-string 1 (org-element-property :value kw))
                                       (match-string 2 (org-element-property :value kw)))))
                             nil nil '(headline)))
           (records (list (list :key (concat path "#file") :kind "file"
                                :title title :body (or (org-glean--paragraphs
                                                       (org-glean--section tree)) "")
                                 :capture-policy file-policy :level 0 :outline-path nil
                                 :properties (org-glean--properties nil file-properties)
                                :position 1)))
           (ordinal 0))
      (org-element-map tree 'headline
        (lambda (h)
          (cl-incf ordinal)
          (let ((properties (org-glean--properties h file-properties)))
          (push (list :key (format "%s@%s#heading:%d" path digest ordinal)
                      :kind "heading" :title (org-element-property :raw-value h)
                      :body (or (org-glean--paragraphs (org-glean--section h)) "")
                      :org-id (org-glean--heading-id h)
                      :capture-policy (or (org-glean--property-value properties "CAPTURE_POLICY")
                                           file-policy)
                      :level (org-element-property :level h)
                      :outline-path (let ((parent (org-element-property :parent h)) path-parts)
                                      (while (and parent (eq (org-element-type parent) 'headline))
                                        (push (org-element-property :raw-value parent) path-parts)
                                        (setq parent (org-element-property :parent parent)))
                                       (nconc path-parts (list (org-element-property :raw-value h))))
                      :properties properties
                      :position (org-element-property :begin h))
                records))))
      (nreverse records))))

(defun org-glean--replace (db path root digest records)
  "Atomically replace PATH owned by ROOT with DIGEST and RECORDS in DB."
  (sqlite-transaction db)
  (condition-case err
      (progn
        (sqlite-execute db "DELETE FROM targets WHERE path = ?" (vector path))
        (sqlite-execute db "INSERT OR REPLACE INTO sources(path,root,digest) VALUES(?,?,?)"
                        (vector path root digest))
        (dolist (record records)
          (sqlite-execute db "INSERT INTO targets(key,path,kind,title,body,org_id,position,digest,capture_policy,level,outline_path,properties) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)"
                          (vector (plist-get record :key) path (plist-get record :kind)
                                  (plist-get record :title) (plist-get record :body)
                                  (plist-get record :org-id) (plist-get record :position) digest
                                  (or (plist-get record :capture-policy) "eligible")
                                  (or (plist-get record :level) 0)
                                  (mapconcat #'identity (plist-get record :outline-path) "\x1f")
                                  (org-glean--sql-properties (plist-get record :properties)))))
        (unless (equal digest (org-glean--digest path))
          (error "Source changed before replacement committed"))
        (sqlite-commit db))
    (error (sqlite-rollback db) (signal (car err) (cdr err)))))

(defun org-glean-reconcile ()
  "Reconcile configured roots with the index; return a count plist.
Changed files are parsed before any rows are replaced.  Failed sources are
reported and preserved; a failed tree walk never deletes indexed sources."
  (interactive)
  (let* ((db (org-glean--db))
         (scan-error nil)
         (found (condition-case err
                    (org-glean--sources)
                  (error (setq scan-error err) nil)))
         (seen (make-hash-table :test #'equal))
         (counts (list :added 0 :changed 0 :unchanged 0 :removed 0 :failed nil)))
    (dolist (source found)
      (pcase-let ((`(,path . ,root) source))
        (puthash path t seen)
        (condition-case err
            (let* ((digest (org-glean--digest path))
                   (previous (car (sqlite-select db "SELECT digest,root FROM sources WHERE path=?"
                                                 (vector path))))
                   (old (car previous)))
              (if (and (equal old digest) (equal root (cadr previous)))
                  (cl-incf (plist-get counts :unchanged))
                (let ((records (org-glean--project path digest)))
                  ;; Do not publish an index of a file that changed while parsing.
                  (unless (equal digest (org-glean--digest path))
                    (error "Source changed during projection"))
                  (org-glean--replace db path root digest records)
                  (cl-incf (plist-get counts (if old :changed :added))))))
          (error (push (cons path (error-message-string err)) (plist-get counts :failed))))))
    (unless scan-error
      (dolist (row (sqlite-select db "SELECT path FROM sources"))
       (unless (gethash (car row) seen)
        (sqlite-transaction db)
        (condition-case err
            (progn
              (sqlite-execute db "DELETE FROM targets WHERE path=?" (vector (car row)))
              (sqlite-execute db "DELETE FROM sources WHERE path=?" (vector (car row)))
              (sqlite-commit db)
              (cl-incf (plist-get counts :removed)))
          (error (sqlite-rollback db) (signal (car err) (cdr err)))))))
    (when scan-error
      (setf (plist-get counts :scan-error) (error-message-string scan-error)))
    (setq org-glean--last-reconcile-at (current-time)
          org-glean--last-reconcile-counts (copy-sequence counts)
          org-glean--last-errors
          (append (when scan-error
                    (list (cons "<root-scan>" (error-message-string scan-error))))
                  (mapcar (lambda (failure) (cons (car failure) (cdr failure)))
                          (plist-get counts :failed))))
    (when (called-interactively-p 'interactive) (message "org-glean: %S" counts))
    counts))

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

(defun org-glean-update-file (path)
  "Update one saved PATH in the index; return nil on an out-of-root path."
  (let* ((absolute (expand-file-name path))
         (owner (org-glean--root-for absolute)))
    (when owner
      (let* ((digest (org-glean--digest absolute))
             (records (org-glean--project absolute digest)))
        (unless (equal digest (org-glean--digest absolute))
          (error "Source changed during projection: %s" absolute))
        (org-glean--replace (org-glean--db) absolute (car owner) digest records)
        t))))

  (defun org-glean--after-save ()
  "Queue the current saved Org file for an incremental index update."
  (when (and buffer-file-name (derived-mode-p 'org-mode)
             (or (org-glean--root-for buffer-file-name)
                 (org-glean--indexed-path-p buffer-file-name)))
    (cl-pushnew (expand-file-name buffer-file-name) org-glean--pending-files :test #'equal)
    (when (timerp org-glean--save-timer) (cancel-timer org-glean--save-timer))
    (setq org-glean--save-timer (run-with-idle-timer 1 nil #'org-glean--flush-saved-files))))

(defun org-glean--indexed-path-p (path)
  "Return non-nil when PATH already belongs to the source manifest."
  (and org-glean--database
       (caar (sqlite-select (org-glean--db) "SELECT path FROM sources WHERE path=?"
                            (vector (expand-file-name path))))))

(defun org-glean--flush-saved-files ()
  "Apply queued save-triggered updates, preserving previous rows on error."
  (setq org-glean--save-timer nil)
  (let ((pending (prog1 org-glean--pending-files
                   (setq org-glean--pending-files nil))))
    (dolist (path pending)
      (condition-case err
          (if (and (file-exists-p path) (org-glean--root-for path))
              (org-glean-update-file path)
            (let ((db (org-glean--db)))
              (sqlite-transaction db)
              (sqlite-execute db "DELETE FROM targets WHERE path=?" (vector path))
              (sqlite-execute db "DELETE FROM sources WHERE path=?" (vector path))
              (sqlite-commit db)))
        (error (message "org-glean: save update failed for %s: %s"
                        path (error-message-string err)))))))

(defun org-glean-start ()
  "Enable save-triggered updates and periodic authoritative reconciliation."
  (interactive)
  (add-hook 'after-save-hook #'org-glean--after-save)
  (when (timerp org-glean--reconcile-timer)
    (cancel-timer org-glean--reconcile-timer))
  (when (timerp org-glean--initial-timer)
    (cancel-timer org-glean--initial-timer))
  (when org-glean-roots
    (setq org-glean--initial-timer
          (run-with-idle-timer 0 nil #'org-glean--initial-reconcile)))
  (when (and (numberp org-glean-reconcile-interval)
             (> org-glean-reconcile-interval 0))
    (setq org-glean--reconcile-timer
          (run-with-idle-timer org-glean-reconcile-interval t
                               #'org-glean--periodic-reconcile)))
  (when (called-interactively-p 'interactive)
    (message "org-glean background updates enabled")))

(defun org-glean-stop ()
  "Disable save-triggered and periodic updates."
  (interactive)
  (remove-hook 'after-save-hook #'org-glean--after-save)
  (dolist (timer (list org-glean--save-timer org-glean--reconcile-timer
                       org-glean--initial-timer))
    (when (timerp timer) (cancel-timer timer)))
  (setq org-glean--save-timer nil org-glean--reconcile-timer nil
        org-glean--initial-timer nil
        org-glean--pending-files nil))

(defun org-glean--initial-reconcile ()
  "Run startup reconciliation once."
  (setq org-glean--initial-timer nil)
  (org-glean--periodic-reconcile))

(defun org-glean--periodic-reconcile ()
  "Run a background reconciliation and report failures without prompting."
  (condition-case err
      (org-glean-reconcile)
    (error (message "org-glean: periodic reconcile failed: %s"
                    (error-message-string err)))))

(defun org-glean-status ()
  "Return versioned read-only status for the active Org Glean index."
  (interactive)
  (let* ((database-available (file-readable-p org-glean-database-file))
         (counts (when database-available
                   (let ((db (org-glean--db)))
                     (list :sources (or (caar (sqlite-select db "SELECT count(*) FROM sources")) 0)
                           :targets (or (caar (sqlite-select db "SELECT count(*) FROM targets")) 0)))))
         (state (cond ((null org-glean-roots) 'unavailable)
                      ((or (plist-get org-glean--last-reconcile-counts :scan-error)
                           org-glean--last-errors)
                       'degraded)
                      (database-available 'ready)
                      (t 'unavailable)))
         (status (list :schema-version 1 :state state
                       :roots (mapcar (lambda (root) (list :id (car root) :path (expand-file-name (cadr root))))
                                      org-glean-roots)
                       :database (expand-file-name org-glean-database-file)
                       :indexed-sources (plist-get counts :sources)
                       :indexed-targets (plist-get counts :targets)
                       :last-reconcile-at org-glean--last-reconcile-at
                       :last-reconcile-counts org-glean--last-reconcile-counts
                       :semantic-state 'unavailable
                       :errors (copy-tree org-glean--last-errors))))
    (when (called-interactively-p 'interactive)
      (message "org-glean: %S" status))
    status))

(defun org-glean-show-errors ()
  "Display the latest reconciliation and search-provider errors."
  (interactive)
  (let ((buffer (get-buffer-create "*Org Glean Errors*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Org Glean errors — %s\n\n"
                        (or (and org-glean--last-reconcile-at
                                 (format-time-string "%Y-%m-%d %H:%M:%S"
                                                     org-glean--last-reconcile-at))
                            "no reconciliation recorded")))
        (if org-glean--last-errors
            (dolist (failure org-glean--last-errors)
              (insert (format "- %s: %s\n" (car failure) (cdr failure))))
          (insert "No source/reconciliation errors recorded.\n"))
        (when org-glean--last-search-provider-errors
          (insert "\nLatest search provider errors:\n")
          (dolist (failure org-glean--last-search-provider-errors)
            (insert (format "- %s: %s\n" (car failure) (cdr failure)))))
        (special-mode)))
    (pop-to-buffer buffer)))

(defun org-glean--results (rows)
  "Turn ROWS into typed result property lists."
  (mapcar (lambda (row)
            (let ((item (cl-mapcar #'cons
                                   '(:key :path :kind :title :org-id :position :digest :snippet
                                     :capture-policy :level :outline-path :properties)
                                   (append row nil))))
              (org-glean--decode-target item))) rows))

(defun org-glean--sql-properties (properties)
  "Encode target PROPERTIES as JSON for the local index."
  (json-encode (or properties [])))

(defun org-glean--parse-properties (value)
  "Parse serialized property VALUE from the index."
  (when (and value (not (string-empty-p value)) (not (string= value "null")))
    (condition-case nil
        (json-parse-string value :object-type 'alist :array-type 'list :null-object nil)
      (error nil))))

(defun org-glean--decode-target (item)
  "Decode structured fields in result ITEM."
  (when (alist-get :outline-path item)
    (setf (alist-get :outline-path item)
          (split-string (alist-get :outline-path item) "\x1f" t)))
  (setf (alist-get :properties item)
        (org-glean--parse-properties (alist-get :properties item)))
  item)

(defun org-glean--alist-put (key value alist)
  "Store KEY VALUE in ALIST, returning the updated association list."
  (let ((cell (assq key alist)))
    (if cell (setcdr cell value)
      (push (cons key value) alist))
    alist))

(defun org-glean--select-columns ()
  "Return the common target result columns for SQL queries."
  "key,path,kind,title,org_id,position,digest,snippet,capture_policy,level,outline_path,properties")

(defun org-glean-search-exact (title &optional limit)
  "Return at most LIMIT targets whose title exactly matches TITLE."
  (org-glean--results
   (sqlite-select (org-glean--db)
                   "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE title=? ORDER BY path,position LIMIT ?"
                  (vector title (max 1 (min 100 (or limit 20)))))))

(defun org-glean-search (query &optional limit fuzzy)
  "Search exact and FTS targets for QUERY, returning at most LIMIT results.
When FUZZY is non-nil, add bounded fuzzy candidates."
  (car (org-glean-search-filtered query limit fuzzy nil)))

(defun org-glean--fts-pattern (query)
  "Return a safely quoted FTS5 prefix query for QUERY, or nil if empty."
  (let ((words (split-string (string-trim (or query "")) "[[:space:]]+" t)))
    (when words
      (mapconcat (lambda (word)
                   (concat "\"" (replace-regexp-in-string "\"" "\"\"" word t t) "\"*"))
                 words " AND "))))

(defun org-glean--properties-match-p (properties requirements)
  "Return non-nil when PROPERTIES satisfies every key/value REQUIREMENT."
  (when (eq properties :null) (setq properties nil))
  (cl-every
   (lambda (requirement)
     (let* ((key (if (symbolp (car requirement))
                     (symbol-name (car requirement)) (car requirement)))
            (actual (cl-some (lambda (property)
                               (when (equal key (if (symbolp (car property))
                                                    (symbol-name (car property))
                                                  (car property)))
                                 (cdr property)))
                             properties)))
       (equal (cdr requirement) actual)))
   requirements))

(defun org-glean--filtered-out-p (item filters)
  "Return non-nil if ITEM does not satisfy FILTERS."
  (or (member (downcase (or (alist-get :capture-policy item) "eligible"))
              (mapcar #'downcase (plist-get filters :exclude-property-values)))
      (and (plist-get filters :max-heading-level)
           (equal (alist-get :kind item) "heading")
           (> (or (alist-get :level item) 0) (plist-get filters :max-heading-level)))
      (member (downcase (or (alist-get :title item) ""))
              (mapcar #'downcase (plist-get filters :exclude-titles)))
       (not (org-glean--properties-match-p
             (alist-get :properties item) (plist-get filters :property-equals)))))

(defun org-glean--in-roots-p (item roots)
  "Return non-nil when ITEM belongs to one of ROOTS, without symlink escape."
  (or (null roots)
      (let ((path (alist-get :path item)))
        (and path (file-exists-p path)
             (cl-some (lambda (root)
                        (let ((root (file-name-as-directory (file-truename root)))
                              (true-path (file-truename path)))
                          (and (file-directory-p root) (file-in-directory-p true-path root))))
                      roots)))))

(defun org-glean--eligible-p (item filters)
  "Return non-nil when ITEM passes FILTERS, including allowed-root scope."
  (let ((roots-specified (plist-member filters :allowed-roots))
        (roots (plist-get filters :allowed-roots)))
    (and (not (org-glean--filtered-out-p item filters))
         (or (not roots-specified)
             (and roots (org-glean--in-roots-p item roots))))))

(defun org-glean--collect-provider (db sql params filters limit budget page-size seen)
  "Read provider candidates in pages, filtering before filling LIMIT.
Return (ITEMS EXAMINED INCOMPLETE EXTRA)."
  (let ((offset 0) (examined 0) (items nil) (extra nil) (done nil))
    (while (and (not done) (< examined budget) (not extra)
                (< (length items) (1+ limit)))
      (let* ((size (min page-size (- budget examined)))
             (rows (org-glean--results
                    (sqlite-select db sql (vconcat params (vector size offset))))))
        (setq examined (+ examined (length rows))
              offset (+ offset (length rows))
              done (< (length rows) size))
        (cl-incf org-glean--provider-work-count (length rows))
        (dolist (item rows)
          (when (or (not (file-exists-p (alist-get :path item)))
                    (not (equal (alist-get :digest item)
                                (org-glean--digest (alist-get :path item)))))
            (setq org-glean--provider-stale-seen t))
          (unless (gethash (alist-get :key item) seen)
            (when (org-glean--eligible-p item filters)
              (if (>= (length items) limit)
                  (setq extra t)
                (puthash (alist-get :key item) t seen)
                (push item items)))))))
    (list (nreverse items) examined
          (and (not done) (not extra) (>= examined budget)
               (<= (length items) limit))
          extra)))

(defun org-glean--trigrams (text)
  "Return the unique padded trigrams from TEXT."
  (let ((text (concat "  " (downcase text) "  ")) result)
    (dotimes (index (max 1 (- (length text) 2)))
      (push (substring text index (+ index 3)) result))
    (let ((unique (delete-dups (nreverse result))))
      (if (<= (length unique) 32) unique
        (cl-loop for index below 32
                 collect (nth (/ (* index (1- (length unique))) 31) unique))))))

(defun org-glean--collect-fuzzy (db query filters limit budget page-size seen)
  "Collect typo-tolerant title results from bounded trigram candidates."
  (let* ((needle (downcase (string-trim query)))
         (trigrams (org-glean--trigrams needle))
         (where (mapconcat (lambda (_) "lower(title) LIKE ?") trigrams " OR "))
         (patterns (mapcar (lambda (gram) (concat "%" gram "%")) trigrams))
         (sql (format "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE %s ORDER BY title,path,position LIMIT ? OFFSET ?" where))
         (scan-cap (min budget org-glean-fuzzy-candidate-limit))
         (offset 0) (examined 0) (done nil) scored extra)
    (while (and (not done) (< examined scan-cap) (not extra))
      (let* ((size (min page-size (- scan-cap examined)))
             (rows (org-glean--results
                    (sqlite-select db sql (vconcat patterns (vector size offset))))))
        (setq examined (+ examined (length rows))
              offset (+ offset (length rows))
              done (< (length rows) size))
        (cl-incf org-glean--provider-work-count (length rows))
        (dolist (item rows)
          (when (or (not (file-exists-p (alist-get :path item)))
                    (not (equal (alist-get :digest item)
                                (org-glean--digest (alist-get :path item)))))
            (setq org-glean--provider-stale-seen t))
          (unless (gethash (alist-get :key item) seen)
            (when (org-glean--eligible-p item filters)
              (let* ((title (downcase (or (alist-get :title item) "")))
                     (scale (max 1 (length needle) (length title)))
                     (similarity (* 100.0 (/ (- scale (string-distance needle title))
                                             (float scale)))))
                (when (>= similarity 60.0)
                  (push (cons similarity item) scored))))))))
    (setq scored (sort scored (lambda (left right) (> (car left) (car right)))))
    (let* ((selected (cl-subseq scored 0 (min (length scored) (1+ limit))))
           (matches (mapcar (lambda (pair)
                              (let ((item (cdr pair)))
                                (puthash (alist-get :key item) t seen)
                                (setf (alist-get :match-type item) 'fuzzy
                                      (alist-get :score item) (* 0.84 (car pair)))
                                item))
                            (cl-subseq selected 0 (min limit (length selected))))))
      (setq extra (> (length scored) (length matches)))
      (list matches examined
            (and (not done) (not extra) (>= examined scan-cap))
            extra))))

(defun org-glean--mark-result (item match-type rank)
  "Add match metadata and source freshness to ITEM."
  (setf (alist-get :match-type item) (or (alist-get :match-type item) match-type)
        (alist-get :score item) (or (alist-get :score item)
                                    (if (eq match-type 'exact) 100.0
                                      (max 85.0 (- 94.0 (* rank 0.01)))))
        (alist-get :source-current item)
        (and (file-exists-p (alist-get :path item))
             (equal (alist-get :digest item) (org-glean--digest (alist-get :path item)))))
  item)

(defun org-glean-search-filtered (query limit fuzzy filters)
  "Search QUERY, applying FILTERS and :allowed-roots before LIMIT."
  (let* ((db (org-glean--db))
         (limit (max 1 (min 100 (or limit org-glean-search-limit))))
         (budget (max 1 org-glean-search-work-budget))
         (page-size (max 1 (min 200 org-glean-search-page-size)))
         (remaining budget)
         (seen (make-hash-table :test #'equal))
         (org-glean--provider-stale-seen nil)
         (used nil)
         (provider-errors nil)
         exact lexical fuzzy-results
         (extra nil) (incomplete nil))
    (when (and (stringp query) (not (string-empty-p query)))
      (let ((org-glean--provider-work-count 0))
        (condition-case err
            (progn
              (let ((page (org-glean--collect-provider
                           db "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE title=? ORDER BY path,position LIMIT ? OFFSET ?"
                           (vector query) filters (1+ limit) remaining page-size seen)))
                (setq exact (nth 0 page) remaining (- remaining (nth 1 page))
                      incomplete (nth 2 page) extra (nth 3 page)))
              (push 'exact used))
          (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                  (push (cons 'exact (error-message-string err)) provider-errors)))))
    (when (and (not extra) (not incomplete) (> remaining 0))
      (let ((fts (org-glean--fts-pattern query)))
        (when fts
          (let ((org-glean--provider-work-count 0))
            (condition-case err
                (progn
                  (let ((page (org-glean--collect-provider
                               db "SELECT t.key,t.path,t.kind,t.title,t.org_id,t.position,t.digest,snippet(target_fts,1,'[',']','…',16),t.capture_policy,t.level,t.outline_path,t.properties FROM target_fts JOIN targets t ON t.rowid=target_fts.rowid WHERE target_fts MATCH ? ORDER BY bm25(target_fts),t.path,t.position LIMIT ? OFFSET ?"
                               (vector fts) filters (1+ (- limit (length exact)))
                               remaining page-size seen)))
                    (setq lexical (nth 0 page) remaining (- remaining (nth 1 page))
                          incomplete (nth 2 page) extra (nth 3 page)))
                  (push 'lexical used))
              (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                      (push (cons 'lexical (error-message-string err)) provider-errors)))))))
    (when (and fuzzy (stringp query) (not (string-empty-p (string-trim query)))
               (not extra) (not incomplete) (> remaining 0)
               (< (+ (length exact) (length lexical)) (1+ limit)))
      (let ((org-glean--provider-work-count 0))
        (condition-case err
            (progn
              (let ((page (org-glean--collect-fuzzy
                           db query filters (1+ (- limit (length exact) (length lexical)))
                           remaining page-size seen)))
                (setq fuzzy-results (nth 0 page) remaining (- remaining (nth 1 page))
                      incomplete (nth 2 page) extra (nth 3 page)))
              (push 'fuzzy used))
          (error (setq remaining (max 0 (- remaining org-glean--provider-work-count)))
                  (push (cons 'fuzzy (error-message-string err)) provider-errors)))))
      (let* ((all (append (mapcar (lambda (item) (org-glean--mark-result item 'exact 0)) exact)
                        (cl-loop for item in lexical for rank from 0
                                 collect (org-glean--mark-result item 'lexical rank))
                        (mapcar (lambda (item) (org-glean--mark-result item 'fuzzy 0))
                                fuzzy-results)))
           (has-extra (> (length all) limit))
           (all (cl-subseq all 0 (min (length all) (1+ limit))))
           (truncated (or extra incomplete provider-errors has-extra))
           (stale (or org-glean--provider-stale-seen
                      (cl-some (lambda (item) (not (alist-get :source-current item))) all)))
           (results (cl-subseq all 0 (min limit (length all)))))
       (setq org-glean--last-search-completeness
             (cond ((or incomplete provider-errors) 'incomplete)
                   ((or extra has-extra) 'truncated)
                   (t 'complete))
             org-glean--last-search-used (nreverse used)
             org-glean--last-search-provider-errors (nreverse provider-errors))
      (setq org-glean--last-search-examined (- budget remaining))
       (list results truncated stale))))

(defun org-glean-search-api (query &optional limit fuzzy filters)
  "Return a versioned, bounded result-set for QUERY.
FUZZY enables bounded title/heading matching. FILTERS is a plist supporting
:exclude-property-values, :max-heading-level, :exclude-titles, and
:allowed-roots. Filters and scope are applied before the result limit."
  (let* ((limit (max 1 (min 100 (or limit org-glean-search-limit))))
         (search (org-glean-search-filtered query limit fuzzy filters))
         (all-results (nth 0 search))
         (truncated (nth 1 search))
         (stale-p (nth 2 search))
         (results (sort all-results #'org-glean--relevance-before-p))
          (results (cl-loop for item in results for rank from 1
                           for next = (nth rank results)
                           for score = (or (alist-get :score item) 0)
                           for next-score = (or (alist-get :score next) 0)
                           collect (append item
                                            `((:rank . ,rank)
                                              (:margin . ,(- score next-score))
                                             (:match-reason . ,(pcase (alist-get :match-type item)
                                                                 ('exact "exact title")
                                                                 ('fuzzy "fuzzy title or heading")
                                                                 (_ "FTS5 lexical match")))
                                             (:link . ,(if (alist-get :org-id item)
                                                           (format "[[id:%s][%s]]"
                                                                   (alist-get :org-id item)
                                                                   (alist-get :title item))
                                                         (format "[[file:%s::%d][%s]]"
                                                                 (alist-get :path item)
                                                                 (alist-get :position item)
                                                                 (alist-get :title item))))))))
          (freshness (cond (stale-p 'stale-source-present)
                           ((null all-results) 'index-checked)
                           (t 'sources-checked-current)))
          (completeness org-glean--last-search-completeness))
    `((schema-version . 1)
      (query . ,query)
      (requested . ((lexical . t) (fuzzy . ,(if fuzzy t :false))
                    (filters . ,(if filters t :false))))
       (used . ,org-glean--last-search-used)
        (degraded . ,(cond (org-glean--last-search-provider-errors 'provider-error)
                           ((eq completeness 'incomplete) 'incomplete)
                           (t :false)))
       (freshness . ,freshness)
       (limit . ,limit)
       (candidate-count . ,(length results))
        (completeness . ,completeness)
        (truncated . ,(if truncated t :false))
        (work-examined . ,org-glean--last-search-examined)
        (provider-errors . ,(vconcat
                             (mapcar (lambda (failure)
                                       `((provider . ,(car failure))
                                         (message . ,(cdr failure))))
                                     org-glean--last-search-provider-errors)))
        (results . ,(vconcat results)))))

(defun org-glean--refresh-result (result)
  "Resolve stable RESULT by ID and recheck its database/source snapshot."
  (let* ((db (org-glean--db))
         (id (alist-get :org-id result)))
    (when id
      (let ((matches (sqlite-select db
                                    "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE org_id=? LIMIT 2"
                                    (vector id))))
        (cond
         ((> (length matches) 1)
          (user-error "Org ID %s is ambiguous; refusing navigation" id))
         ((= (length matches) 1)
          (setq result (car (org-glean--results matches))))
         (t (user-error "Org ID %s is no longer indexed; reconcile and search again" id)))))
    (let* ((path (alist-get :path result))
           (digest (alist-get :digest result))
           (current (caar (sqlite-select db "SELECT digest FROM targets WHERE key=?"
                                         (vector (alist-get :key result))))))
      (unless (equal current digest)
        (user-error "Result is no longer indexed; search again"))
      (unless (and (file-exists-p path) (equal digest (org-glean--digest path)))
        (user-error "Source changed; reconcile and search again"))
      result)))

(defun org-glean--target-position (buffer result)
  "Resolve RESULT within BUFFER, returning a validated heading position."
  (with-current-buffer buffer
    (when (and buffer-file-name (not (verify-visited-file-modtime buffer)))
      (user-error "Visited buffer is stale; revert it before navigating"))
    (when (buffer-modified-p)
      (user-error "Source has unsaved changes; save before navigating"))
    (save-restriction
      (widen)
      (if (not (equal (alist-get :kind result) "heading"))
          (or (alist-get :position result) (point-min))
        (let ((id (alist-get :org-id result))
              positions)
          (if id
              (org-map-entries
               (lambda ()
                 (when (equal id (org-entry-get nil "ID"))
                   (push (point) positions))) nil 'file)
            (goto-char (alist-get :position result))
            (when (and (org-at-heading-p)
                       (equal (alist-get :title result) (org-get-heading t t t t)))
              (push (point) positions)))
          (unless (= (length positions) 1)
            (user-error "Heading no longer resolves uniquely; reconcile and search again"))
          (car positions))))))

(defun org-glean-open-result (result &optional preview)
  "Open RESULT. With PREVIEW, show another window and retain selected-window focus."
  (let* ((resolved (org-glean--refresh-result result))
         (path (alist-get :path resolved))
         (buffer (find-file-noselect path))
         (position (org-glean--target-position buffer resolved)))
    (with-current-buffer buffer (goto-char position))
    (if preview
        (let ((window (display-buffer buffer '(display-buffer-pop-up-window)))
              (origin (selected-window)))
          (when (window-live-p window)
            (set-window-point window position))
          (when (window-live-p origin)
            (select-window origin)))
      (let ((window (display-buffer buffer '(display-buffer-pop-up-window))))
        (select-window window)
        (with-current-buffer buffer (goto-char position))))
    buffer))

(defun org-glean-visit (result)
  "Visit RESULT and move point to the resolved target."
  (interactive)
  (org-glean-open-result result nil))

(defvar org-glean-results-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'org-glean-results-visit)
    (define-key map (kbd "TAB") #'org-glean-results-preview)
    (define-key map (kbd "e") #'org-glean-results-toggle-group)
    (define-key map (kbd "g") #'org-glean-results-refresh)
    map))

(define-derived-mode org-glean-results-mode tabulated-list-mode "Org-Glean"
  "Major mode for bounded Org Glean results."
  (setq tabulated-list-format
        [("Title" 38 t) ("Kind" 10 t) ("Source" 28 t) ("Match" 12 t)
         ("Fresh" 7 t)])
  (setq tabulated-list-padding 2
        tabulated-list-sort-key nil)
  (tabulated-list-init-header))

(defvar-local org-glean--results-query nil)
(defvar-local org-glean--results-filters nil)
(defvar-local org-glean--results-items nil)
(defvar-local org-glean--results-groups nil)
(defvar-local org-glean--results-expanded-groups nil)

(defun org-glean--result-sort-key (item)
  "Return the results-buffer order key for ITEM."
  (list (or (cdr (assq (alist-get :match-type item)
                       '((exact . 0) (lexical . 1) (fuzzy . 2)))) 3)))

(defun org-glean--relevance-before-p (left right)
  "Return non-nil if LEFT has higher display relevance than RIGHT."
  (let ((left-key (org-glean--result-sort-key left))
        (right-key (org-glean--result-sort-key right)))
    (if (= (car left-key) (car right-key))
        (let ((left-score (or (alist-get :score left) 0))
              (right-score (or (alist-get :score right) 0)))
          (if (= left-score right-score)
              (< (or (alist-get :rank left) most-positive-fixnum)
                 (or (alist-get :rank right) most-positive-fixnum))
            (> left-score right-score)))
      (< (car left-key) (car right-key)))))

(defun org-glean--result-groups (items)
  "Group repeated fuzzy headings in the same file from ITEMS."
  (let (groups ordered)
    (dolist (item items)
      (let* ((groupable (and (eq (alist-get :match-type item) 'fuzzy)
                             (equal (alist-get :kind item) "heading")))
             (group-key (and groupable
                             (list (alist-get :path item) (alist-get :title item))))
             (group (and group-key
                         (cl-find-if (lambda (existing)
                                       (equal group-key (car existing)))
                                     groups))))
        (if group
            (setcdr group (append (cdr group) (list item)))
          (let ((entry (cons (or group-key (alist-get :key item)) (list item))))
            (push entry groups)
            (push entry ordered)))))
    (let ((ordered (nreverse ordered)))
      (dolist (group ordered)
        (setcdr group (sort (cdr group) #'org-glean--relevance-before-p)))
      (sort ordered
          (lambda (left right)
            (org-glean--relevance-before-p (cadr left) (cadr right)))))))

(defun org-glean--tabulated-row (item &optional count)
  "Format ITEM as a row, optionally labelling a COUNT of grouped hits."
  (let* ((key (alist-get :key item))
         (title (or (alist-get :title item) ""))
         (title (if (and count (> count 1))
                    (format "%s (%d matches; e expands)" title count)
                  title))
         (kind (or (alist-get :kind item) ""))
         (source (file-name-nondirectory (alist-get :path item)))
         (match (symbol-name (alist-get :match-type item)))
         (fresh (if (alist-get :source-current item) "yes" "stale")))
    (list key (vector title kind source match fresh))))

(defun org-glean--tabulated-rows ()
  "Build collapsed/expanded tabulated rows from the current search results."
  (let (rows)
    (dolist (group org-glean--results-groups)
      (let* ((items (cdr group))
             (group-key (car group))
             (expanded (member group-key org-glean--results-expanded-groups)))
        (if (and expanded (> (length items) 1))
            (dolist (item items) (push (org-glean--tabulated-row item) rows))
          (push (org-glean--tabulated-row
                 (car (sort (copy-sequence items) #'org-glean--relevance-before-p))
                 (length items)) rows))))
    (nreverse rows)))

(defun org-glean--buffer-result-items ()
  "Return ordered result items for the current results buffer."
  (apply #'append (mapcar #'cdr org-glean--results-groups)))

(defun org-glean--tabulated-row-result ()
  "Resolve the result represented by the current tabulated row."
  (let ((key (tabulated-list-get-id)))
    (or (cl-find key (org-glean--buffer-result-items)
                 :key (lambda (item) (alist-get :key item)) :test #'equal)
        (cl-find-if (lambda (group) (equal key (car group)))
                    org-glean--results-groups)
        (user-error "Result disappeared; refresh the list"))))

(defun org-glean--selected-result-group ()
  "Return the group represented by the currently selected row."
  (let* ((key (tabulated-list-get-id))
         (group (cl-find-if (lambda (candidate)
                              (or (equal key (car candidate))
                                  (cl-some (lambda (item)
                                             (equal key (alist-get :key item)))
                                           (cdr candidate))))
                            org-glean--results-groups)))
    (unless group (user-error "Result disappeared; refresh the list"))
    (cdr group)))

(defun org-glean--selected-result-items ()
  "Return the selected target, or representative target for a collapsed group."
  (let* ((key (tabulated-list-get-id))
         (items (org-glean--selected-result-group))
         (selected (cl-find key items :key (lambda (item) (alist-get :key item))
                            :test #'equal)))
    (list (or selected (car items)))))

(defun org-glean--tabulated-entry (item)
  "Format result ITEM as one Tabulated List entry."
  (org-glean--tabulated-row item))

(defun org-glean-results-refresh ()
  "Refresh the current Org Glean result buffer."
  (interactive)
  (unless org-glean--results-query (user-error "No Org Glean query to refresh"))
  (let* ((response (org-glean-search-api org-glean--results-query 100 t
                                         org-glean--results-filters))
         (results (alist-get 'results response)))
    (setq org-glean--results-items (append results nil)
          org-glean--results-groups (org-glean--result-groups org-glean--results-items)
          org-glean--results-expanded-groups
          (cl-remove-if-not (lambda (key)
                              (cl-some (lambda (group) (equal key (car group)))
                                       org-glean--results-groups))
                            org-glean--results-expanded-groups)
          tabulated-list-entries (org-glean--tabulated-rows))
    (tabulated-list-print t)
      (setq header-line-format
          (format "Query: %s | freshness: %s | %d targets — TAB previews, RET visits, e expands/collapses, g refreshes"
                  org-glean--results-query (alist-get 'freshness response)
                  (length results)))))

(defun org-glean-results-visit ()
  "Visit the indexed target on the current results row."
  (interactive)
  (org-glean-visit (org-glean--tabulated-row-result)))

(defun org-glean-results-preview ()
  "Preview the selected result in another window without moving focus."
  (interactive)
  (org-glean-open-result (org-glean--tabulated-row-result) t))

(defun org-glean-results-toggle-group ()
  "Expand/collapse repeated fuzzy hits on the selected file/title group."
  (interactive)
  (let* ((selected (org-glean--selected-result-group))
         (key (list (alist-get :path (car selected))
                    (alist-get :title (car selected)))))
    (unless (> (length selected) 1)
      (user-error "Selected row has no repeated matches to expand"))
    (if (member key org-glean--results-expanded-groups)
        (setq org-glean--results-expanded-groups
              (delete key org-glean--results-expanded-groups))
      (push key org-glean--results-expanded-groups))
          (setq tabulated-list-entries (org-glean--tabulated-rows))
    (tabulated-list-print t)))

(defun org-glean-search-buffer (query &optional filters)
  "Show QUERY in an exploration results buffer.
FILTERS is the generic result-filter plist accepted by `org-glean-search-api'."
  (interactive "sSearch Org: ")
  (let ((buffer (get-buffer-create "*Org Glean Results*")))
    (with-current-buffer buffer
      (org-glean-results-mode)
      (setq org-glean--results-query query
            org-glean--results-filters filters)
      (org-glean-results-refresh))
    (pop-to-buffer buffer)))

;;;###autoload
(defun org-glean-find (query)
  "Pick and visit a bounded fuzzy/FTS result for QUERY."
  (interactive "sSearch Org: ")
  (let* ((results (append (alist-get 'results (org-glean-search-api query nil t)) nil))
         (choices (cl-loop for item in results for n from 1
                           collect (cons (format "%d. %s — %s (%s)" n
                                                 (alist-get :title item)
                                                 (file-name-nondirectory (alist-get :path item))
                                                 (alist-get :kind item)) item)))
         (choice (and choices (completing-read "Visit: " choices nil t))))
    (unless choice (user-error "No matches"))
    (org-glean-visit (cdr (assoc choice choices)))))

(defun org-glean-install-defaults ()
  "Start background freshness updates when package is loaded in a user session."
  (when (and (not noninteractive) org-glean-roots)
    (org-glean-start)))

(add-hook 'emacs-startup-hook #'org-glean-install-defaults)

(provide 'org-glean)
;;; org-glean.el ends here
