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
  "Migrate DB from the original lexical schema to current schema."
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
  t)

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
            (sqlite-execute db "INSERT INTO target_fts(target_fts) VALUES('rebuild')")
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
When FUZZY is non-nil, add bounded title/heading fuzzy candidates."
  (let* ((db (org-glean--db))
         (fts-pattern (org-glean--fts-pattern query))
         (cap (max 1 (min 100 (or limit org-glean-search-limit))))
         (words (split-string (string-trim (or query "")) "[[:space:]]+" t))
         (exact (when (and (stringp query) (not (string-empty-p query)))
                  (org-glean--results
                   (sqlite-select db
                          "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets WHERE title=? ORDER BY path,position LIMIT ?"
                                  (vector query cap)))))
          (lexical (when (and words fts-pattern)
                     (condition-case nil
                        (org-glean--results
                         (sqlite-select db
                                         "SELECT t.key,t.path,t.kind,t.title,t.org_id,t.position,t.digest,snippet(target_fts,1,'[',']','…',16),t.capture_policy,t.level,t.outline_path,t.properties FROM target_fts JOIN targets t ON t.rowid=target_fts.rowid WHERE target_fts MATCH ? ORDER BY bm25(target_fts),t.path,t.position LIMIT ?"
                                        (vector fts-pattern cap)))
                      (error nil))))
         (all (append exact lexical))
         (seen (make-hash-table :test #'equal)))
    (setq all (cl-remove-if (lambda (item)
                              (if (gethash (alist-get :key item) seen) t
                                (puthash (alist-get :key item) t seen) nil)) all))
    (when (and fuzzy (< (length all) cap)
               (not (string-empty-p (string-trim (or query "")))))
      (let* ((candidates (sqlite-select db
                                          "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160),capture_policy,level,outline_path,properties FROM targets ORDER BY title LIMIT 2000"))
             (records (org-glean--results candidates))
             (scored (cl-loop for item in records
                              for title = (downcase (or (alist-get :title item) ""))
                              for needle = (downcase (string-trim (or query "")))
                              for distance = (string-distance needle title)
                              for scale = (max (length needle) (length title) 1)
                              for score = (* 100.0 (/ (- scale distance) (float scale)))
                              when (and (>= score 60.0)
                                        (not (gethash (alist-get :key item) seen)))
                              collect (cons score item))))
        (dolist (pair (sort scored (lambda (a b) (> (car a) (car b)))))
          (when (< (length all) cap)
            (let ((item (cdr pair)))
              (setq all (append all (list (append item
                                                  `((:match-type . fuzzy)
                                                    (:score . ,(round (car pair))))))))
              (puthash (alist-get :key item) t seen))))))
    (setq all (cl-subseq all 0 (min cap (length all))))
    (mapcar (lambda (item)
              (let* ((match-type (or (alist-get :match-type item)
                                     (if (member item exact) 'exact 'lexical)))
                     (score (or (alist-get :score item)
                                (if (eq match-type 'exact) 100.0 85.0)))
                     (current (and (file-exists-p (alist-get :path item))
                                   (equal (alist-get :digest item)
                                          (org-glean--digest (alist-get :path item))))))
                (setq item (org-glean--alist-put :match-type match-type item)
                      item (org-glean--alist-put :score score item)
                      item (org-glean--alist-put :source-current current item))
                item)) all)))

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

(defun org-glean-search-api (query &optional limit fuzzy filters)
  "Return a versioned, bounded result-set for QUERY.
FUZZY enables bounded title/heading matching. FILTERS is a plist supporting
:exclude-property-values, :max-heading-level, and :exclude-titles."
  (let* ((all-results (org-glean-search query limit fuzzy))
         (results (cl-remove-if (lambda (item) (org-glean--filtered-out-p item filters))
                                all-results))
         (stale-p (cl-some (lambda (item) (not (alist-get :source-current item))) all-results))
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
                          (t 'sources-checked-current))))
    `((schema-version . 1)
      (query . ,query)
      (requested . ((lexical . t) (fuzzy . ,(if fuzzy t :false))
                    (filters . ,(if filters t :false))))
      (used . ,(if fuzzy '(exact lexical fuzzy) '(exact lexical)))
      (degraded . :false)
      (freshness . ,freshness)
      (limit . ,(min 100 (max 1 (or limit org-glean-search-limit))))
      (candidate-count . ,(length results))
      (truncated . :false)
      (results . ,(vconcat results)))))

(defun org-glean-visit (result)
  "Visit RESULT if it still resolves unambiguously in the saved source."
  (let* ((id (alist-get :org-id result))
         (db (org-glean--db)))
    ;; Resolve explicit IDs afresh so a moved heading remains navigable, but
    ;; never guess if the configured roots contain duplicate IDs.
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
           (position (alist-get :position result))
           (current (caar (sqlite-select db "SELECT digest FROM targets WHERE key=?"
                                         (vector (alist-get :key result))))))
      (unless (equal current digest)
        (user-error "Result is no longer indexed; search again"))
      (unless (and (file-exists-p path)
                   (equal digest (org-glean--digest path)))
        (user-error "Source changed; reconcile and search again"))
      (when (and (get-file-buffer path) (buffer-modified-p (get-file-buffer path)))
        (let ((edited-buffer (get-file-buffer path)))
          (when (and (buffer-file-name edited-buffer)
                     (not (verify-visited-file-modtime edited-buffer)))
            (user-error "Visited buffer is stale; revert it before navigating"))
          (user-error "Source has unsaved changes; save before navigating")))
      (let ((buffer (find-file-noselect path)))
        (with-current-buffer buffer
          (when (and buffer-file-name (not (verify-visited-file-modtime buffer)))
            (user-error "Visited buffer is stale; revert it before navigating"))
          (let ((saved-id id)
                (target result))
          (save-restriction
            (widen)
            (if saved-id
                (progn
                  (goto-char (point-min))
                  (unless (re-search-forward
                           (format "^\\*+ +%s[ \t]*$"
                                   (regexp-quote (alist-get :title target))) nil t)
                    (user-error "Stable-ID heading was not found in its resolved file"))
                  (unless (equal saved-id (org-entry-get nil "ID"))
                    (user-error "Stable-ID heading no longer matches the index")))
              (goto-char position))
            (when (and (equal (alist-get :kind result) "heading")
                       (or (not (org-at-heading-p))
                             (not (equal (alist-get :title target)
                                        (org-get-heading t t t t)))
                             (not (equal saved-id (org-entry-get nil "ID")))))
              (user-error "Heading no longer matches the indexed target")))))
        (pop-to-buffer buffer)
        (goto-char position)))))

(defvar org-glean-results-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'org-glean-results-visit)
    (define-key map (kbd "g") #'org-glean-results-refresh)
    map))

(define-derived-mode org-glean-results-mode tabulated-list-mode "Org-Glean"
  "Major mode for bounded Org Glean results."
  (setq tabulated-list-format
        [("Title" 38 t) ("Kind" 10 t) ("Source" 28 t) ("Match" 12 t)
         ("Fresh" 7 t)])
  (setq tabulated-list-padding 2
        tabulated-list-sort-key (cons "Match" nil))
  (tabulated-list-init-header))

(defvar-local org-glean--results-query nil)
(defvar-local org-glean--results-filters nil)

(defun org-glean-results-refresh ()
  "Refresh the current Org Glean result buffer."
  (interactive)
  (unless org-glean--results-query (user-error "No Org Glean query to refresh"))
  (let* ((response (org-glean-search-api org-glean--results-query 100 t
                                         org-glean--results-filters))
         (results (alist-get 'results response))
         (rows (mapcar (lambda (item)
                         (let* ((key (alist-get :key item))
                                (title (or (alist-get :title item) ""))
                                (kind (or (alist-get :kind item) ""))
                                (source (file-name-nondirectory (alist-get :path item)))
                                (match (symbol-name (alist-get :match-type item)))
                                (fresh (if (alist-get :source-current item) "yes" "stale")))
                           (cons key (vector title kind source match fresh)))) results)))
    (setq tabulated-list-entries rows)
    (tabulated-list-print t)
    (setq header-line-format
          (format "Query: %s | freshness: %s | %d results — RET visits, g refreshes"
                  org-glean--results-query (alist-get 'freshness response)
                  (length results)))))

(defun org-glean-results-visit ()
  "Visit the indexed target on the current results row."
  (interactive)
  (let* ((key (tabulated-list-get-id))
         (response (org-glean-search-api org-glean--results-query 100 t
                                         org-glean--results-filters))
         (item (cl-find key (append (alist-get 'results response) nil)
                        :key (lambda (result) (alist-get :key result)) :test #'equal)))
    (unless item (user-error "Result disappeared; refresh the list"))
    (org-glean-visit item)))

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
