;;; kargu/tools/toolchain.el --- Strategy pattern for project toolchains -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Toolchain lookup for a project root.  The language profiles under
;; `kargu/languages/' carry the build and test commands; this file only
;; resolves them and lets a user register a strategy for anything else.
;; Public: `kargu-toolchain-strategy', `kargu-toolchain-register',
;; `kargu-toolchain-detect'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'kargu/fs)
(require 'kargu/languages)

;;;; Strategy definition --------------------------------------------------

(cl-defstruct (kargu-toolchain-strategy (:constructor kargu-make-toolchain-strategy))
  "Strategy object encapsulating detection and commands for one language toolchain."
  name
  priority
  detector
  resolver)

(defvar kargu-toolchain-strategies nil
  "List of registered `kargu-toolchain-strategy' objects, ordered by priority.")

(defun kargu-toolchain-register (strategy)
  "Register a STRATEGY in `kargu-toolchain-strategies', maintaining priority order."
  (when (or (functionp (kargu-toolchain-strategy-detector strategy))
            (functionp (kargu-toolchain-strategy-resolver strategy)))
    (user-error "Native toolchains require declarative detectors and command plists"))
  (setq kargu-toolchain-strategies
        (cl-remove (kargu-toolchain-strategy-name strategy)
                   kargu-toolchain-strategies
                   :key #'kargu-toolchain-strategy-name
                   :test #'equal))
  (push strategy kargu-toolchain-strategies)
  (setq kargu-toolchain-strategies
        (sort kargu-toolchain-strategies
              (lambda (a b)
                (> (or (kargu-toolchain-strategy-priority a) 0)
                   (or (kargu-toolchain-strategy-priority b) 0)))))
  strategy)

(defun kargu-toolchain-detect (root)
  "Detect the primary toolchain for ROOT.
The language profile of ROOT answers first.  Strategies registered with
`kargu-toolchain-register' cover projects no language profile claims."
  (when-let* ((view (kargu-project-probe-view root))
              (id (gethash "language" view)) ((stringp id))
              (commands (kargu-project-probe-toolchain id root)))
    (append (list :language (gethash "language_name" view)) commands)))

(provide 'kargu/tools/toolchain)

;;; toolchain.el ends here
