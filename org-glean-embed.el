;;; org-glean-embed.el --- Async client for the local embedding backend -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.
;;
;; Talks to semantic/org_glean_embed.py over stdio (see that file's module
;; docstring for the JSON Lines protocol). This client owns nothing about
;; Org content or freshness - it is a thin, restartable process wrapper: one
;; persistent subprocess, request/response correlation by id, and both an
;; asynchronous (callback) and synchronous (timeout) calling convention.
;; Emacs (org-glean-index.el's embedding queue, in a later commit) is the
;; only thing that decides what to embed and when.

;;; Code:

(require 'org-glean-core)
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defcustom org-glean-semantic-venv-dir
  (expand-file-name "org-glean" user-emacs-directory)
  "Directory holding the package-private Python environment and models.
Created by `org-glean-install'; never touches the user's own Python."
  :type 'directory
  :group 'org-glean)

(defcustom org-glean-semantic-timeout 30
  "Maximum seconds to wait for one synchronous embedding backend response."
  :type 'number
  :group 'org-glean)

(defvar org-glean--embed-process nil)
(defvar org-glean--embed-process-preset nil
  "Preset name the current `org-glean--embed-process' was started with.")
(defvar org-glean--embed-response-buffer ""
  "Unparsed tail of the backend's stdout, across process filter calls.")
(defvar org-glean--embed-callbacks nil
  "Alist of (ID . CALLBACK) for in-flight asynchronous requests.")
(defvar org-glean--embed-responses nil
  "Alist of (ID . RESPONSE) already received but not yet consumed by a
synchronous waiter.")
(defvar org-glean--embed-request-id 0)

(defun org-glean--embed-venv-python ()
  "Return the Python executable inside the managed venv, or nil if absent."
  (let ((candidate (expand-file-name "bin/python3" org-glean-semantic-venv-dir)))
    (when (file-executable-p candidate) candidate)))

(defun org-glean--embed-model-dir (preset)
  "Return the directory where PRESET's tokenizer/ONNX files are installed."
  (expand-file-name (format "models/%s" preset) org-glean-semantic-venv-dir))

(defun org-glean--embed-model-installed-p (preset)
  "Return non-nil if PRESET's model files are present in the managed venv."
  (let ((dir (org-glean--embed-model-dir preset)))
    (and (file-exists-p (expand-file-name "tokenizer.json" dir))
         (or (file-exists-p (expand-file-name "onnx/model.onnx" dir))
             (file-exists-p (expand-file-name "model.onnx" dir))))))

(defun org-glean-embed-available-p (&optional preset)
  "Return non-nil if a managed backend can serve PRESET (default the active
`org-glean-semantic-model') without downloading or installing anything.
Never starts a process or touches the network; purely a filesystem check."
  (let ((preset (or preset org-glean-semantic-model)))
    (and (org-glean--embed-venv-python)
         (org-glean--embed-model-installed-p preset))))

(defun org-glean--embed-script ()
  "Return the path to the embedding backend script."
  (expand-file-name "semantic/org_glean_embed.py" org-glean--package-directory))

(defun org-glean--embed-process-filter (_process chunk)
  "Collect newline-delimited JSON responses from the embedding backend CHUNK."
  (setq org-glean--embed-response-buffer
        (concat org-glean--embed-response-buffer chunk))
  (let ((newline (string-search "\n" org-glean--embed-response-buffer)))
    (while newline
      (let ((line (substring org-glean--embed-response-buffer 0 newline)))
        (setq org-glean--embed-response-buffer
              (substring org-glean--embed-response-buffer (1+ newline)))
        (condition-case nil
            (let* ((response (json-parse-string line :object-type 'alist :array-type 'array))
                   (id (alist-get 'id response))
                   (callback (alist-get id org-glean--embed-callbacks)))
              (if callback
                  (progn
                    (setq org-glean--embed-callbacks
                          (assq-delete-all id org-glean--embed-callbacks))
                    (funcall callback response))
                (push (cons id response) org-glean--embed-responses)))
          (error nil)))
      (setq newline (string-search "\n" org-glean--embed-response-buffer)))))

(defun org-glean--embed-process-sentinel (process _event)
  "Clear cached embedding backend state when PROCESS exits.
In-flight callbacks are notified with a synthetic error response rather than
left hanging forever; a future request restarts the process fresh."
  (unless (process-live-p process)
    (dolist (pair org-glean--embed-callbacks)
      (funcall (cdr pair)
               `((id . ,(car pair))
                 (error . ((type . "backend-exited") (message . "Embedding backend process exited"))))))
    (setq org-glean--embed-process nil
          org-glean--embed-process-preset nil
          org-glean--embed-callbacks nil
          org-glean--embed-response-buffer "")))

