;;; org-glean-project.el --- org-element projection of one saved file -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of org-glean; loaded via org-glean.el. Not intended to be required
;; directly by other packages.

;;; Code:

(require 'org-glean-core)
(require 'org-glean-store)
(require 'org)
(require 'org-element)
(require 'cl-lib)

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
                                 :level 0 :outline-path nil
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

(provide 'org-glean-project)
;;; org-glean-project.el ends here
