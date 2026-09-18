;;; kargu/tools/bash.el --- Shell command tool -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; `bash' tool: run a shell command with a timeout.  Advertised
;; only in agent mode (mutating-tools list).  Requires: `kargu/core',
;; `kargu/api'.

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
(require 'kargu/contract)
(require 'kargu/api)
(require 'kargu/permission)

(defgroup kargu-bash nil
  "Shell command tool."
  :group 'kargu
  :prefix "kargu-bash-")

(defcustom kargu-bash-timeout 30
  "Seconds after which a bash tool command is killed."
  :type 'natnum
  :group 'kargu-bash)

(defun kargu-bash--cwd (path)
  "Resolve optional working directory PATH and assert it is in project root."
  (let* ((root (kargu-permission-project-root))
         (raw (and (stringp path) (not (string-empty-p (string-trim path))) path)))
    (if (null raw)
        root
      (let ((abs (if (file-name-absolute-p raw)
                     (expand-file-name raw)
                   (expand-file-name raw root))))
        (kargu-permission-assert-within-project abs root "cwd")))))

(defvar kargu-bash--processes (make-hash-table :test 'equal)
  "Active background processes keyed by ID string (e.g. `p1\').")

(defvar kargu-bash--counter 0
  "Monotonic counter for background process IDs.")

(defun kargu-bash--clean-buffer-processes (buf)
  "Delete all processes associated with BUF and prevent exit queries."
  (when (and buf (buffer-live-p buf))
    (dolist (p (process-list))
      (when (eq (process-buffer p) buf)
        (set-process-query-on-exit-flag p nil)
        (set-process-buffer p nil)
        (ignore-errors (delete-process p))))))

(defun kargu-bash--manage-process (command)
  "Handle background process management commands (list, status, kill).
Return a result string if COMMAND matches a management command, or nil."
  (let ((cmd (string-trim command)))
    (cond
     ((equal cmd "list")
      (let (lines)
        (maphash
         (lambda (id plist)
           (let* ((proc (plist-get plist :proc))
                  (alive (and proc (process-live-p proc)))
                  (pid (plist-get plist :pid))
                  (orig-cmd (plist-get plist :command)))
             (push (format "  [%s] PID %s (%s) - %s"
                           id (or pid "?") (if alive "RUNNING" "EXITED")
                           (truncate-string-to-width orig-cmd 60))
                   lines)))
         kargu-bash--processes)
        (if lines
            (concat "Background processes:\n" (string-join (nreverse lines) "\n"))
          "No active background processes.")))
     ((string-prefix-p "kill " cmd)
      (let* ((target-id (string-trim (substring cmd 5)))
             (plist (gethash target-id kargu-bash--processes)))
        (if (null plist)
            (format "ERROR: no background process found with ID '%s'" target-id)
          (let ((buf (plist-get plist :buf)))
            (kargu-bash--clean-buffer-processes buf)
            (when (and buf (buffer-live-p buf))
              (ignore-errors (kill-buffer buf)))
            (remhash target-id kargu-bash--processes)
            (format "Background process [%s] (PID %s) terminated."
                    target-id (plist-get plist :pid))))))
     ((string-prefix-p "status " cmd)
      (let* ((target-id (string-trim (substring cmd 7)))
             (plist (gethash target-id kargu-bash--processes)))
        (if (null plist)
            (format "ERROR: no background process found with ID '%s'" target-id)
          (let* ((proc (plist-get plist :proc))
                 (alive (and proc (process-live-p proc)))
                 (buf (plist-get plist :buf))
                 (out (if (and buf (buffer-live-p buf))
                          (with-current-buffer buf
                            (let* ((lines (split-string (buffer-string) "\n"))
                                   (tail (last lines 25)))
                              (string-join tail "\n")))
                        "(buffer closed)")))
            (format "Background process [%s] (PID %s, %s):\nCommand: %s\nRecent output:\n%s"
                    target-id (plist-get plist :pid)
                    (if alive "RUNNING" (format "EXITED code %s" (process-exit-status proc)))
                    (plist-get plist :command)
                    (if (string-empty-p (string-trim out)) "(no output yet)" out))))))
     (t nil))))