(defun org-glean--embed-start-process (preset)
  "Return the persistent embedding backend process for PRESET.
Restarts the process if PRESET differs from the currently running one, or
if it is not live. Signals if no managed Python/model is available; never
starts a process implicitly for a preset that has not been installed."
  (unless (org-glean-embed-available-p preset)
    (error "Semantic model %s is not installed; run M-x org-glean-install" preset))
  (unless (and (process-live-p org-glean--embed-process)
               (equal preset org-glean--embed-process-preset))
    (when (process-live-p org-glean--embed-process)
      (delete-process org-glean--embed-process))
    (setq org-glean--embed-response-buffer ""
          org-glean--embed-responses nil
          org-glean--embed-callbacks nil
          org-glean--embed-process
          (make-process :name (format "org-glean-embed-%s" preset)
                        :command (list (org-glean--embed-venv-python)
                                       (org-glean--embed-script) preset
                                       (org-glean--embed-model-dir preset))
                        :connection-type 'pipe :coding 'utf-8-unix :noquery t
                        :buffer nil
                        :filter #'org-glean--embed-process-filter
                        :sentinel #'org-glean--embed-process-sentinel)
          org-glean--embed-process-preset preset))
  org-glean--embed-process)

(defun org-glean-embed-stop ()
  "Stop the cached embedding backend process, if running."
  (interactive)
  (when (process-live-p org-glean--embed-process)
    (delete-process org-glean--embed-process))
  (setq org-glean--embed-process nil
        org-glean--embed-process-preset nil))

(defun org-glean--embed-request (op payload callback &optional preset)
  "Send one asynchronous backend OP with PAYLOAD, calling CALLBACK with the
raw parsed response (an alist with `result' or `error') when it arrives.
Never blocks; use `org-glean--embed-request-sync' for a blocking caller."
  (let* ((preset (or preset org-glean-semantic-model))
         (process (org-glean--embed-start-process preset))
         (id (cl-incf org-glean--embed-request-id)))
    (push (cons id callback) org-glean--embed-callbacks)
    (process-send-string
     process
     (concat (json-encode (append `((id . ,id) (op . ,op)) payload)) "\n"))
    id))

