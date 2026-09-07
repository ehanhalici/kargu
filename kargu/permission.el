;;; kargu/permission.el --- LSP project root permission and sandboxing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Path-based permission and sandboxing guardrails.
;; Ensures all file reads, writes, searches, and bash commands are strictly
;; confined to the LSP project root (`kargu--project-root`).
;;
;; Public:
;;   `kargu-permission-project-root'
;;   `kargu-permission-within-project-p'
;;   `kargu-permission-assert-within-project'
;;   `kargu-permission-tokenize-command'
;;   `kargu-permission-validate-command'

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

(defvar kargu-chat--output-marker)
(defvar kargu-chat--prompt-marker)
(declare-function kargu-chat--prompt-live-p "kargu/chat/prompt" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())
(declare-function kargu-loop-running-p "kargu/loop" ())

(defconst kargu-permission-allowed-devices
  '("/dev/null" "/dev/zero" "/dev/stdout" "/dev/stderr" "/dev/stdin" "/dev/tty")
  "Standard Unix device sinks/sources allowed in shell commands.")

(defconst kargu-permission-allowed-binary-dirs
  '("/bin" "/usr/bin" "/usr/local/bin" "/snap/bin" "/opt/homebrew/bin"
    "/run/current-system/sw/bin" "/run/wrappers/bin" "/sbin" "/usr/sbin")
  "Standard system executable directories allowed in shell commands.")

;;;; Root resolution ------------------------------------------------------

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

;;;; Path validation ------------------------------------------------------

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

;;;; Command validation ---------------------------------------------------

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
         ;; Whitespace
         ((memq c (list ?\s ?\t ?\n ?\r))
          (setq i (1+ i)))
         ;; Quoted literals: single or double
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
         ;; Shell operators & separators: ; & | < > = ` ( )
         ((memq c (list ?\; ?\& ?\| ?\< ?\> ?\= ?\` ?\( ?\)))
          (setq i (1+ i)))
         ;; Unquoted word/argument
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
             ;; Check traversal dots: ..
             ((or (string-match-p "\\`\\.\\.\\(/\\|\\'\\)" tok)
                  (string-match-p "/\\.\\.\\(/\\|\\'\\)" tok)
                  (string= tok ".."))
              (let ((expanded (expand-file-name tok effective-cwd)))
                (unless (kargu-permission-within-project-p expanded effective-root)
                  (error "Permission denied: path '%s' escapes project root '%s'"
                         tok effective-root))))
             ;; Check home directory escapes: ~
             ((string-prefix-p "~" tok)
              (let ((expanded (expand-file-name tok)))
                (unless (kargu-permission-within-project-p expanded effective-root)
                  (error "Permission denied: home path '%s' is outside project root '%s'"
                         tok effective-root))))
             ;; Check absolute paths: /...
             ((string-prefix-p "/" tok)
              (cond
               ;; Path is inside project root -> OK
               ((kargu-permission-within-project-p tok effective-root)
                nil)
               ;; Path is allowed device sink -> OK
               ((member tok kargu-permission-allowed-devices)
                nil)
               ((string-prefix-p "/dev/fd/" tok)
                nil)
               ;; Path is an allowed system executable -> OK
               ((and (eq type :word) (kargu-permission-allowed-binary-p tok))
                nil)
               ;; Otherwise -> FORBIDDEN
               (t
                (error "Permission denied: path '%s' is outside project root '%s'"
                       tok effective-root)))))))))))

;;;; Approval UI ----------------------------------------------------------

(defun kargu-permission-request-approval (command dir)
  "Request user approval for executing COMMAND in DIR.
Presents '[✓ Approve]' and '[✗ Reject]' buttons in the chat buffer.
Returns non-nil if approved, or nil if rejected."
  (cond
   ;; Testing override
   (kargu-permission--mock-decision
    (eq kargu-permission--mock-decision :approve))
   ;; Non-interactive (batch mode) or confirmation disabled -> Auto-approve
   ((or noninteractive (not kargu-permission-confirm-bash))
    t)
   ;; Interactive with live chat buffer
   (t
    (when (fboundp 'kargu-notify)
      (kargu-notify 'permission))
    (let* ((chat-buf (or (and (bound-and-true-p kargu--loop-run)
                              (plist-get kargu--loop-run :chat-buffer))
                         (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*"))))
           (decision nil))
      (if (not (and chat-buf (buffer-live-p chat-buf)))
          ;; Fallback when chat buffer is not available
          (y-or-n-p (format "Execute Kargu bash command? $ %s (dir: %s) " command dir))
        ;; In chat buffer, insert notification and buttons
        (with-current-buffer chat-buf
          (let* ((inhibit-read-only t))
            (when (and (fboundp 'kargu-chat--prompt-live-p)
                       (kargu-chat--prompt-live-p))
              (delete-region kargu-chat--output-marker (point-max))
              (setq kargu-chat--prompt-marker nil))
            (goto-char (point-max))
            (insert "\n")
            (insert (propertize "  ⚡ [Bash Permission Approval]" 'face '(:inherit warning :weight bold)) "\n")
            (insert (format "     Command: $ %s\n" (propertize command 'face 'font-lock-keyword-face)))
            (insert (format "     Directory: %s\n     " dir))
            (insert-button
             "[✓ Approve]"
             'action (lambda (_)
                       (setq decision :approved)
                       (exit-recursive-edit))
             'face '(:inherit success :weight bold)
             'help-echo "Click to approve and execute command")
            (insert "  ")
            (insert-button
             "[✗ Reject]"
             'action (lambda (_)
                       (setq decision :rejected)
                       (exit-recursive-edit))
             'face '(:inherit error :weight bold)
             'help-echo "Click to reject command")
            (insert "\n\n")
            (setq kargu-chat--output-marker (copy-marker (point-max) t))))
        ;; Scroll chat window to show the prompt
        (dolist (win (get-buffer-window-list chat-buf nil t))
          (set-window-point win (point-max)))
        ;; Enter recursive edit to wait for button click or C-g
        (message "Command approval pending: click [✓ Approve] or [✗ Reject] (or C-g to cancel)")
        (condition-case _sig
            (recursive-edit)
          (quit
           (setq decision :rejected)
           (message "kargu: command execution cancelled by user")))
        ;; Update UI to show final choice
        (with-current-buffer chat-buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (if (eq decision :approved)
                (insert (propertize "     -> [✓ Approved, executing...]\n" 'face 'font-lock-string-face))
              (insert (propertize "     -> [✗ Rejected]\n" 'face 'font-lock-warning-face)))
            (setq kargu-chat--output-marker (copy-marker (point-max) t))))
        (dolist (win (get-buffer-window-list chat-buf nil t))
          (set-window-point win (point-max)))
        (when (and chat-buf (buffer-live-p chat-buf)
                   (not (kargu-loop-running-p))
                   (fboundp 'kargu-chat--ensure-idle-prompt))
          (with-current-buffer chat-buf
            (kargu-chat--ensure-idle-prompt)))
        (eq decision :approved))))))

(provide 'kargu/permission)

;;; kargu/permission.el ends here