(defun kargu-bash--resolve-shell ()
  "Find an executable shell binary."
  (let ((s (or (getenv "SHELL")
               (and (boundp 'shell-file-name) shell-file-name)
               "/bin/sh")))
    (if (and (stringp s) (executable-find s))
        s
      (or (executable-find "bash") (executable-find "sh") "/bin/sh"))))

(defun kargu-bash--run-background (command dir shell)
  "Execute COMMAND in DIR asynchronously under SHELL and return status string."
  (let* ((id (format "p%d" (cl-incf kargu-bash--counter)))
         (buf (get-buffer-create (format "*kargu-proc-%s*" id)))
         proc)
    (with-current-buffer buf
      (erase-buffer)
      (setq-local buffer-offer-save nil))
    (let ((default-directory (file-name-as-directory dir)))
      (setq proc (make-process
                  :name (format "kargu-bg-%s" id)
                  :buffer buf
                  :command (list shell "-c" command)
                  :connection-type 'pipe
                  :stderr buf))
      (dolist (p (process-list))
        (when (eq (process-buffer p) buf)
          (set-process-query-on-exit-flag p nil))))
    (puthash id
             (list :id id
                   :pid (process-id proc)
                   :command command
                   :proc proc
                   :buf buf
                   :start (float-time))
             kargu-bash--processes)
    (format "Process started in background: ID=[%s], PID=%d. Output directed to buffer '*kargu-proc-%s*'.\nManage with bash command='status %s' or command='kill %s'."
            id (process-id proc) id id id)))

(defvar kargu-bash--active-async-proc nil
  "Process object of the currently running async bash tool command, or nil.")

(defun kargu-bash-kill-active-async ()
  "Kill active asynchronous bash process if one is currently running."
  (when (and kargu-bash--active-async-proc
             (process-live-p kargu-bash--active-async-proc))
    (ignore-errors (kill-process kargu-bash--active-async-proc))
    (setq kargu-bash--active-async-proc nil)))

(defun kargu-bash--run-async (command dir shell callback)
  "Execute COMMAND asynchronously in DIR under SHELL.
Calls CALLBACK with the formatted output string upon exit or timeout.
Emacs UI remains completely responsive and interactive for the user."
  (let* ((buf (generate-new-buffer " *kargu-bash*"))
         (start (float-time))
         (completed nil)
         (timer nil)
         (timeout-timer nil)
         proc)
    (let ((default-directory (file-name-as-directory dir)))
      (setq proc (make-process
                  :name "kargu-bash"
                  :buffer buf
                  :command (list shell "-c" command)
                  :connection-type 'pipe
                  :stderr buf
                  :sentinel
                  (lambda (p _event)
                    (unless completed
                      (setq completed t)
                      (setq kargu-bash--active-async-proc nil)
                      (when timer (cancel-timer timer))
                      (when timeout-timer (cancel-timer timeout-timer))
                      (let* ((code (process-exit-status p))
                             (out (if (buffer-live-p buf)
                                      (with-current-buffer buf (buffer-string))
                                    ""))
                             (res (format "exit %s\ncwd: %s\n%s"
                                          code dir
                                          (if (string-empty-p out) "(no output)" out))))
                        (message "kargu: [bash] '%s' finished (exit %s, %.1fs)"
                                 (truncate-string-to-width command 30)
                                 code (- (float-time) start))
                        (kargu-bash--clean-buffer-processes buf)
                        (when (buffer-live-p buf) (kill-buffer buf))
                        (funcall callback res))))))
      (set-process-query-on-exit-flag proc nil)
      (setq kargu-bash--active-async-proc proc))
    ;; Timeout timer: kill process and return error when kargu-bash-timeout expires
    (setq timeout-timer
          (run-at-time
           kargu-bash-timeout nil
           (lambda ()
             (unless completed
               (setq completed t)
               (setq kargu-bash--active-async-proc nil)
               (when timer (cancel-timer timer))
               (when (process-live-p proc)
                 (ignore-errors (kill-process proc)))
               (let ((err-msg (format "ERROR: bash timed out after %ds: %s"
                                      kargu-bash-timeout
                                      (truncate-string-to-width command 80))))
                 (message "kargu: [bash] '%s' timed out (%ds)"
                          (truncate-string-to-width command 30)
                          kargu-bash-timeout)
                 (kargu-bash--clean-buffer-processes buf)
                 (when (buffer-live-p buf) (kill-buffer buf))
                 (funcall callback err-msg))))))
    ;; Periodic status ticker in minibuffer so user sees elapsed time
    (setq timer
          (run-at-time
           1.0 1.0
           (lambda ()
             (unless completed
               (when (process-live-p proc)
                 (let ((elapsed (- (float-time) start)))
                   (message "kargu: running '%s' (%.1fs / %ds) [waiting in background]..."
                            (truncate-string-to-width command 40)
                            elapsed kargu-bash-timeout)))))))
    (message "kargu: started '%s' asynchronously in background (timeout %ds)..."
             (truncate-string-to-width command 40) kargu-bash-timeout)))

(defun kargu-bash--run-sync (command dir shell)
  "Execute COMMAND synchronously in DIR under SHELL within timeout bounds.
Emits live progress updates and redisplays to avoid freezing the window."
  (let* ((buf (generate-new-buffer " *kargu-bash*"))
         (start (float-time))
         (last-msg 0.0)
         proc)
    (unwind-protect
        (progn
          (let ((default-directory (file-name-as-directory dir)))
            (setq proc (make-process
                        :name "kargu-bash"
                        :buffer buf
                        :command (list shell "-c" command)
                        :connection-type 'pipe
                        :stderr buf))
            (set-process-query-on-exit-flag proc nil))
          (with-local-quit
            (while (process-live-p proc)
              (let ((elapsed (- (float-time) start)))
                (when (> elapsed kargu-bash-timeout)
                  (ignore-errors (kill-process proc))
                  (error "bash timed out after %ds: %s"
                         kargu-bash-timeout
                         (truncate-string-to-width command 80)))
                (when (>= (- elapsed last-msg) 0.5)
                  (setq last-msg elapsed)
                  (message "kargu: running '%s' (%.1fs / %ds) [C-g to cancel]..."
                           (truncate-string-to-width command 40)
                           elapsed kargu-bash-timeout)
                  (redisplay)))
              (accept-process-output proc 0.05)))
          (if (process-live-p proc)
              (progn
                (ignore-errors (kill-process proc))
                (error "bash command interrupted by user (C-g): %s"
                       (truncate-string-to-width command 80)))
            (let* ((code (process-exit-status proc))
                   (out (with-current-buffer buf (buffer-string))))
              (message "kargu: [bash] '%s' finished (exit %s, %.1fs)"
                       (truncate-string-to-width command 30)
                       code (- (float-time) start))
              (format "exit %s\ncwd: %s\n%s" code dir
                      (if (string-empty-p out) "(no output)" out)))))
      (kargu-bash--clean-buffer-processes buf)
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(defun kargu-bash-run (command &optional cwd background callback)
  "Run COMMAND in CWD, capturing stdout and stderr.
When CALLBACK is non-nil, execute asynchronously without blocking
the Emacs UI and call CALLBACK with the result string upon completion.
When BACKGROUND is non-nil, start a persistent background process.
Strictly validates that CWD and all path arguments stay within project root."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p command
                         "command must be a non-empty string: %S" command)
  (let ((mgmt (kargu-bash--manage-process command)))
    (if mgmt
        (if callback (funcall callback mgmt) mgmt)
      (let* ((root (kargu-permission-project-root))
             (dir (kargu-bash--cwd cwd)))
        ;; Sandboxing check: command cannot escape project root
        (kargu-permission-validate-command command root dir)
        ;; User approval check: 1-click button prompt in chat
        (unless (kargu-permission-request-approval command dir)
          (let ((err-text
                 (concat "Permission denied: Command execution was rejected by the user.\n"
                         "  - Rejected command: '" command "'\n"
                         "  - Working directory: '" dir "'\n"
                         "  - Allowed project root: '" root "'\n"
                         "  - Reason: The user chose not to grant execution permission for this shell command.\n"
                         "  - Guidance: Do not repeatedly execute the identical command without user clarification. Consider an alternative approach that works strictly within '" root "' or ask the user for guidance.")))
            (if callback
                (funcall callback (format "ERROR: %s" err-text))
              (error "%s" err-text))))
        (let ((shell (kargu-bash--resolve-shell)))
          (cond
           (background
            (let ((res (kargu-bash--run-background command dir shell)))
              (if callback (funcall callback res) res)))
           (callback
            (kargu-bash--run-async command dir shell callback))
           (t
            (kargu-bash--run-sync command dir shell))))))))

(defun kargu-bash-register-tools ()
  "Register the bash tool."
  (kargu-register-tool
   "bash"
   "Run a shell command in the project (stdout+stderr, timeout, background support). Agent mode only. Use for builds, tests, dev servers, git. Set background=true for long-running servers."
   '(("type" . "object")
     ("properties" . (("command" . (("type" . "string")
                                    ("description" . "Shell command to run, or 'status <id>', 'kill <id>', 'list'.")))
                      ("cwd" . (("type" . "string")
                                ("description" . "Working directory (default: project root).")))
                      ("background" . (("type" . "boolean")
                                       ("description" . "Set true to start a persistent background server/watcher.")))))
     ("required" . ["command"]))
   (lambda (args &optional callback)
     (condition-case-unless-debug err
         (kargu-bash-run
          (kargu--tool-arg args "command")
          (kargu--tool-arg args "cwd" "path" "directory")
          (kargu--tool-arg args "background")
          callback)
       (error
        (let ((err-msg (format "ERROR: %s" (error-message-string err))))
          (if callback (funcall callback err-msg) err-msg)))))))

(kargu-bash-register-tools)

(provide 'kargu/tools/bash)

;;; kargu/tools/bash.el ends here