(defun org-glean--embed-request-sync (op payload &optional preset timeout)
  "Send one backend OP with PAYLOAD and block for its response.
Returns the response's `result' alist, or signals an error using its
`error' object's message. TIMEOUT defaults to `org-glean-semantic-timeout'."
  (let* ((preset (or preset org-glean-semantic-model))
         (process (org-glean--embed-start-process preset))
         (id (cl-incf org-glean--embed-request-id))
         (deadline (+ (float-time) (or timeout org-glean-semantic-timeout)))
         response)
    (process-send-string
     process
     (concat (json-encode (append `((id . ,id) (op . ,op)) payload)) "\n"))
    (while (and (null response) (process-live-p process) (< (float-time) deadline))
      (accept-process-output process 0.05)
      (setq response (alist-get id org-glean--embed-responses)))
    (unless response
      (error "Embedding backend timed out or exited"))
    (setq org-glean--embed-responses (assq-delete-all id org-glean--embed-responses))
    (let ((failure (alist-get 'error response)))
      (when failure
        (error "Embedding backend %s: %s"
               (alist-get 'type failure) (alist-get 'message failure))))
    (alist-get 'result response)))

;;; Installation

(defun org-glean--embed-presets ()
  "Return the parsed model preset table from semantic/presets.json.
The single source of truth for preset names/metadata; both the Python
backend and this Elisp orchestration read the same file, so they cannot
drift out of sync."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "semantic/presets.json" org-glean--package-directory))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(defun org-glean--embed-preset-info (preset)
  "Return PRESET's entry from `org-glean--embed-presets', or signal."
  (or (alist-get (intern preset) (org-glean--embed-presets))
      (error "Unknown semantic model preset: %s" preset)))

(defun org-glean--install-log (buffer format-string &rest args)
  "Append a formatted line to the install log BUFFER."
  (with-current-buffer buffer
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert (apply #'format format-string args)))))

(defun org-glean--install-run (buffer program args)
  "Run PROGRAM with ARGS synchronously, appending its output to BUFFER.
Signals if PROGRAM exits non-zero; the failing command's own output in
BUFFER is the diagnostic, so the error message just points at it."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (insert (format "$ %s %s\n" program (mapconcat #'identity args " ")))))
  (let* ((inhibit-read-only t)
         (code (apply #'call-process program nil buffer nil args)))
    (unless (eq code 0)
      (error "%s failed (exit %s); see buffer %s" program code (buffer-name buffer)))))

(defun org-glean--install-ensure-venv (buffer)
  "Create the managed venv and install its dependencies if not already done."
  (unless (executable-find "uv")
    (error "uv is required to install the semantic backend; see https://docs.astral.sh/uv/"))
  (unless (org-glean--embed-venv-python)
    (org-glean--install-log buffer "Creating venv at %s...\n" org-glean-semantic-venv-dir)
    (org-glean--install-run buffer "uv" (list "venv" org-glean-semantic-venv-dir)))
  (org-glean--install-log buffer "Installing backend dependencies...\n")
  (org-glean--install-run
   buffer "uv"
   (list "pip" "install" "--python" (org-glean--embed-venv-python)
         "-r" (expand-file-name "semantic/requirements.txt" org-glean--package-directory))))

(defun org-glean--install-download-model (buffer preset)
  "Download PRESET's tokenizer/ONNX files into its managed model directory.
The only network-touching step; only reached after `org-glean-install''s
explicit consent prompt."
  (let ((dir (org-glean--embed-model-dir preset)))
    (make-directory dir t)
    (org-glean--install-log buffer "Downloading %s model files into %s...\n" preset dir)
    (org-glean--install-run
     buffer (org-glean--embed-venv-python)
     (list (expand-file-name "semantic/org_glean_download.py" org-glean--package-directory)
           preset dir))))

(defun org-glean--install-self-test (preset)
  "Verify PRESET actually embeds meaningfully: a German/English paraphrase
of the same fact must outrank an unrelated distractor. Returns non-nil on
success. Restarts the backend process first, so a stale (e.g. fake-mode)
process from a prior session cannot mask a broken installation."
  (org-glean-embed-stop)
  (let* ((embedded (alist-get 'vectors
                              (org-glean--embed-request-sync
                               "embed" '((texts . ["Schweißnahtprüfung" "quarterly sales report"])
                                         (kind . "passage"))
                               preset 120)))
         (positive (aref embedded 0))
         (distractor (aref embedded 1)))
    (org-glean--embed-request-sync
     "load" `((items . (((digest . "org-glean-selftest-positive") (vector . ,positive))
                        ((digest . "org-glean-selftest-distractor") (vector . ,distractor)))))
     preset 60)
    (let ((results (alist-get 'results
                              (org-glean--embed-request-sync
                               "search" '((query . "weld inspection") (k . 1)) preset 60))))
      (and results
           (equal "org-glean-selftest-positive" (alist-get 'digest (aref results 0)))))))

(defun org-glean-install (&optional preset)
  "Install and verify a local semantic search backend for PRESET.
Interactively prompts for the preset (default `org-glean-semantic-model')
and, after showing its approximate download size, asks for one explicit
consent before any network access. Creates a package-private `uv' venv
under `org-glean-semantic-venv-dir', installs backend dependencies,
downloads the model's tokenizer/ONNX files, and runs a self-test that a
German/English paraphrase ranks above an unrelated distractor. Ordinary
search never reaches any of this implicitly."
  (interactive
   (list (completing-read "Install semantic model preset: "
                          (mapcar (lambda (pair) (symbol-name (car pair)))
                                  (org-glean--embed-presets))
                          nil t org-glean-semantic-model)))
  (let* ((preset (or preset org-glean-semantic-model))
         (info (org-glean--embed-preset-info preset))
         (size-mb (alist-get 'approx_size_mb info))
         (buffer (get-buffer-create "*Org Glean Install*")))
    (unless (yes-or-no-p
             (format "Download %s (~%s MB) from Hugging Face into %s? "
                     (alist-get 'model_id info) size-mb org-glean-semantic-venv-dir))
      (user-error "org-glean-install: cancelled, nothing downloaded"))
    (with-current-buffer buffer
      (erase-buffer)
      (special-mode))
    (org-glean--install-ensure-venv buffer)
    (org-glean--install-download-model buffer preset)
    (org-glean--install-log buffer "Running self-test...\n")
    (if (org-glean--install-self-test preset)
        (progn
          (org-glean--install-log buffer "Self-test passed: paraphrase ranked correctly.\n")
          (message "org-glean-install: %s installed and verified" preset)
          (run-hooks 'org-glean-install-hook))
      (org-glean--install-log buffer "Self-test FAILED: paraphrase did not outrank the distractor.\n")
      (pop-to-buffer buffer)
      (error "org-glean-install: self-test failed for %s; see buffer %s" preset (buffer-name buffer)))
    (pop-to-buffer buffer)))

(provide 'org-glean-embed)
;;; org-glean-embed.el ends here
