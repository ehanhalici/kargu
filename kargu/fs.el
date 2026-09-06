;;; kargu/fs.el --- Bounded project file walks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Shared skip-directory table and a capped recursive file walk
;; used by `@' completion and the Elisp glob fallback.
;; Requires: `kargu/core'.
;; Public: `kargu-fs-walk', `kargu-fs-skipped-path-p'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
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

(require 'kargu/core)

(defconst kargu-fs-skip-dirs
  '(".git" "node_modules" ".venv" "__pycache__" ".direnv" "dist"
    "build" "target" ".next" "vendor" "out" ".cache" ".cargo"
    "opencode-1.18.27")
  "Directory names skipped while walking a project tree.")

(defcustom kargu-fs-max-listed-files 2000
  "Cap on files visited by a bounded walk."
  :type 'natnum
  :group 'kargu)

(defun kargu-fs-skipped-path-p (path)
  "Non-nil if PATH has a skipped directory component."
  (cl-some (lambda (part) (member part kargu-fs-skip-dirs))
           (split-string (expand-file-name path) "/" t)))

(defun kargu-fs-ignore-file-p (path)
  "Return non-nil if PATH is a compiled or backup artifact."
  (let ((name (file-name-nondirectory path)))
    (or (string-match-p "\\`\\.#" name)
        (string-match-p "~\\'" name)
        (string-match-p "\\.\\(elc\\|eln\\|o\\|so\\|pyc\\|class\\|rlib\\|rmeta\\)\\'"
                        name))))

(defun kargu-fs-walk (dir &optional cap on-file)
  "Recursively visit files under DIR, at most CAP entries.
ON-FILE, if given, is called with each absolute file path and
should return non-nil to keep it.  Skip directories in
`kargu-fs-skip-dirs'.  CAP counts visited files, not matches.
Return the list of kept paths."
  (let ((acc nil)
        (n 0)
        (cap (or cap kargu-fs-max-listed-files)))
    (cl-labels
        ((walk (d)
           (when (< n cap)
             (dolist (f (ignore-errors
                          (directory-files d t directory-files-no-dot-files-regexp t)))
               (when (< n cap)
                 (let ((name (file-name-nondirectory f)))
                   (cond
                    ((and (file-directory-p f)
                          (not (member name kargu-fs-skip-dirs)))
                     (walk f))
                    ((and (not (file-directory-p f))
                          (not (kargu-fs-ignore-file-p f)))
                     (setq n (1+ n))
                     (when (or (null on-file) (funcall on-file f))
                       (push (expand-file-name f) acc))))))))))
      (walk dir))
    acc))

(provide 'kargu/fs)

;;; kargu/fs.el ends here
