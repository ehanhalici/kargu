;;; kargu/history.el --- Conversation history and protocol firewall -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade module for Kargu conversation history and protocol firewall.
;; Requires modular subcomponents under `kargu/history/`:
;;   * `kargu/history/protocol' -> OpenAI-shaped message queue & role helpers
;;   * `kargu/history/repair'   -> protocol firewall invariant validation
;;   * `kargu/history/compact'  -> token threshold & history compaction
;;
;; Public API:
;;   `kargu-history-add', `kargu-history-add-tool-result',
;;   `kargu-history-validate', `kargu-history-reset', `kargu-history-inspect',
;;   `kargu-history-compact-threshold', `kargu-history-char-count'.

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

(require 'kargu/history/protocol)
(require 'kargu/history/repair)
(require 'kargu/history/compact)

(provide 'kargu/history)

;;; kargu/history.el ends here
