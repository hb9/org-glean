;;; org-glean-chunk.el --- Org-aware chunking for semantic passages -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.
;;
;; Turns a source's projected records into embeddable passage chunks. A
;; passage always carries enough Org context (outline path, file title) that
;; it stands on its own for an embedding model; a long body is split into
;; overlapping windows so nothing is silently truncated by the model's
;; context length. See DESIGN.md for the chunking rationale and ROADMAP.md
;; phase 1 for what is intentionally deferred (token-accurate windowing).

;;; Code:

(require 'org-glean-core)
(require 'cl-lib)
(require 'subr-x)

(defcustom org-glean-chunk-max-chars 1500
  "Approximate maximum characters of body text per chunk window.
This is a character estimate, not a token count; the embedding backend
reports actual truncation against the model's token limit (see
ROADMAP.md phase 1)."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-chunk-overlap-chars 300
  "Approximate characters of trailing context repeated into the next window."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-chunk-file-outline-depth 2
  "Maximum heading level summarized in a source's file-level chunk."
  :type 'integer
  :group 'org-glean)

(defcustom org-glean-chunk-min-words 6
  "Minimum real words a chunk's passage must have after noise is stripped.
A chunk below this threshold is not embedded at all: measured on a real
corpus, about 13% of chunks were bare URL lists, Org log-book lines
(\"State \\\"DONE\\\" from ... [timestamp]\"), or hour tables with no
retrievable meaning, and they still consumed semantic search result slots
indistinguishable from real content. Lexical search is unaffected: it
indexes `targets', not `chunks', and still returns everything.
A \"real word\" is 3+ letters (rough but locale-tolerant with `chunk-max-chars')."
  :type 'integer
  :group 'org-glean)

(defun org-glean--chunk-strip-noise (text)
  "Remove URLs, Org log-book lines and bare timestamps from TEXT.
This only affects what gets embedded; the stored target body (and hence
lexical/exact search) is untouched. These forms carry near-zero semantic
meaning but are common enough in real Org files (link-only headings, time
logs) to otherwise dominate a chunk's content and its resulting vector."
  (let ((text (or text "")))
    (setq text (replace-regexp-in-string "https?://[^ \t\n]+" "" text))
    (setq text (replace-regexp-in-string
               "State \"[A-Za-z]+\"\\( +from +\"[A-Za-z]*\"\\)? *\\(\\[[^]]*\\]\\)?" "" text))
    (setq text (replace-regexp-in-string "\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^]]*\\]" "" text))
    (string-trim text)))

(defun org-glean--chunk-word-count (text)
  "Return the number of 3+ letter words in TEXT."
  (length (seq-filter (lambda (w) (>= (length w) 3))
                      (split-string text "[^[:alpha:]]+" t))))

(defun org-glean--chunk-digest (text)
  "Return the content digest for chunk TEXT, keying its vector cache entry."
  (secure-hash 'sha256 (encode-coding-string (string-trim text) 'utf-8)))

(defun org-glean--chunk-paragraphs (text)
  "Split TEXT into non-empty paragraphs on blank lines."
  (cl-remove-if #'string-empty-p
                (mapcar #'string-trim (split-string (or text "") "\n[ \t]*\n"))))

(defun org-glean--chunk-windows (text)
  "Split TEXT into overlapping windows of roughly `org-glean-chunk-max-chars'.
Windows are assembled from whole paragraphs, so a window never splits a
paragraph mid-sentence. A short TEXT returns a single window. Trailing
paragraphs from a window are repeated at the start of the next window up to
`org-glean-chunk-overlap-chars', so a fact near a window boundary is not
invisible to whichever window's query happens to match its neighbourhood."
  (let ((paragraphs (org-glean--chunk-paragraphs text)))
    (if (null paragraphs)
        nil
      (let ((windows nil) (current nil) (current-len 0))
        (dolist (paragraph paragraphs)
          (push paragraph current)
          (cl-incf current-len (1+ (length paragraph)))
          (when (>= current-len org-glean-chunk-max-chars)
            (push (string-join (nreverse current) "\n\n") windows)
            ;; Seed the next window with trailing paragraphs from this one so
            ;; content near the cut is not siloed into only one window.
            (let ((overlap nil) (overlap-len 0) (rest (reverse current)))
              (while (and rest (< overlap-len org-glean-chunk-overlap-chars))
                (push (car rest) overlap)
                (cl-incf overlap-len (1+ (length (car rest))))
                (setq rest (cdr rest)))
              (setq current overlap
                    current-len overlap-len))))
        (when current
          (push (string-join (nreverse current) "\n\n") windows))
        (nreverse windows)))))

(defun org-glean--chunk-context-line (record)
  "Return the one-line Org context header for RECORD.
A heading's context is its outline path joined with \" > \"; a file's
context is just its title. This line is prepended to every window so a
chunk is self-describing to an embedding model even without its neighbours."
  (if (equal (plist-get record :kind) "file")
      (plist-get record :title)
    (string-join (append (plist-get record :outline-path)
                          (unless (plist-get record :outline-path)
                            (list (plist-get record :title))))
                 " > ")))

(defun org-glean--chunk-file-outline (records)
  "Return a short heading-title summary of RECORDS for the file-level passage.
Only headings at `org-glean-chunk-file-outline-depth' or shallower are
included, so the file passage stays a compact orientation aid rather than a
duplicate of every heading's own passage."
  (string-join
   (delq nil
         (mapcar (lambda (record)
                   (when (and (equal (plist-get record :kind) "heading")
                              (<= (or (plist-get record :level) 0)
                                  org-glean-chunk-file-outline-depth))
                     (plist-get record :title)))
                 records))
   "\n"))

(defun org-glean--chunk-record-text (record records)
  "Return the full un-windowed passage text for RECORD among sibling RECORDS.
Body text has URLs, log-book lines and bare timestamps stripped (see
`org-glean--chunk-strip-noise'); if what remains is too short to be
retrievable on its own, a heading's file title is folded in as extra
context (see `org-glean-chunk-min-words')."
  (let ((body (org-glean--chunk-strip-noise (plist-get record :body))))
    (if (equal (plist-get record :kind) "file")
        (string-join
         (delq nil (list (plist-get record :title)
                         (org-glean--chunk-file-outline records)
                         body))
         "\n")
      (let* ((context (org-glean--chunk-context-line record))
             (words (org-glean--chunk-word-count (concat context " " body)))
             (file-title (and (< words org-glean-chunk-min-words)
                              (plist-get
                               (cl-find "file" records
                                        :key (lambda (r) (plist-get r :kind)) :test #'equal)
                               :title))))
        (string-join (delq nil (list file-title context body)) "\n\n")))))

(defun org-glean--chunk-record (record records)
  "Return a list of chunk plists (:ord :text :text-digest) for RECORD.
RECORDS are RECORD's siblings from the same source, used to build the
file-level record's outline summary. A record with no retrievable text
(after trimming) yields no chunks at all, rather than an empty-passage
vector that would only ever score as noise. Likewise, a record whose
noise-stripped text falls below `org-glean-chunk-min-words' yields no
chunks: it is still fully lexically searchable via `targets', it just
never becomes a semantic search candidate."
  (let* ((text (org-glean--chunk-record-text record records))
         (windows (org-glean--chunk-windows text)))
    (cl-loop for window in windows
             for ord from 0
             when (>= (org-glean--chunk-word-count window) org-glean-chunk-min-words)
             collect (list :ord ord :text window
                           :text-digest (org-glean--chunk-digest window)))))

(defun org-glean--chunk-records (records)
  "Return a flat list of chunk plists (:key :target-key :ord :text :text-digest)
for every record in RECORDS."
  (cl-mapcan
   (lambda (record)
     (mapcar (lambda (chunk)
               (list :key (format "%s#chunk:%d" (plist-get record :key) (plist-get chunk :ord))
                     :target-key (plist-get record :key)
                     :ord (plist-get chunk :ord)
                     :text (plist-get chunk :text)
                     :text-digest (plist-get chunk :text-digest)))
             (org-glean--chunk-record record records)))
   records))

(provide 'org-glean-chunk)
;;; org-glean-chunk.el ends here
