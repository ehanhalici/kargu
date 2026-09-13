;;; kargu/config.el --- TOML config, provider, API key -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade module for the Kargu configuration subsystem.
;; Requires modular subcomponents under `kargu/config/`:
;;   * `kargu/config/toml'   -> pure Elisp TOML parser
;;   * `kargu/config/key'    -> multi-tier API key & endpoint resolution
;;   * `kargu/config/schema' -> configuration caching & setup verification
;;
;; Public API:
;;   `kargu-config-file', `kargu-edit-config', `kargu-set-provider', `kargu-check-setup'.

;;; Code:

;; Ensure the package root is on `load-path' during compilation.
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

(require 'kargu/config/toml)
(require 'kargu/config/key)
(require 'kargu/config/schema)

(provide 'kargu/config)

;;; kargu/config.el ends here
