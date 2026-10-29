;;; read.el --- Bounded asynchronous native edit reads -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Complete metadata and text pages before entering an issued editor handler.

;;; Code:

(require 'seq)
(require 'kargu/bridge/edit/patch)
(require 'kargu/bridge/edit/document)

(defun kargu-bridge-edit-batch-read-files (artifact callback)
  "Read every immutable file view of ARTIFACT into CALLBACK."
  (if (not (eq (gethash "batch" (kargu-bridge-edit-artifact-descriptor artifact)) t))
      (funcall callback (list (kargu-bridge-edit-artifact-descriptor artifact)) nil)
    (cl-labels ((page (offset reversed)
                  (kargu-bridge-edit-patch-files
                   artifact offset
                   (lambda (value failure)
                     (if failure (funcall callback nil failure)
                       (let ((next (gethash "next_offset" value)))
                         (seq-doseq (file (gethash "files" value)) (push file reversed))
                         (cond
                          ((eq (gethash "complete" value) t)
                           (funcall callback (nreverse reversed) nil))
                          ((and (integerp next) (> next offset)) (page next reversed))
                          (t (funcall callback nil "Invalid native file cursor")))))))))
      (page 0 nil))))

(cl-defun kargu-bridge-edit-batch-read-text (artifact &key file part callback)
  "Read ARTIFACT's FILE and PART asynchronously into CALLBACK."
  (let ((batch (eq (gethash "batch" (kargu-bridge-edit-artifact-descriptor artifact)) t)))
    (cl-labels ((page (offset reversed)
                  (let ((receive
                         (lambda (value failure)
                           (if failure (funcall callback nil failure)
                             (let ((next (gethash "next_offset" value)))
                               (push (gethash "text" value) reversed)
                               (cond
                                ((eq (gethash "complete" value) t)
                                 (funcall callback (apply #'concat (nreverse reversed)) nil))
                                ((and (integerp next) (> next offset)) (page next reversed))
                                (t (funcall callback nil "Invalid native text cursor"))))))))
                    (if batch
                        (kargu-bridge-edit-patch-text artifact file part :offset offset :callback receive)
                      (kargu-bridge-edit-read artifact part offset receive)))))
      (page 0 nil))))

(defun kargu-bridge-edit-batch-read-document (path)
  "Observe local PATH in a visiting buffer without evaluating file variables."
  (when (file-remote-p path) (error "Native edits require a local file"))
  (let* ((enable-local-eval nil) (enable-local-variables nil)
         (enable-dir-local-variables nil)
         (buffer (or (find-buffer-visiting path) (find-file-noselect path))))
    (with-current-buffer buffer
      (unless (verify-visited-file-modtime buffer)
        (error "Visited file changed on disk: %s" path)))
    (kargu-bridge-edit-document-capture buffer)))

(defun kargu-bridge-edit-batch-read-proposals (artifact callback)
  "Load all frozen ARTIFACT views and text bodies into CALLBACK."
  (kargu-bridge-edit-batch-read-files
   artifact
   (lambda (views failure)
     (if failure (funcall callback nil failure)
       (cl-labels ((next (remaining index reversed)
                     (if (null remaining) (funcall callback (nreverse reversed) nil)
                       (let ((view (car remaining)))
                         (kargu-bridge-edit-batch-read-text
                          artifact :file index :part "base"
                          :callback
                          (lambda (base fault)
                            (if fault (funcall callback nil fault)
                              (kargu-bridge-edit-batch-read-text
                               artifact :file index :part "proposed"
                               :callback
                               (lambda (proposed error-data)
                                 (if error-data (funcall callback nil error-data)
                                   (next (cdr remaining) (1+ index)
                                         (cons (list :view view :base base :proposed proposed :document nil)
                                               reversed))))))))))))
         (next views 0 nil))))))

(provide 'kargu/bridge/edit/batch/read)
;;; read.el ends here
