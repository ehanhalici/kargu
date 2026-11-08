;;; fs.el --- Shared discovery settings sent to Rust -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; User preferences for directory exclusions and discovery limits.  Rust's
;; native discovery applies them; Emacs never walks the project itself.
;; Requires: `kargu/core/group'.
;; Public: `kargu-fs-skip-dirs', `kargu-fs-max-listed-files',
;; `kargu-fs-max-visited-directories'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core/group)

(defcustom kargu-fs-skip-dirs
  '(".git" "node_modules" ".venv" "__pycache__" ".direnv" "dist"
    "build" "target" ".next" "vendor" "out" ".cache" ".cargo")
  "Directory names excluded at every depth by native discovery and searches.
Remove a name such as build or vendor when it contains project sources."
  :type '(repeat string)
  :group 'kargu)

(defcustom kargu-fs-max-listed-files 2000
  "Cap on files visited by one native discovery request."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-fs-max-visited-directories 2000
  "Maximum directories inspected by one native discovery request."
  :type 'natnum
  :group 'kargu)

(provide 'kargu/fs)

;;; fs.el ends here
