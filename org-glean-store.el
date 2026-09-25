;;; org-glean-store.el --- SQLite schema, migration and row (de)serialization -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-chunk)
(require 'sqlite)
(require 'json)

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
created before migration version 1; healthy opens do not rewrite the index.
Schema version 2 adds `chunks' and `vectors' for per-chunk, content-keyed
semantic materialization; it never touches `targets' or `sources'."
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
          (when (< version 2)
            ;; Chunks are content-owned by their source and rewritten wholesale
            ;; on every `org-glean--replace'. Vectors are keyed on (model,
            ;; text digest) alone, so they are never deleted by a source
            ;; replace/remove: an unchanged passage keeps its vector across
            ;; reprojection, a move, or even a full reconciliation rebuild.
            (sqlite-execute db "CREATE TABLE IF NOT EXISTS chunks (key TEXT PRIMARY KEY, target_key TEXT NOT NULL, path TEXT NOT NULL, ord INTEGER NOT NULL, text TEXT NOT NULL, text_digest TEXT NOT NULL, FOREIGN KEY(path) REFERENCES sources(path))")
            (sqlite-execute db "CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path)")
            (sqlite-execute db "CREATE INDEX IF NOT EXISTS chunks_target ON chunks(target_key)")
            (sqlite-execute db "CREATE INDEX IF NOT EXISTS chunks_digest ON chunks(text_digest)")
            (sqlite-execute db "CREATE TABLE IF NOT EXISTS vectors (model_id TEXT NOT NULL, text_digest TEXT NOT NULL, dim INTEGER NOT NULL, vector BLOB NOT NULL, PRIMARY KEY (model_id, text_digest))")
            (sqlite-execute db "PRAGMA user_version = 2"))
          (when (< version 3)
            ;; Version 2 created `chunks'/`vectors' but never populated chunks
            ;; for targets that already existed at migration time - only
            ;; `org-glean--replace' (added/changed sources) writes chunk rows,
            ;; and reconcile's unchanged-source skip means an already-indexed,
            ;; untouched source would otherwise never be chunked, ever,
            ;; leaving semantic search silently empty on any pre-existing
            ;; installation. Backfill chunks for every existing target
            ;; directly from the already-stored target rows (title/body/
            ;; outline-path), with no need to re-read or re-parse the
            ;; original Org files.
            (org-glean--backfill-chunks db)
            (sqlite-execute db "PRAGMA user_version = 3"))
          (sqlite-commit db)
          t)
      (error
       (sqlite-rollback db)
       (signal (car err) (cdr err))))))

(defun org-glean--backfill-chunks (db)
  "Populate `chunks' for every target in DB lacking one, grouped by source.
Reconstructs the record plists `org-glean--chunk-records' expects directly
from the `targets' table, so this never needs the original Org files."
  (let ((by-path (make-hash-table :test #'equal)))
    (dolist (row (sqlite-select
                  db "SELECT key,path,kind,title,body,org_id,position,digest,capture_policy,level,outline_path,properties FROM targets ORDER BY path,position"))
      (pcase-let ((`(,key ,path ,kind ,title ,body ,org-id ,position ,digest
                     ,capture-policy ,level ,outline-path ,properties)
                   (append row nil)))
        (push (list :key key :path path :kind kind :title title :body body
                   :org-id org-id :position position :digest digest
                   :capture-policy capture-policy :level level
                   :outline-path (and outline-path (not (string-empty-p outline-path))
                                     (split-string outline-path "\x1f" t))
                   :properties (org-glean--parse-properties properties))
              (gethash path by-path))))
    (maphash
     (lambda (path records)
       (let ((records (nreverse records)))
         (dolist (chunk (org-glean--chunk-records records))
           (sqlite-execute
            db "INSERT OR REPLACE INTO chunks(key,target_key,path,ord,text,text_digest) VALUES(?,?,?,?,?,?)"
            (vector (plist-get chunk :key) (plist-get chunk :target-key)
                    path (plist-get chunk :ord) (plist-get chunk :text)
                    (plist-get chunk :text-digest))))))
     by-path)))



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

(defun org-glean--replace (db path root digest records)
  "Atomically replace PATH owned by ROOT with DIGEST and RECORDS in DB.
Each record's chunk rows are rewritten too, via `org-glean--chunk-records'.
Chunk keys are per-target and are freely deleted and recreated; vectors are
keyed on content digest alone and are never touched here, so an unchanged
passage keeps its vector across this replacement."
  (sqlite-transaction db)
  (condition-case err
      (progn
        (sqlite-execute db "DELETE FROM targets WHERE path = ?" (vector path))
        (sqlite-execute db "DELETE FROM chunks WHERE path = ?" (vector path))
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
        (dolist (chunk (org-glean--chunk-records records))
          (sqlite-execute db "INSERT INTO chunks(key,target_key,path,ord,text,text_digest) VALUES(?,?,?,?,?,?)"
                          (vector (plist-get chunk :key) (plist-get chunk :target-key)
                                  path (plist-get chunk :ord) (plist-get chunk :text)
                                  (plist-get chunk :text-digest))))
        (unless (equal digest (org-glean--digest path))
          (error "Source changed before replacement committed"))
        (sqlite-commit db))
    (error (sqlite-rollback db) (signal (car err) (cdr err)))))

(defun org-glean--semantic-coverage (db model-id)
  "Return (COVERED . TOTAL) chunks with a vector for MODEL-ID in DB."
  (let ((total (or (caar (sqlite-select db "SELECT count(*) FROM chunks")) 0))
        (covered (or (caar (sqlite-select
                            db "SELECT count(*) FROM chunks c JOIN vectors v ON v.text_digest = c.text_digest AND v.model_id = ?"
                            (vector model-id)))
                     0)))
    (cons covered total)))

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

(provide 'org-glean-store)
;;; org-glean-store.el ends here
