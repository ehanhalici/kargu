;;; workspace.el --- Project-scoped debugger resources -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Resolve only source buffers and adapter connections inside one workspace.
;; Unknown adapter working directories are not evidence of project ownership.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/permission)

(defvar kargu-context-buffer)

(declare-function dape--config "dape" (conn))
(declare-function dape--parent "dape" (conn))
(declare-function dape--live-connections "dape" ())

(defun kargu-dape--connection-directory (connection &optional seen)
  "Return CONNECTION's concrete working directory, avoiding parents in SEEN."
  (when (and connection (not (memq connection seen))
             (fboundp 'dape--config))
    (let* ((config (dape--config connection))
           (command-cwd (plist-get config 'command-cwd))
           (cwd (plist-get config :cwd))
           (base (and (stringp command-cwd)
                      (file-name-absolute-p command-cwd) command-cwd)))
      (cond
       ((and (stringp cwd) (not (string-empty-p cwd))
             (or base (file-name-absolute-p cwd)))
        (expand-file-name cwd base))
       (base base)
       ((fboundp 'dape--parent)
        (kargu-dape--connection-directory
         (dape--parent connection) (cons connection seen)))))))

(defun kargu-dape-project-connections (&optional root)
  "Return live adapter connections with a concrete directory inside ROOT.
ROOT defaults to the selected project.  Global Dape selection is ignored."
  (let ((root (or root (kargu-permission-project-root))))
    (when (fboundp 'dape--live-connections)
      (seq-filter
       (lambda (connection)
         (when-let* ((directory (kargu-dape--connection-directory connection)))
           (kargu-permission-within-project-p directory root)))
       (dape--live-connections)))))

(defun kargu-dape-launch-connections (root token)
  "Return live root adapters in ROOT bearing the exact launch TOKEN.
The non-keyword metadata key is local to Dape and is never a DAP argument."
  (when token
    (seq-filter (lambda (connection)
                  (and (not (dape--parent connection))
                       (eq token (plist-get (dape--config connection) 'kargu--launch-token))))
                (kargu-dape-project-connections root))))

(defun kargu-dape--source-buffer-p (buffer root)
  "Return non-nil when BUFFER visits source code inside ROOT."
  (and (buffer-live-p buffer)
       (buffer-file-name buffer)
       (with-current-buffer buffer
         (and (derived-mode-p 'prog-mode)
              (not (derived-mode-p 'kargu-chat-mode))))
       (kargu-permission-within-project-p (buffer-file-name buffer) root)))

(defun kargu-dape-source-buffer (&optional root)
  "Return the preferred source buffer inside ROOT, or nil.
ROOT defaults to the selected project.  A foreign context, visible window
or recently visited file cannot become a launch target."
  (let* ((root (or root (kargu-permission-project-root)))
         (source (bound-and-true-p kargu-context-buffer))
         (context (cond
                   ((bufferp source) source)
                   ((stringp source) (find-buffer-visiting source))))
         (candidates (append (list context (current-buffer))
                             (mapcar #'window-buffer (window-list))
                             (buffer-list))))
    (seq-find (lambda (buffer) (kargu-dape--source-buffer-p buffer root))
              candidates)))

(provide 'kargu/tools/dape/workspace)
;;; workspace.el ends here
