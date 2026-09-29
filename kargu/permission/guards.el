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

(declare-function eglot-current-server "eglot")
(declare-function eglot-project "eglot" (server))

(defun kargu-permission-context-root ()
  "Project root of the current buffer from Eglot or `project.el'.
Falls back to `default-directory'.  Not canonicalized; callers that
need the canonical root use `kargu-permission-project-root'."
  (condition-case-unless-debug nil
      (let* ((server (and (fboundp 'eglot-current-server)
                          (eglot-current-server)))
             (proj (or (and server (fboundp 'eglot-project)
                            (eglot-project server))
                       (and (fboundp 'project-current)
                            (project-current))))
             (root (and proj (fboundp 'project-root) (project-root proj))))
        (if root
            (file-name-as-directory (expand-file-name root))
          default-directory))
    (error default-directory)))

(defun kargu-permission-project-root (&optional buffer)
  "Return the canonical project root directory for BUFFER (or current).
The one answer to \"where is the project\": an explicit override, then
the language or LSP context, then Eglot / `project.el' of BUFFER.  The
result ends with a slash and has symlinks resolved."
  (let ((raw-root
         (or kargu-permission--override-root
             (and (fboundp 'kargu--project-root)
                  (if (and buffer (buffer-live-p buffer))
                      (with-current-buffer buffer (kargu--project-root))
                    (kargu--project-root)))
             (if (and buffer (buffer-live-p buffer))
                 (with-current-buffer buffer (kargu-permission-context-root))
               (kargu-permission-context-root)))))
    (file-name-as-directory (file-truename (expand-file-name raw-root)))))

(defun kargu-permission-resolve (path &optional label root)
  "Return PATH as an absolute name that is inside the project.
A relative PATH is taken from ROOT (default `kargu-permission-project-root').
LABEL names the resource in the refusal.  Signals when PATH is empty
or, in strict mode, when it escapes the root."
  (unless (and (stringp path) (not (string-empty-p (string-trim path))))
    (error "path must be a non-empty string"))
  (let* ((base (or root (kargu-permission-project-root)))
         (abs (expand-file-name path base)))
    (kargu-permission-assert-within-project abs base label)))

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
        (error (concat "Permission denied: %s '%s' is outside the permitted workspace boundary.\n"
                       "  - Attempted target: '%s' (resolved to '%s')\n"
                       "  - Allowed project root: '%s'\n"
                       "  - Reason: For security and workspace isolation, you do not have permission to access paths outside the project root.\n"
                       "  - Guidance: You are strictly restricted to working within '%s'. Please adjust your path to be relative to the project root or stay inside this directory.")
               (or label "path") (or path "") (or path "") abs effective-root effective-root))
      abs)))

(provide 'kargu/permission/guards)

;;; kargu/permission/guards.el ends here
