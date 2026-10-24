;;; catalog.el --- Rust-owned provider catalog projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Synchronous startup reads the same manifest embedded by Rust.  Once the core
;; connects its validated snapshot replaces this credential-free UI projection.

;;; Code:

(require 'kargu/providers/projection)

(let ((manifest (expand-file-name
                 "../../kargu-core/assets/providers.json"
                 (file-name-directory (or load-file-name buffer-file-name)))))
  (unless (and (file-regular-p manifest)
               (<= (file-attribute-size (file-attributes manifest)) (* 512 1024)))
    (error "Missing or oversized Rust provider manifest"))
  (with-temp-buffer
    (insert-file-contents manifest)
    (kargu-providers-install-projection
     (json-parse-buffer :object-type 'hash-table :array-type 'array
                        :null-object :json-null :false-object :json-false))))

(provide 'kargu/providers/catalog)
;;; catalog.el ends here
