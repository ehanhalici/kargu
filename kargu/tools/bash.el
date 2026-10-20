;;; bash.el --- Shell command tool -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; `bash' tool: run a shell command with a timeout.  Advertised
;; only in agent mode (mutating-tools list).  Requires: `kargu/core',
;; `kargu/api/tools'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/api/tools)
(require 'kargu/permission)
(require 'kargu/tools/process)

(defgroup kargu-bash nil
  "Shell command tool."
  :group 'kargu
  :prefix "kargu-bash-")

(defcustom kargu-bash-timeout nil
  "Optional positive Bash deadline in seconds; nil allows unlimited duration."
  :type '(choice (const :tag "Unlimited duration" nil) number)
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

(require 'kargu/tools/bash/jobs)

(defun kargu-bash--manage-process (command)
  "Handle shell job management COMMAND without starting a new process."
  (kargu-bash-manage-job command))

(defun kargu-bash--resolve-shell ()
  "Find Bash, falling back to POSIX sh without using the login shell."
  (or (executable-find "bash")
      (executable-find "sh")
      (error "Bash tool requires an executable bash or sh")))

(defun kargu-bash--run-background (command dir shell)
  "Start persistent COMMAND in DIR using SHELL and return its job ID."
  (kargu-bash-start-job command dir shell :background t))

(defun kargu-bash--run-async (command dir shell callback)
  "Run COMMAND in DIR using SHELL, delivering output to CALLBACK."
  (kargu-bash-start-job command dir shell :callback callback))

(defun kargu-bash--manage-kill (id)
  "Cancel and forget shell job ID."
  (kargu-bash-manage-job (concat "kill " id)))

(defun kargu-bash--rejection-text (command dir root)
  "Model-facing text for a COMMAND in DIR the user refused (ROOT is the project)."
  (concat "Permission denied: Command execution was rejected by the user.\n"
          "  - Rejected command: '" command "'\n"
          "  - Working directory: '" dir "'\n"
          "  - Allowed project root: '" root "'\n"
          "  - Reason: The user chose not to grant execution permission for this shell command.\n"
          "  - Guidance: Do not repeatedly execute the identical command without user clarification. Consider an alternative approach that works strictly within '" root "' or ask the user for guidance."))

(defun kargu-bash--start (command dir background callback)
  "Start approved COMMAND in DIR and deliver output to CALLBACK.
Return a persistent process identifier when BACKGROUND is non-nil."
  (let ((shell (kargu-bash--resolve-shell)))
    (cond
     (background
      (let ((res (kargu-bash--run-background command dir shell)))
        (if callback (funcall callback res) res)))
     (callback
      (kargu-bash--run-async command dir shell callback))
     (t
      (error "Bash commands never run synchronously: pass a CALLBACK")))))

(defun kargu-bash--run-async-approved (command dir root background callback)
  "Approve COMMAND in DIR within ROOT and deliver output to CALLBACK.
Start a persistent process when BACKGROUND is non-nil."
  (kargu-permission-request-approval-async
   command dir (kargu-permission-command-risks command)
   (lambda (approved)
     (if approved
         (kargu-bash--start command dir background callback)
       (funcall callback
                (format "ERROR: %s" (kargu-bash--rejection-text command dir root)))))))

(defun kargu-bash-run (command &optional cwd background callback)
  "Run COMMAND in CWD, capturing stdout and stderr.
With CALLBACK the call returns at once: approval, execution and the result
all arrive asynchronously.  Without CALLBACK only background processes and
process management (`list', `status', `kill') are served, since Emacs never
waits for a command.
When BACKGROUND is non-nil, start a persistent background process.
Strictly validates that CWD and all path arguments stay within project root."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p command
                         "command must be a non-empty string: %S" command)
  (let ((mgmt (kargu-bash--manage-process command)))
    (if mgmt
        (if callback (funcall callback mgmt) mgmt)
      (let* ((root (kargu-permission-project-root))
             (dir (kargu-bash--cwd cwd)))
        (kargu-permission-validate-command command root dir)
        (cond
         (callback
          (kargu-bash--run-async-approved command dir root background callback))
         ((kargu-permission-request-approval
           command dir (kargu-permission-command-risks command))
          (kargu-bash--start command dir background nil))
         (t (error "%s" (kargu-bash--rejection-text command dir root))))))))

(defun kargu-bash-register-tools ()
  "Register the bash tool."
  (kargu-register-tool
   "bash"
   "Run a project shell command asynchronously with no default duration limit. Agent mode only. Output is bounded without terminating the job. Use list/status <id>/kill <id> for monitoring and cancellation. Set background=true for persistent servers or watchers; ordinary long builds can remain foreground jobs."
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
          (kargu--tool-flag args "background")
          callback)
       (error
        (let ((err-msg (format "ERROR: %s" (error-message-string err))))
          (if callback (funcall callback err-msg) err-msg)))))))

(provide 'kargu/tools/bash)

;;; bash.el ends here
