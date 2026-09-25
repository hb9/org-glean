;;; org-glean-index.el --- Discovery, reconciliation and save-triggered updates -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-store)
(require 'org-glean-project)
(require 'org-glean-semantic)
(require 'cl-lib)

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
              (sqlite-execute db "DELETE FROM chunks WHERE path=?" (vector (car row)))
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
    (org-glean-semantic-queue-start)
    counts))

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
        (org-glean-semantic-queue-start)
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
              (sqlite-execute db "DELETE FROM chunks WHERE path=?" (vector path))
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
         (coverage (when database-available
                     (org-glean--semantic-coverage (org-glean--db) org-glean-semantic-model)))
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
                       :semantic-state (cond
                                        ((not org-glean-semantic-provider) 'unavailable)
                                        ((org-glean-embed-available-p org-glean-semantic-model) 'ready)
                                        (t 'not-installed))
                       :semantic-model org-glean-semantic-model
                       :semantic-coverage-chunks (car coverage)
                       :semantic-coverage-total (cdr coverage)
                       :semantic-queue-state org-glean--semantic-queue-state
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

(provide 'org-glean-index)
;;; org-glean-index.el ends here
