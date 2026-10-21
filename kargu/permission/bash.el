;;; bash.el --- Shell command validation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Shell command tokenization and escape analysis.
;; Best-effort path checks and approval requirements, not OS isolation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
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

(defconst kargu-permission--versioned-interpreter-pattern
  (rx bos (or "python" "lua" "php") (+ digit) (* "." (+ digit)) eos)
  "Version-qualified interpreters whose inline code still needs approval.")

(defun kargu-permission--interpreter-p (name)
  "Return non-nil when NAME identifies a known or versioned interpreter."
  (or (member name kargu-permission-interpreters)
      (string-match-p kargu-permission--versioned-interpreter-pattern name)))

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
     ((or (string-match-p (rx (any "='\"\\")) base)
          (member base '("eval" "exec" "source" "." "xargs" "sudo" "doas" "nohup"
                         "env" "command" "time" "timeout" "busybox" "toolbox")))
      (format "`%s' runs another command the validator cannot see" base))
     ((and (kargu-permission--interpreter-p base)
           (cl-some (lambda (w) (member w kargu-permission-code-flags)) (cdr words)))
      (format "`%s' runs inline code" base))
     ((and (equal base "find")
           (seq-intersection words '("-exec" "-execdir" "-ok" "-okdir") #'equal))
      "find executes another command")
     ((and (equal base "git")
           (cl-some (lambda (word)
                      (or (string-prefix-p "-c" word)
                          (string-prefix-p "--config-env" word)
                          (string-prefix-p "--exec-path" word)
                          (equal word "--paginate")))
                    (cdr words)))
      "Git configuration or pager flags can execute another command"))))

(defun kargu-permission-command-risks (command)
  "Reasons why COMMAND cannot be fully checked by the path validator.
Return nil for a command made only of plain words and quoted literals.
A non-nil result means the command may touch paths the tokenizer never
sees, so it needs an explicit human approval."
  (save-match-data
    (let (risks)
      (when (kargu-permission--unverified-environment-p command)
        (push "unresolved or shell-local variables can change paths at run time" risks))
      (when (string-match-p (rx (any "{}\\")) command)
	(push "braces or escapes can change paths after validation" risks))
      (when (cl-some (lambda (token)
                       (let ((word (cdr token)))
			 (and (string-prefix-p "-" word)
                              (string-match-p (rx (any "/~")) word))))
                     (kargu-permission-tokenize-command command))
	(push "an option contains an embedded path the validator cannot interpret" risks))
      (when (string-match-p "\\$(\\|`\\|\\$'\\|\\${\\|\\$\"\\|<(\\|>(" command)
	(push "shell expansion ($(...), backticks, $'...', ${...}) builds paths at run time" risks))
      (when (string-match-p "\\\\/" command)
	(push "backslash-escaped slash hides a path" risks))
      (when (string-match-p "|[ \t]*\\(?:[^ \t|;&]*/\\)?\\(?:ba\\|z\\|da\\|k\\)?sh\\b" command)
	(push "pipes data into a shell" risks))
      (dolist (words (kargu-permission--command-words command))
	(when-let* ((r (kargu-permission--segment-risk words)))
          (push r risks)))
      (nreverse (delete-dups risks)))))

(defun kargu-permission--validate-cwd (effective-cwd effective-root cwd)
  "Check EFFECTIVE-CWD against EFFECTIVE-ROOT, reporting the supplied CWD."
  (unless (kargu-permission-within-project-p effective-cwd effective-root)
    (error (concat "Permission denied: working directory '%s' is outside the permitted workspace boundary.\n"
                   "  - Attempted working directory: '%s' (resolved to '%s')\n"
                   "  - Allowed project root: '%s'\n"
                   "  - Reason: Shell commands are strictly confined to the project root to prevent unauthorized system access.\n"
                   "  - Guidance: You do not have permission to run commands outside '%s'. Please set 'cwd' to a subdirectory within the project root or omit 'cwd' to run directly in the project root.")
           (or cwd "") (or cwd "") effective-cwd effective-root effective-root)))

(defconst kargu-permission--traversal-error
  (concat "Permission denied: path traversal '%s' escapes the permitted workspace boundary.\n"
          "  - Attempted path: '%s' (resolved to '%s')\n"
          "  - Allowed project root: '%s'\n"
          "  - Reason: Directory traversal (..) attempting to escape the project boundary is prohibited.\n"
          "  - Guidance: You only have permission to execute commands and access files within '%s'. Please modify your command to operate strictly inside the project root.")
  "Refusal template for a traversal outside the workspace.")

(defconst kargu-permission--symlink-error
  (concat "Permission denied: '%s' resolves outside the permitted workspace boundary "
          "(a symbolic link points out of '%s').")
  "Refusal template for a symlink outside the workspace.")

(defconst kargu-permission--home-path-error
  (concat "Permission denied: home directory path '%s' escapes the permitted workspace boundary.\n"
          "  - Attempted path: '%s' (resolved to '%s')\n"
          "  - Allowed project root: '%s'\n"
          "  - Reason: Accessing files in the user's home directory outside the project root is prohibited.\n"
          "  - Guidance: You do not have permission to access external home directories. Please only work inside '%s'.")
  "Refusal template for a home-path outside the workspace.")

