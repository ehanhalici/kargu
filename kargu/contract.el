;;; kargu/contract.el --- Ingress contract validation and invariants -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Contract-driven ingress validation engine.
;; Facade module requiring the contract submodules under `kargu/contract/`.

;;; Code:

;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/contract/constants)
(require 'kargu/contract/result)
(require 'kargu/contract/types)
(require 'kargu/contract/assert)

(provide 'kargu/contract)

;;; kargu/contract.el ends here
