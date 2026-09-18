;;; kargu/languages.el --- Modular language support loader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

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

(require 'kargu/languages/core)
(require 'kargu/languages/rust)
(require 'kargu/languages/c)
(require 'kargu/languages/cpp)
(require 'kargu/languages/golang)
(require 'kargu/languages/python)
(require 'kargu/languages/java)
(require 'kargu/languages/haskell)
(require 'kargu/languages/ocaml)

(provide 'kargu/languages)

;;; kargu/languages.el ends here
