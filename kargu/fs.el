;;; fs.el --- Bounded project file walks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Shared skip-directory table and a capped recursive file walk
;; used by `@' completion and other editor-side discovery consumers.
;; Requires: `kargu/core/group'.
;; Public: `kargu-fs-walk', `kargu-fs-skipped-path-p'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core/group)

(defcustom kargu-fs-skip-dirs
  '(".git" "node_modules" ".venv" "__pycache__" ".direnv" "dist"
    "build" "target" ".next" "vendor" "out" ".cache" ".cargo")
  "Directory names excluded at every depth by project walks and searches.
Remove a name such as build or vendor when it contains project sources.
This explicit filter also applies to the fallback without Git ignore support."
  :type '(repeat string)
  :group 'kargu)

(defcustom kargu-fs-max-listed-files 2000
  "Cap on files visited by a bounded walk."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-fs-max-visited-directories 2000
  "Maximum directories inspected by a single bounded file walk."
  :type 'natnum
  :group 'kargu)

(defun kargu-fs-skipped-path-p (path &optional root)
  "Return non-nil if PATH has a skipped directory below ROOT.
ROOT defaults to `default-directory'; ancestor directory names are ignored."
  (cl-some (lambda (part) (member part kargu-fs-skip-dirs))
           (split-string (or (file-name-directory
                              (file-relative-name (expand-file-name path) (or root default-directory))) "") "/" t)))

(defun kargu-fs-ignore-file-p (path)
  "Return non-nil if PATH is a compiled or backup artifact."
  (let ((name (file-name-nondirectory path)))
    (or (string-match-p "\\`\\.#" name)
        (string-match-p "~\\'" name)
        (string-match-p "\\.\\(elc\\|eln\\|o\\|so\\|pyc\\|class\\|rlib\\|rmeta\\)\\'"
                        name))))

(cl-defstruct (kargu-fs--walk (:constructor kargu-fs--make-walk))
  "Traversal resources and counters owned by one bounded file walk."
  root pending cap on-file (count 0) (directories 0) kept
  (seen (make-hash-table :test #'equal)))

(defun kargu-fs--contained-path (path root)
  "Return PATH's canonical name only if it remains within ROOT."
  (condition-case nil
      (let ((real (file-truename path)))
        (when (or (equal (directory-file-name real) (directory-file-name root))
                  (file-in-directory-p real root))
          real))
    (file-error nil)))

(defun kargu-fs--visit-entry (state path)
  "Visit a contained PATH under traversal STATE without following escapes."
  (when (and (< (kargu-fs--walk-count state) (kargu-fs--walk-cap state))
             (kargu-fs--contained-path path (kargu-fs--walk-root state)))
    (cond
     ((file-directory-p path)
      (unless (member (file-name-nondirectory path) kargu-fs-skip-dirs)
        (push path (kargu-fs--walk-pending state))))
     ((and (file-regular-p path) (not (kargu-fs-ignore-file-p path)))
      (cl-incf (kargu-fs--walk-count state))
      (when (or (null (kargu-fs--walk-on-file state))
                (funcall (kargu-fs--walk-on-file state) path))
        (push path (kargu-fs--walk-kept state)))))))

(defun kargu-fs--visit-directory (state path)
  "Inspect PATH once by canonical identity under traversal STATE."
  (when-let* ((real (kargu-fs--contained-path path (kargu-fs--walk-root state)))
              (real (directory-file-name real))
              ((not (gethash real (kargu-fs--walk-seen state)))))
    (puthash real t (kargu-fs--walk-seen state))
    (cl-incf (kargu-fs--walk-directories state))
    (dolist (entry (condition-case nil
                       (directory-files path t directory-files-no-dot-files-regexp)
                     (file-error nil)))
      (kargu-fs--visit-entry state entry))))

(defun kargu-fs-walk (dir &optional cap on-file)
  "Recursively visit files under DIR, at most CAP entries.
ON-FILE, if given, is called with each absolute file path and
should return non-nil to keep it.  Skip directories in
`kargu-fs-skip-dirs'.  CAP counts visited files, not matches.
Directory visits are separately capped by `kargu-fs-max-visited-directories'.
Resolve symlinks before entry, never leave DIR and never revisit a directory.
Return the list of kept paths without recursive Lisp calls."
  (let ((state (kargu-fs--make-walk
                :root (file-name-as-directory (file-truename dir))
                :pending (list (expand-file-name dir))
                :cap (or cap kargu-fs-max-listed-files) :on-file on-file)))
    (while (and (kargu-fs--walk-pending state)
                (< (kargu-fs--walk-count state) (kargu-fs--walk-cap state))
                (< (kargu-fs--walk-directories state) kargu-fs-max-visited-directories))
      (kargu-fs--visit-directory state (pop (kargu-fs--walk-pending state))))
    (nreverse (kargu-fs--walk-kept state))))

(defun kargu-fs-has-file-p (root filename)
  "Return non-nil if FILENAME exists under directory ROOT."
  (and (stringp root)
       (file-exists-p (expand-file-name filename root))))

(defun kargu-fs-has-extension-p (root extensions)
  "Find a file under ROOT with one of EXTENSIONS using a bounded walk.
Stop at the first match; honor the walk's skip and symlink policies."
  (save-match-data
    (catch 'kargu-fs-found
      (kargu-fs-walk
       root nil
       (lambda (file)
         (when (member (file-name-extension file) extensions)
           (throw 'kargu-fs-found t))
         nil))
      nil)))

(defun kargu-rel-path (path &optional root)
  "Return PATH relative to ROOT when it is inside ROOT.
ROOT defaults to project root or `default-directory'."
  (let* ((effective-root (or root
                             (and (fboundp 'kargu-permission-project-root)
                                  (kargu-permission-project-root))
                             default-directory))
         (rel (file-relative-name (expand-file-name path) effective-root)))
    (if (or (equal rel "..") (string-prefix-p "../" rel))
        (expand-file-name path)
      rel)))

(provide 'kargu/fs)

;;; fs.el ends here
