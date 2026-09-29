;;; kargu/languages.el --- Modular language support loader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

(require 'kargu/languages/core)
(require 'kargu/languages/rust)
(require 'kargu/languages/c)
(require 'kargu/languages/cpp)
(require 'kargu/languages/golang)
(require 'kargu/languages/python)
(require 'kargu/languages/java)
(require 'kargu/languages/haskell)
(require 'kargu/languages/ocaml)
(require 'kargu/languages/javascript)
(require 'kargu/languages/typescript)
(require 'kargu/languages/elisp)

(provide 'kargu/languages)

;;; kargu/languages.el ends here