(defconst kargu-permission--system-path-error
  (concat "Permission denied: external system path '%s' is outside the permitted workspace boundary.\n"
          "  - Attempted path: '%s'\n"
          "  - Allowed project root: '%s'\n"
          "  - Reason: Absolute system paths outside the project root are prohibited (only standard system binaries and device sinks are permitted).\n"
          "  - Guidance: You do not have permission to access '%s'. You must restrict all script executions, file creations, and inspections to within '%s'.")
  "Refusal template for a system-path outside the workspace.")

(defconst kargu-permission--environment-reference
  (rx "$" (or (seq "{" (any alpha "_") (* (any alnum "_")) "}")
              (seq (any alpha "_") (* (any alnum "_")))))
  "Simple environment references understood without executing shell code.")

(defun kargu-permission--unverified-environment-p (command)
  "Return non-nil if COMMAND references missing or shell-local variables."
  (save-match-data
    (let ((position 0))
      (catch 'unverified
        (while (string-match kargu-permission--environment-reference command position)
          (let* ((reference (match-string 0 command))
                 (name (if (string-prefix-p "${" reference)
                           (substring reference 2 -1) (substring reference 1))))
            (setq position (match-end 0))
            (when (or (member name '("PWD" "OLDPWD")) (null (getenv name)))
              (throw 'unverified t))))
        nil))))

(defun kargu-permission--expand-environment (command)
  "Expand simple environment references in COMMAND without path rewriting."
  (save-match-data
    (replace-regexp-in-string
     kargu-permission--environment-reference
     (lambda (reference)
       (let ((name (if (string-prefix-p "${" reference)
                       (substring reference 2 -1) (substring reference 1))))
         (or (getenv name) reference)))
     command t t)))

(defun kargu-permission--option-path (token)
  "Extract an unambiguous absolute or home path attached to option TOKEN."
  (save-match-data
    (when (string-match
           (rx bos "-" (+ (any alpha "-")) (? "=")
               (group (any "/~") (* anychar)) eos) token)
      (match-string 1 token))))

(defun kargu-permission--validate-token (tok-cons effective-cwd effective-root)
  "Validate TOK-CONS against EFFECTIVE-CWD and EFFECTIVE-ROOT."
  (let* ((path (kargu-permission--option-path (cdr tok-cons)))
         (type (if path :quoted (car tok-cons)))
         (tok (or path (cdr tok-cons))))
    (cond
     ((or (string-match-p "\\`\\.\\.\\(/\\|\\'\\)" tok)
          (string-match-p "/\\.\\.\\(/\\|\\'\\)" tok)
          (string= tok ".."))
      (let ((expanded (expand-file-name tok effective-cwd)))
        (unless (kargu-permission-within-project-p expanded effective-root)
          (error kargu-permission--traversal-error
                 tok tok expanded effective-root effective-root))))
     ((and (not (string-prefix-p "-" tok))
           (not (string-prefix-p "/" tok))
           (not (string-prefix-p "~" tok))
           (not (string-empty-p tok))
           (file-exists-p (expand-file-name tok effective-cwd))
           (not (kargu-permission-within-project-p
                 (expand-file-name tok effective-cwd) effective-root)))
      (error kargu-permission--symlink-error
             tok effective-root))
     ((string-prefix-p "~" tok)
      (let ((expanded (expand-file-name tok)))
        (unless (kargu-permission-within-project-p expanded effective-root)
          (error kargu-permission--home-path-error
                 tok tok expanded effective-root effective-root))))
     ((string-prefix-p "/" tok)
      (cond
       ((kargu-permission-within-project-p tok effective-root) nil)
       ((member tok kargu-permission-allowed-devices) nil)
       ((string-prefix-p "/dev/fd/" tok) nil)
       ((and (eq type :word) (kargu-permission-allowed-binary-p tok)) nil)
       (t
        (error kargu-permission--system-path-error
               tok tok effective-root tok effective-root)))))))

(defun kargu-permission-validate-command (command &optional root cwd)
  "Validate that COMMAND and CWD do not access paths outside ROOT.
Signal an error if any path argument, redirection, or traversal
escapes ROOT."
  (unless (and (stringp command) (not (string-empty-p (string-trim command))))
    (error "Command must be a non-empty string"))
  (when kargu-permission-strict-mode
    (save-match-data
      (let* ((effective-root (file-name-as-directory
                              (file-truename (or root (kargu-permission-project-root)))))
             (effective-cwd (file-name-as-directory
                             (file-truename (or cwd effective-root)))))
	;; 1. Check working directory
	(kargu-permission--validate-cwd effective-cwd effective-root cwd)
	;; 2. Substitute common environment variables and validate tokens
	(let* ((expanded-cmd (kargu-permission--expand-environment command))
               (tokens (kargu-permission-tokenize-command expanded-cmd)))
          (dolist (tok-cons tokens)
            (kargu-permission--validate-token tok-cons effective-cwd effective-root)))))))

(provide 'kargu/permission/bash)

;;; bash.el ends here
