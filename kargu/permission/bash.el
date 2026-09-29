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
           (string-match-p "\\`/nix/store/[^/]+-[^/]+/bin/" (file-truename path)))))

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

(defconst kargu-permission-interpreters
  '("sh" "bash" "zsh" "dash" "ksh" "fish" "csh" "tcsh"
    "python" "python2" "python3" "perl" "ruby" "node" "nodejs" "php" "lua"
    "awk" "gawk" "emacs" "osascript" "pwsh" "powershell")
  "Programs that can run code the path validator cannot see.")

(defconst kargu-permission-code-flags
  '("-c" "-e" "-E" "-r" "-x" "--eval" "--exec" "--command" "--execute" "--eval-expression")
  "Flags that make an interpreter run the following text as code.")

(defun kargu-permission--command-words (command)
  "Word tokens of COMMAND, by command position, as lists of strings.
Commands are split on ; & | and newlines so each segment is one list."
  (let (segments)
    (dolist (seg (split-string command "[;&|\n]+" t "[ \t]+"))
      (push (split-string seg "[ \t]+" t) segments))
    (nreverse segments)))

(defun kargu-permission--segment-risk (words)
  "Reason string when the command WORDS run code that cannot be inspected."
  (let* ((head (car words))
         (base (and head (file-name-nondirectory head))))
    (cond
     ((null base) nil)
     ((member base '("eval" "exec" "source" "." "xargs" "sudo" "doas" "nohup" "env" "command" "time" "timeout"))
      (format "`%s' runs another command the validator cannot see" base))
     ((and (member base kargu-permission-interpreters)
           (cl-some (lambda (w) (member w kargu-permission-code-flags)) (cdr words)))
      (format "`%s' runs inline code" base)))))

(defun kargu-permission-command-risks (command)
  "Reasons why COMMAND cannot be fully checked by the path validator.
Return nil for a command made only of plain words and quoted literals.
A non-nil result means the command may touch paths the tokenizer never
sees, so it needs an explicit human approval."
  (let (risks)
    (when (string-match-p "\\$(\\|`\\|\\$'\\|\\${\\|\\$\"\\|<(\\|>(" command)
      (push "shell expansion ($(...), backticks, $'...', ${...}) builds paths at run time" risks))
    (when (string-match-p "\\\\/" command)
      (push "backslash-escaped slash hides a path" risks))
    (when (string-match-p "|[ \t]*\\(?:[^ \t|;&]*/\\)?\\(?:ba\\|z\\|da\\|k\\)?sh\\b" command)
      (push "pipes data into a shell" risks))
    (dolist (words (kargu-permission--command-words command))
      (when-let* ((r (kargu-permission--segment-risk words)))
        (push r risks)))
    (nreverse (delete-dups risks))))

(defun kargu-permission--validate-cwd (effective-cwd effective-root cwd)
  "Signal an error if EFFECTIVE-CWD is not within EFFECTIVE-ROOT."
  (unless (kargu-permission-within-project-p effective-cwd effective-root)
    (error (concat "Permission denied: working directory '%s' is outside the permitted workspace boundary.\n"
                   "  - Attempted working directory: '%s' (resolved to '%s')\n"
                   "  - Allowed project root: '%s'\n"
                   "  - Reason: Shell commands are strictly confined to the project root to prevent unauthorized system access.\n"
                   "  - Guidance: You do not have permission to run commands outside '%s'. Please set 'cwd' to a subdirectory within the project root or omit 'cwd' to run directly in the project root.")
           (or cwd "") (or cwd "") effective-cwd effective-root effective-root)))

(defun kargu-permission--validate-token (tok-cons effective-cwd effective-root)
  "Validate token cons (TYPE . TOK) against EFFECTIVE-CWD and EFFECTIVE-ROOT."
  (let* ((type (car tok-cons))
         (tok (cdr tok-cons)))
    (cond
     ((or (string-match-p "\\`\\.\\.\\(/\\|\\'\\)" tok)
          (string-match-p "/\\.\\.\\(/\\|\\'\\)" tok)
          (string= tok ".."))
      (let ((expanded (expand-file-name tok effective-cwd)))
        (unless (kargu-permission-within-project-p expanded effective-root)
          (error (concat "Permission denied: path traversal '%s' escapes the permitted workspace boundary.\n"
                         "  - Attempted path: '%s' (resolved to '%s')\n"
                         "  - Allowed project root: '%s'\n"
                         "  - Reason: Directory traversal (..) attempting to escape the project boundary is prohibited.\n"
                         "  - Guidance: You only have permission to execute commands and access files within '%s'. Please modify your command to operate strictly inside the project root.")
                 tok tok expanded effective-root effective-root))))
     ((and (not (string-prefix-p "-" tok))
           (not (string-prefix-p "/" tok))
           (not (string-prefix-p "~" tok))
           (not (string-empty-p tok))
           (file-exists-p (expand-file-name tok effective-cwd))
           (not (kargu-permission-within-project-p
                 (expand-file-name tok effective-cwd) effective-root)))
      (error (concat "Permission denied: '%s' resolves outside the permitted workspace boundary "
                     "(a symbolic link points out of '%s').")
             tok effective-root))
     ((string-prefix-p "~" tok)
      (let ((expanded (expand-file-name tok)))
        (unless (kargu-permission-within-project-p expanded effective-root)
          (error (concat "Permission denied: home directory path '%s' escapes the permitted workspace boundary.\n"
                         "  - Attempted path: '%s' (resolved to '%s')\n"
                         "  - Allowed project root: '%s'\n"
                         "  - Reason: Accessing files in the user's home directory outside the project root is prohibited.\n"
                         "  - Guidance: You do not have permission to access external home directories. Please only work inside '%s'.")
                 tok tok expanded effective-root effective-root))))
     ((string-prefix-p "/" tok)
      (cond
       ((kargu-permission-within-project-p tok effective-root) nil)
       ((member tok kargu-permission-allowed-devices) nil)
       ((string-prefix-p "/dev/fd/" tok) nil)
       ((and (eq type :word) (kargu-permission-allowed-binary-p tok)) nil)
       (t
        (error (concat "Permission denied: external system path '%s' is outside the permitted workspace boundary.\n"
                       "  - Attempted path: '%s'\n"
                       "  - Allowed project root: '%s'\n"
                       "  - Reason: Absolute system paths outside the project root are prohibited (only standard system binaries and device sinks are permitted).\n"
                       "  - Guidance: You do not have permission to access '%s'. You must restrict all script executions, file creations, and inspections to within '%s'.")
               tok tok effective-root tok effective-root)))))))

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
      (kargu-permission--validate-cwd effective-cwd effective-root cwd)
      ;; 2. Substitute common environment variables and validate tokens
      (let* ((expanded-cmd (condition-case _
                               (substitute-in-file-name command)
                             (error command)))
             (tokens (kargu-permission-tokenize-command expanded-cmd)))
        (dolist (tok-cons tokens)
          (kargu-permission--validate-token tok-cons effective-cwd effective-root))))))

(provide 'kargu/permission/bash)

;;; kargu/permission/bash.el ends here
