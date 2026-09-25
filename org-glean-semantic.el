;;; org-glean-semantic.el --- Background embedding queue -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.
;;
;; Chunks that lack a vector for the active model are "pending". An
;; idle-driven timer embeds them in bounded batches, asynchronously, so
;; ordinary editing is never blocked: the timer only fires once Emacs has
;; been idle, and each batch's embed request is itself asynchronous. Saves
;; and reconciliation make lexical/exact search current immediately (see
;; org-glean-index.el); this queue only ever catches semantic search up to
;; that same state in the background. See DESIGN.md and ROADMAP.md phase 1.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-store)
(require 'org-glean-embed)
(require 'cl-lib)

(defcustom org-glean-semantic-batch-size 32
  "Maximum chunks embedded per background queue batch."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-semantic-idle-delay 0.5
  "Idle seconds before the background embedding queue processes a batch."
  :type 'number
  :group 'org-glean)

(defvar org-glean--semantic-queue-timer nil)
(defvar org-glean--semantic-queue-state 'idle
  "One of `idle' (nothing pending or not installed), `running' (a batch is
in flight) or `paused' (stopped by `org-glean-semantic-pause').")
(defvar org-glean--semantic-queue-inflight nil
  "Non-nil while a batch's async embed request has not yet returned.
Prevents two overlapping batches from racing each other's SQLite writes.")

(defun org-glean--semantic-pending-chunks (db model-id limit)
  "Return up to LIMIT (text-digest . text) pairs lacking a MODEL-ID vector.
Distinct on text-digest: two chunks that happen to share identical content
(and therefore the same digest) are embedded once, not twice."
  (sqlite-select
   db "SELECT DISTINCT c.text_digest, c.text FROM chunks c WHERE NOT EXISTS (SELECT 1 FROM vectors v WHERE v.model_id = ? AND v.text_digest = c.text_digest) LIMIT ?"
   (vector model-id limit)))

(defun org-glean--semantic-store-vectors (db model-id digests vectors-b64)
  "Write MODEL-ID vectors for DIGESTS from base64-encoded VECTORS-B64.
Vectors are stored as raw BLOBs (Emacs sqlite treats a unibyte string
parameter as BLOB), one transaction per batch."
  (sqlite-transaction db)
  (condition-case err
      (progn
        (cl-loop for digest in digests
                 for vector-b64 across vectors-b64
                 do (let ((blob (base64-decode-string vector-b64)))
                      (sqlite-execute
                       db "INSERT OR REPLACE INTO vectors(model_id,text_digest,dim,vector) VALUES(?,?,?,?)"
                       (vector model-id digest (/ (length blob) 4) blob))))
        (sqlite-commit db))
    (error (sqlite-rollback db) (signal (car err) (cdr err)))))

(defun org-glean--semantic-queue-process-batch (&optional callback)
  "Embed one pending batch for the active model, asynchronously.
CALLBACK, when given, is called with the number of chunks embedded in this
batch (0 if none were pending, the backend is unavailable, or a batch is
already in flight). Never blocks Emacs: the embed request itself is
asynchronous, and this function returns immediately after sending it."
  (cond
   (org-glean--semantic-queue-inflight
    (when callback (funcall callback 0)))
   ((not (org-glean-embed-available-p org-glean-semantic-model))
    (setq org-glean--semantic-queue-state 'idle)
    (when callback (funcall callback 0)))
   (t
    (let* ((db (org-glean--db))
           (model org-glean-semantic-model)
           (pending (org-glean--semantic-pending-chunks db model org-glean-semantic-batch-size)))
      (if (null pending)
          (progn (setq org-glean--semantic-queue-state 'idle)
                 (when callback (funcall callback 0)))
        (setq org-glean--semantic-queue-inflight t
              org-glean--semantic-queue-state 'running)
        (let ((digests (mapcar #'car pending))
              (texts (vconcat (mapcar #'cadr pending))))
          (org-glean--embed-request
           "embed" `((texts . ,texts) (kind . "passage"))
           (lambda (response)
             (setq org-glean--semantic-queue-inflight nil)
             (condition-case err
                 (let ((failure (alist-get 'error response)))
                   (if failure
                       (progn
                         (setq org-glean--semantic-queue-state 'idle)
                         (push (cons "<semantic>"
                                    (format "%s: %s" (alist-get 'type failure)
                                            (alist-get 'message failure)))
                               org-glean--last-errors))
                     (let ((vectors (alist-get 'vectors (alist-get 'result response))))
                       (org-glean--semantic-store-vectors db model digests vectors)
                       ;; Keep the backend's in-memory scoring cache current so
                       ;; a query right after this batch sees these vectors
                       ;; without needing a separate warm-up reload.
                       (org-glean--embed-request
                        "load"
                        `((items . ,(vconcat (cl-mapcar (lambda (d v) `((digest . ,d) (vector . ,v)))
                                                        digests (append vectors nil)))))
                        (lambda (_response) nil)
                        model)))
                   (when callback (funcall callback (length digests))))
               (error
                (setq org-glean--semantic-queue-state 'idle)
                (push (cons "<semantic>" (error-message-string err)) org-glean--last-errors)
                (when callback (funcall callback 0))))))))))))

(defun org-glean--semantic-queue-tick ()
  "Idle-timer callback: process one batch if the queue is not paused."
  (unless (eq org-glean--semantic-queue-state 'paused)
    (org-glean--semantic-queue-process-batch)))

(defun org-glean-semantic-queue-start ()
  "Ensure the background embedding queue's idle timer is running.
A no-op if already running, paused, or no semantic backend is installed for
the active model; called automatically after reconciliation and save
updates, and after a successful `org-glean-install'."
  (interactive)
  (when (and (not (eq org-glean--semantic-queue-state 'paused))
             (org-glean-embed-available-p org-glean-semantic-model)
             (not (timerp org-glean--semantic-queue-timer)))
    (setq org-glean--semantic-queue-timer
          (run-with-idle-timer org-glean-semantic-idle-delay t
                               #'org-glean--semantic-queue-tick))))

(defun org-glean-semantic-pause ()
  "Stop the background embedding queue until `org-glean-semantic-resume'."
  (interactive)
  (setq org-glean--semantic-queue-state 'paused)
  (when (timerp org-glean--semantic-queue-timer)
    (cancel-timer org-glean--semantic-queue-timer))
  (setq org-glean--semantic-queue-timer nil))

(defun org-glean-semantic-resume ()
  "Resume the background embedding queue after `org-glean-semantic-pause'."
  (interactive)
  (setq org-glean--semantic-queue-state 'idle)
  (org-glean-semantic-queue-start))

(add-hook 'org-glean-install-hook #'org-glean-semantic-queue-start)

(provide 'org-glean-semantic)
;;; org-glean-semantic.el ends here
