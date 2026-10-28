;;; patch.el --- Native patch inspection and document transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Rust parses targets and applies Git in its private workspace.  The editor
;; supplies only explicitly named live captures; every port remains read-only.

;;; Code:

(require 'kargu/bridge/edit)

(defconst kargu-bridge-edit-patch--document-prefix "document:"
  "Native named-document upload part prefix.")
(defconst kargu-bridge-edit-patch--document-pattern
  (rx string-start "document:" digit (opt digit) (opt digit) string-end)
  "Bounded native document part spelling.")

(cl-defun kargu-bridge-edit-patch-inspect (application arguments text &key callback parent valid-p)
  "Inspect detached patch TEXT and ARGUMENTS for APPLICATION into CALLBACK.
PARENT and VALID-P guard source lifetime.  CALLBACK receives (ARTIFACT FAILURE).
The returned read-only handle must be explicitly released after use."
  (kargu-bridge-edit--start application arguments (list (cons "patch" text))
                            :callback callback :parent parent :valid-p valid-p :action :inspect))

(cl-defun kargu-bridge-edit-patch--read (artifact method arguments &key callback)
  "Read METHOD/ARGUMENTS on exact ARTIFACT into CALLBACK.
Never acquire a replacement lease."
  (if (not (kargu-bridge-edit--current-p artifact))
      (funcall callback nil (kargu-bridge--fault "stale_edit_preparation"))
    (kargu-bridge-edit--call
     artifact method arguments
     (lambda (value failure)
       (if (not (kargu-bridge-edit--current-p artifact))
           (funcall callback nil (kargu-bridge--fault "stale_edit_preparation"))
         (funcall callback value failure))))))

(defun kargu-bridge-edit-patch-targets (artifact offset callback)
  "Read one native target page for inspected ARTIFACT at OFFSET into CALLBACK."
  (let ((arguments (kargu-bridge-edit--arguments artifact)))
    (puthash "offset" offset arguments)
    (kargu-bridge-edit-patch--read artifact :targets arguments :callback callback)))

(cl-defun kargu-bridge-edit-patch-document (artifact path document &key text callback parent valid-p)
  "Attach decoded TEXT and DOCUMENT evidence at named PATH to ARTIFACT.
CALLBACK receives (ARTIFACT FAILURE) after all upload ACKs.
PARENT and VALID-P guard the captured source.  Failure revokes the patch handle."
  (let* ((transfer (kargu-bridge-edit--transfer artifact callback :parent parent :valid-p valid-p :action :document))
         (task (kargu-bridge-edit-transfer-task transfer)))
    (condition-case nil
        (let ((arguments (kargu-bridge-edit--arguments artifact)))
          (puthash "path" (copy-sequence path) arguments)
          (puthash "document" (kargu-bridge-edit--copy document) arguments)
          (kargu-bridge-edit--detach transfer (list (cons "document" text)))
          (if (not (kargu-bridge-edit--live-p transfer))
              (kargu-bridge-edit--fail transfer (kargu-bridge--fault "stale_edit_preparation"))
            (kargu-bridge-edit--call
             artifact :document arguments
             (kargu-bridge-edit--guard
              transfer (lambda (value)
                         (let ((part (and (hash-table-p value) (gethash "part" value))))
                           (unless (and (stringp part) (string-match-p kargu-bridge-edit-patch--document-pattern part)
                                        (<= 0 (string-to-number (string-remove-prefix kargu-bridge-edit-patch--document-prefix part)) (1- kargu-bridge-edit--file-count)))
                             (error "Invalid document part"))
                           (setcar (car (kargu-bridge-edit-transfer-parts transfer)) (copy-sequence part))
                           (kargu-bridge-edit--pump transfer)))))))
      ((error quit) (kargu-bridge-edit--fail transfer (kargu-bridge--fault "invalid_edit_document"))))
    task))

(cl-defun kargu-bridge-edit-patch-prepare (artifact callback &key parent valid-p)
  "Prepare ARTIFACT with supervised native Git and deliver CALLBACK.
PARENT and VALID-P guard captured source/document ownership.
All previously declared live documents must have completed upload."
  (let ((transfer (kargu-bridge-edit--transfer artifact callback :parent parent :valid-p valid-p)))
    (kargu-bridge-edit--pump transfer)
    (kargu-bridge-edit-transfer-task transfer)))

(defun kargu-bridge-edit-patch-files (artifact offset callback)
  "Read one immutable file page of ARTIFACT at OFFSET into CALLBACK."
  (let ((arguments (kargu-bridge-edit--arguments artifact)))
    (puthash "offset" offset arguments)
    (kargu-bridge-edit-patch--read artifact :files arguments :callback callback)))

(cl-defun kargu-bridge-edit-patch-text (artifact file part &key offset callback)
  "Read ARTIFACT FILE's base/proposed PART at byte OFFSET into CALLBACK."
  (let ((arguments (kargu-bridge-edit--arguments artifact)))
    (puthash "file" file arguments) (puthash "part" part arguments) (puthash "offset" offset arguments)
    (kargu-bridge-edit-patch--read artifact :read arguments :callback callback)))

(provide 'kargu/bridge/edit/patch)
;;; patch.el ends here
