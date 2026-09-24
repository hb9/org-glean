;;; org-glean.el --- Read-only Org indexing and search -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Version: 0.1.0
;; Keywords: outlines, search

;;; Commentary:
;; The database is disposable.  All corpus files are read, never modified.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'sqlite)
(require 'subr-x)

(defgroup org-glean nil "Local search for Org files." :group 'org)

(defcustom org-glean-roots nil
  "Named root specifications (NAME DIRECTORY INCLUDES EXCLUDES).
INCLUDES and EXCLUDES are lists of regexps against root-relative paths.
An empty INCLUDES list accepts every .org file."
  :type '(repeat (list string directory (repeat regexp) (repeat regexp))))

(defcustom org-glean-database-file
  (expand-file-name "org-glean.sqlite" user-emacs-directory)
  "Path to the disposable search index."
  :type 'file)

(defvar org-glean--database nil)
(defvar org-glean--database-path nil)

(defun org-glean--digest (path)
  "Hash the literal saved bytes in PATH."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun org-glean--db ()
  "Return the open database, checking required capabilities first."
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (error "org-glean requires Emacs built with SQLite support"))
  (when (and org-glean--database
             (not (equal org-glean--database-path
                         (expand-file-name org-glean-database-file))))
    (org-glean-close))
  (unless org-glean--database
    (make-directory (file-name-directory (expand-file-name org-glean-database-file)) t)
    (let ((db (sqlite-open org-glean-database-file)))
      (condition-case err
          (progn
            (sqlite-execute db "CREATE TABLE IF NOT EXISTS sources (path TEXT PRIMARY KEY, root TEXT NOT NULL, digest TEXT NOT NULL)")
            (sqlite-execute db "CREATE TABLE IF NOT EXISTS targets (key TEXT PRIMARY KEY, path TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, org_id TEXT, position INTEGER NOT NULL, digest TEXT NOT NULL, FOREIGN KEY(path) REFERENCES sources(path))")
            (sqlite-execute db "CREATE INDEX IF NOT EXISTS targets_path ON targets(path)")
            (sqlite-execute db "CREATE INDEX IF NOT EXISTS targets_title ON targets(title)")
            (sqlite-execute db "CREATE VIRTUAL TABLE IF NOT EXISTS target_fts USING fts5(title, body, content='targets', content_rowid='rowid')")
            (sqlite-execute db "CREATE TRIGGER IF NOT EXISTS targets_ai AFTER INSERT ON targets BEGIN INSERT INTO target_fts(rowid,title,body) VALUES (new.rowid,new.title,new.body); END")
            (sqlite-execute db "CREATE TRIGGER IF NOT EXISTS targets_ad AFTER DELETE ON targets BEGIN INSERT INTO target_fts(target_fts,rowid,title,body) VALUES ('delete',old.rowid,old.title,old.body); END")
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
  (unless org-glean-roots (user-error "Configure org-glean-roots before reconciling"))
  (let ((owners (make-hash-table :test #'equal)) found)
    (dolist (spec org-glean-roots)
      (unless (and (listp spec) (= (length spec) 4)
                   (stringp (nth 0 spec)) (stringp (nth 1 spec))
                   (listp (nth 2 spec)) (listp (nth 3 spec)))
        (user-error "Invalid org-glean root specification: %S" spec))
      (pcase-let ((`(,name ,directory ,includes ,excludes) spec))
        (unless (file-directory-p directory)
          (user-error "Configured Org root does not exist: %s" directory))
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
           (records (list (list :key (concat path "#file") :kind "file"
                                :title title :body (or (org-glean--paragraphs
                                                       (org-glean--section tree)) "")
                                :position 1)))
           (ordinal 0))
      (org-element-map tree 'headline
        (lambda (h)
          (cl-incf ordinal)
          (push (list :key (format "%s@%s#heading:%d" path digest ordinal)
                      :kind "heading" :title (org-element-property :raw-value h)
                      :body (or (org-glean--paragraphs (org-glean--section h)) "")
                      :org-id (org-glean--heading-id h)
                      :position (org-element-property :begin h))
                records)))
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
          (sqlite-execute db "INSERT INTO targets(key,path,kind,title,body,org_id,position,digest) VALUES(?,?,?,?,?,?,?,?)"
                          (vector (plist-get record :key) path (plist-get record :kind)
                                  (plist-get record :title) (plist-get record :body)
                                  (plist-get record :org-id) (plist-get record :position) digest)))
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
         (found (org-glean--sources))
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
    (dolist (row (sqlite-select db "SELECT path FROM sources"))
      (unless (gethash (car row) seen)
        (sqlite-transaction db)
        (condition-case err
            (progn
              (sqlite-execute db "DELETE FROM targets WHERE path=?" (vector (car row)))
              (sqlite-execute db "DELETE FROM sources WHERE path=?" (vector (car row)))
              (sqlite-commit db)
              (cl-incf (plist-get counts :removed)))
          (error (sqlite-rollback db) (signal (car err) (cdr err))))))
    (when (called-interactively-p 'interactive) (message "org-glean: %S" counts))
    counts))

(defun org-glean--results (rows)
  "Turn ROWS into typed result property lists."
  (mapcar (lambda (row)
            (cl-mapcar #'cons '(:key :path :kind :title :org-id :position :digest :snippet)
                       (append row nil))) rows))

(defun org-glean-search-exact (title &optional limit)
  "Return at most LIMIT targets whose title exactly matches TITLE."
  (org-glean--results
   (sqlite-select (org-glean--db)
                  "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160) FROM targets WHERE title=? ORDER BY path,position LIMIT ?"
                  (vector title (max 1 (min 100 (or limit 20)))))))

(defun org-glean-search (query &optional limit)
  "Search FTS5 for QUERY, returning at most LIMIT results.
Treat each whitespace-separated input word as a quoted literal prefix."
  (let ((words (split-string (string-trim query) "[[:space:]]+" t)))
    (when words
      (let ((fts (mapconcat (lambda (word)
                              (concat "\"" (replace-regexp-in-string "\"" "\"\"" word t t) "\"*"))
                            words " AND ")))
        (org-glean--results
         (sqlite-select (org-glean--db)
                        "SELECT t.key,t.path,t.kind,t.title,t.org_id,t.position,t.digest,snippet(target_fts,1,'[',']','…',16) FROM target_fts JOIN targets t ON t.rowid=target_fts.rowid WHERE target_fts MATCH ? ORDER BY bm25(target_fts),t.path,t.position LIMIT ?"
                        (vector fts (max 1 (min 100 (or limit 20))))))))))

(defun org-glean-visit (result)
  "Visit RESULT if it still resolves unambiguously in the saved source."
  (let* ((id (alist-get :org-id result))
         (db (org-glean--db)))
    ;; Resolve explicit IDs afresh so a moved heading remains navigable, but
    ;; never guess if the configured roots contain duplicate IDs.
    (when id
      (let ((matches (sqlite-select db
                                    "SELECT key,path,kind,title,org_id,position,digest,substr(body,1,160) FROM targets WHERE org_id=? LIMIT 2"
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
        (user-error "Source has unsaved changes; save before navigating"))
      (let ((buffer (find-file-noselect path)))
        (with-current-buffer buffer
          (when (and buffer-file-name (not (verify-visited-file-modtime buffer)))
            (user-error "Visited buffer is stale; revert it before navigating"))
          (save-restriction
            (widen)
            (goto-char position)
            (when (and (equal (alist-get :kind result) "heading")
                       (or (not (org-at-heading-p))
                            (not (equal (alist-get :title result)
                                        (org-get-heading t t t t)))
                            (not (equal id (org-entry-get nil "ID")))))
              (user-error "Heading no longer matches the indexed target"))))
        (pop-to-buffer buffer)
        (goto-char position)))))

;;;###autoload
(defun org-glean-find (query)
  "Pick and visit a bounded FTS result for QUERY."
  (interactive "sSearch Org: ")
  (let* ((results (org-glean-search query))
         (choices (cl-loop for item in results for n from 1
                           collect (cons (format "%d. %s — %s (%s)" n
                                                 (alist-get :title item)
                                                 (file-name-nondirectory (alist-get :path item))
                                                 (alist-get :kind item)) item)))
         (choice (and choices (completing-read "Visit: " choices nil t))))
    (unless choice (user-error "No matches"))
    (org-glean-visit (cdr (assoc choice choices)))))

(provide 'org-glean)
;;; org-glean.el ends here
