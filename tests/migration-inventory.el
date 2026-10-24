;;; migration-inventory.el --- Read-only migration baseline exporter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Batch usage after package initialization: -L . -l this-file --funcall
;; kargu-migration-print-inventory.  Writes JSON to stdout, never session files.
;; The inventory includes definitions, not credentials or runtime arguments.

;;; Code:

(require 'kargu)
(require 'json)

(defun kargu-migration-print-inventory ()
  "Print the loaded package's source, command, schema and policy baseline."
  (let* ((root (file-name-directory (locate-library "kargu")))
         (sources (cons "kargu.el"
                        (mapcar (lambda (file) (file-relative-name file root))
                                (directory-files-recursively
                                 (expand-file-name "kargu" root) "\\.el\\'"))))
         functions commands tools)
    (mapatoms
     (lambda (symbol)
       (let ((name (symbol-name symbol)))
         (when (and (string-prefix-p "kargu-" name)
                    (not (string-match-p "--" name)) (fboundp symbol))
           (when-let* ((file (symbol-file symbol 'defun)))
             (when (file-in-directory-p file root)
               (push name functions)
               (when (commandp symbol) (push name commands))))))))
    (dolist (name (sort (kargu-registered-tools) #'string<))
      (let* ((definition (kargu-find-tool name))
             (canonical (kargu-tool-definition-name definition)))
        (push `((name . ,name) (canonical . ,canonical)
                (parameters . ,(kargu-tool-definition-parameters definition))
                (policy_lisp . ,(prin1-to-string (kargu-tool-definition-policy definition)))) tools)))
    (princ (json-encode
            `((schema_version . 1) (emacs_version . ,emacs-version)
              (session_schema_version . 2) (source_files . ,(vconcat (sort sources #'string<)))
              (loaded_public_functions . ,(vconcat (sort functions #'string<)))
              (loaded_public_commands . ,(vconcat (sort commands #'string<)))
              (tools . ,(vconcat (nreverse tools))))))
    (terpri)))

(provide 'tests/migration-inventory)
;;; migration-inventory.el ends here
