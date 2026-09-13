;;; kargu/permission/bash.el --- Shell command validation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Shell command tokenization and escape analysis.
;; Prevents shell injections, directory traversal (..), home escapes (~),
;; and unauthorized filesystem modifications.

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

(require 'kargu/permission/guards)

(defun kargu-permission-allowed-binary-p (path)
  "Return non-nil if PATH is an executable in standard system binary dirs."
  (and (stringp path)
       (file-name-absolute-p path)
       (file-executable-p path)
       (not (file-directory-p path))
       (or (cl-some (lambda (dir)
                      (let ((d (file-name-as-directory (file-truename dir))))
                        (string-prefix-p d (file-truename path))))
                    kargu-permission-allowed-binary-dirs)
           (string-match-p "\\`/nix/store/[^/]+-[^/]+/bin/" path))))

(defun kargu-permission-tokenize-command (cmd)
  "Tokenize shell CMD respecting quotes, operators, and subshells."
  (let ((tokens nil)
        (i 0)
        (len (length cmd)))
    (while (< i len)
      (let ((c (aref cmd i)))
        (cond
         ((memq c (list ?\s ?\t ?\n ?\r))
          (setq i (1+ i)))
         ((memq c (list ?\" ?\'))
          (let ((q c)
                (start (1+ i)))
            (setq i (1+ i))
            (while (and (< i len) (/= (aref cmd i) q))
              (when (= (aref cmd i) ?\\) (setq i (1+ i)))
              (setq i (1+ i)))
            (let ((content (substring cmd start (min i len))))
              (push (cons :quoted content) tokens))
            (when (< i len) (setq i (1+ i)))))
         ((memq c (list ?\; ?\& ?\| ?\< ?\> ?\= ?\` ?\( ?\)))
          (setq i (1+ i)))
         (t
          (let ((start i))
            (while (and (< i len)
                        (not (memq (aref cmd i)
                                   (list ?\s ?\t ?\n ?\r ?\; ?\& ?\| ?\< ?\> ?\= ?\` ?\" ?\' ?\( ?\)))))
              (setq i (1+ i)))
            (push (cons :word (substring cmd start i)) tokens))))))
    (nreverse tokens)))

(defun kargu-permission-validate-command (command &optional root cwd)
  "Validate that COMMAND and CWD do not access paths outside ROOT.
Signal an error if any path argument, redirection, or traversal
escapes ROOT."
  (unless (and (stringp command) (not (string-empty-p (string-trim command))))
    (error "command must be a non-empty string"))
  (when kargu-permission-strict-mode
    (let* ((effective-root (file-name-as-directory
                            (file-truename (or root (kargu-permission-project-root)))))
           (effective-cwd (file-name-as-directory
                           (file-truename (or cwd effective-root)))))
      ;; 1. Check working directory
      (unless (kargu-permission-within-project-p effective-cwd effective-root)
        (error "Permission denied: working directory '%s' is outside project root '%s'"
               (or cwd "") effective-root))
      ;; 2. Substitute common environment variables (e.g. $HOME)
      (let* ((expanded-cmd (condition-case _
                               (substitute-in-file-name command)
                             (error command)))
             (tokens (kargu-permission-tokenize-command expanded-cmd)))
        (dolist (tok-cons tokens)
          (let* ((type (car tok-cons))
                 (tok (cdr tok-cons)))
            (cond
             ((or (string-match-p "\\`\\.\\.\\(/\\|\\'\\)" tok)
                  (string-match-p "/\\.\\.\\(/\\|\\'\\)" tok)
                  (string= tok ".."))
              (let ((expanded (expand-file-name tok effective-cwd)))
                (unless (kargu-permission-within-project-p expanded effective-root)
                  (error "Permission denied: path '%s' escapes project root '%s'"
                         tok effective-root))))
             ((string-prefix-p "~" tok)
              (let ((expanded (expand-file-name tok)))
                (unless (kargu-permission-within-project-p expanded effective-root)
                  (error "Permission denied: home path '%s' is outside project root '%s'"
                         tok effective-root))))
             ((string-prefix-p "/" tok)
              (cond
               ((kargu-permission-within-project-p tok effective-root)
                nil)
               ((member tok kargu-permission-allowed-devices)
                nil)
               ((string-prefix-p "/dev/fd/" tok)
                nil)
               ((and (eq type :word) (kargu-permission-allowed-binary-p tok))
                nil)
               (t
                (error "Permission denied: path '%s' is outside project root '%s'"
                       tok effective-root)))))))))))

(provide 'kargu/permission/bash)

;;; kargu/permission/bash.el ends here
