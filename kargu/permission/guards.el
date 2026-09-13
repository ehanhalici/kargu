;;; kargu/permission/guards.el --- Project boundary guards -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Path-based permission and sandboxing guards.
;; Ensures all file reads, writes, and searches are strictly confined to project root.

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

(defgroup kargu-permission nil
  "Permission and sandbox rules for Kargu tools."
  :group 'kargu
  :prefix "kargu-permission-")

(defcustom kargu-permission-strict-mode t
  "When non-nil, strictly enforce project root boundaries for tools."
  :type 'boolean
  :group 'kargu-permission)

(defcustom kargu-permission-confirm-bash t
  "When non-nil, prompt for confirmation before running a bash command."
  :type 'boolean
  :group 'kargu-permission)

(defvar kargu-permission--override-root nil
  "Internal dynamically bound root used during testing or explicit overrides.")

(defvar kargu-permission--mock-decision nil
  "Dynamically bound decision (:approve | :reject) used for unit testing.")

(defconst kargu-permission-allowed-devices
  '("/dev/null" "/dev/zero" "/dev/stdout" "/dev/stderr" "/dev/stdin" "/dev/tty")
  "Standard Unix device sinks/sources allowed in shell commands.")

(defconst kargu-permission-allowed-binary-dirs
  '("/bin" "/usr/bin" "/usr/local/bin" "/snap/bin" "/opt/homebrew/bin"
    "/run/current-system/sw/bin" "/run/wrappers/bin" "/sbin" "/usr/sbin")
  "Standard system executable directories allowed in shell commands.")

(declare-function lsp-workspace-root "lsp-mode")

(defun kargu-permission-project-root (&optional buffer)
  "Return the canonical project root directory for BUFFER (or current).
The returned directory always ends with a slash and has symlinks resolved."
  (let ((raw-root
         (or kargu-permission--override-root
             (and (fboundp 'kargu--project-root)
                  (ignore-errors (kargu--project-root)))
             (when (and buffer (buffer-live-p buffer))
               (with-current-buffer buffer
                 (or (when (fboundp 'lsp-workspace-root)
                       (let ((ws (lsp-workspace-root)))
                         (and ws (file-name-as-directory ws))))
                     (when (fboundp 'project-root)
                       (let ((project (project-current)))
                         (and project (project-root project))))
                     default-directory)))
             default-directory)))
    (file-name-as-directory (file-truename (expand-file-name raw-root)))))

(defun kargu-permission-within-project-p (path &optional root)
  "Return non-nil if PATH is inside ROOT (canonicalized).
ROOT defaults to `kargu-permission-project-root'.  Both PATH and ROOT
have symlinks and relative segments canonicalized via `file-truename'."
  (let* ((effective-root (file-name-as-directory
                          (file-truename (or root (kargu-permission-project-root)))))
         (raw-abs (if (file-name-absolute-p path)
                      path
                    (expand-file-name path effective-root)))
         (effective-path (file-truename raw-abs)))
    (or (string= effective-path (directory-file-name effective-root))
        (string= (file-name-as-directory effective-path) effective-root)
        (string-prefix-p effective-root (file-name-as-directory effective-path))
        (file-in-directory-p effective-path effective-root))))

(defun kargu-permission-assert-within-project (path &optional root label)
  "Assert that PATH is strictly within ROOT.
Signal a `permission-denied' error when PATH escapes ROOT.
LABEL optionally describes the resource (e.g. \"file\", \"cwd\").
Return the expanded absolute file name."
  (let* ((effective-root (file-name-as-directory
                          (file-truename (or root (kargu-permission-project-root)))))
         (abs (if (and (stringp path) (file-name-absolute-p path))
                  (expand-file-name path)
                (expand-file-name (or path "") effective-root))))
    (if (not kargu-permission-strict-mode)
        abs
      (unless (kargu-permission-within-project-p abs effective-root)
        (error "Permission denied: %s '%s' is outside project root '%s'"
               (or label "path") (or path "") effective-root))
      abs)))

(provide 'kargu/permission/guards)

;;; kargu/permission/guards.el ends here
