;;; kargu/result.el --- Railway-Oriented Programming (Result / Either) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Result (Either) algebraic data type facade.
;; Forwarding to `kargu/contract/result'.

;;; Code:

;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory.
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

(require 'kargu/contract/result)

(provide 'kargu/result)

;;; kargu/result.el ends here
