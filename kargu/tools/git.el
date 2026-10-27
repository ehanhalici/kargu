;;; git.el --- Magit and Git tools suite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Complete Git tools suite modeled on Magit workflows:
;; status, diff, log, commit, branch, stage, unstage, stash, blame.
;; Integrates with Magit buffers when `magit' is loaded.
;;
;; Public:
;;   `kargu-git-status'
;;   `kargu-git-diff'
;;   `kargu-git-log'
;;   `kargu-git-commit'
;;   `kargu-git-branch'
;;   `kargu-git-stage'
;;   `kargu-git-unstage'
;;   `kargu-git-stash'
;;   `kargu-git-blame'
;;   `kargu-git-magit-status'
;;   `kargu-git-register-tools'

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)

(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/api/tools)
(require 'kargu/permission)
(require 'kargu/tools/process)
(require 'kargu/tools/git/native)
(require 'kargu/async)
(require 'magit nil t)

(defgroup kargu-git nil
  "Git and Magit integration tools."
  :group 'kargu
  :prefix "kargu-git-")

(defcustom kargu-git-timeout nil
  "Optional deadline in seconds for Git commands.
Nil lets hooks and signing finish without a deadline.  Stopping the owning
agent task still cancels the Git process."
  :type '(choice (const :tag "No deadline" nil) (number :tag "Seconds"))
  :group 'kargu-git)

;;;; Helpers --------------------------------------------------------------

(defun kargu-git--refresh ()
  "Refresh Magit status buffers if Magit is loaded."
  (when (fboundp 'magit-refresh)
    (ignore-errors (magit-refresh))))

;;;; Status ---------------------------------------------------------------

(defun kargu-git-status (callback &optional root)
  "Pass a structured, Magit-style Git status report for ROOT to CALLBACK."
  (kargu-git-native-status callback (or root (kargu-permission-project-root))
                           kargu-git-timeout kargu-process-max-bytes))

;;;; Diff -----------------------------------------------------------------

(defun kargu-git-diff (callback &optional staged path commit)
  "Read a native Git diff into CALLBACK, optionally STAGED or for PATH/COMMIT."
  (kargu-git-native-read
   callback (kargu-permission-project-root) kargu-git-timeout kargu-process-max-bytes
   (kargu-bridge--object "operation" "diff" "staged" (if staged t :json-false)
                         "path" (or (kargu-nonempty path) :json-null)
                         "commit" (or (kargu-nonempty commit) :json-null))))

;;;; Log ------------------------------------------------------------------

(defun kargu-git-log (callback &optional max-count path)
  "Pass recent commit log to CALLBACK.  MAX-COUNT caps results (default 10).
PATH optionally filters by file path."
  (kargu-git-native-read
   callback (kargu-permission-project-root) kargu-git-timeout kargu-process-max-bytes
   (kargu-bridge--object "operation" "log" "max_count" (or max-count 10)
                         "path" (or (kargu-nonempty path) :json-null))))

;;;; Changing commands ----------------------------------------------------

(defun kargu-git--mutate (callback query)
  "Deliver approved native QUERY to CALLBACK and refresh the editor view."
  (unless (functionp callback) (error "Native Git mutations require a callback"))
  (kargu-git-native-mutate
   (lambda (text) (kargu-git--refresh) (funcall callback text))
   (kargu-permission-project-root) kargu-git-timeout kargu-process-max-bytes query))

(defun kargu-git-commit (callback message &optional all)
  "Create an approved native commit with MESSAGE and optional ALL to CALLBACK."
  (kargu-git--mutate callback (kargu-bridge--object "operation" "commit" "message" message
                                                 "all" (if all t :json-false))))

(defun kargu-git-stage (callback paths)
  "Stage literal PATHS through the native approval ledger into CALLBACK."
  (kargu-git--mutate callback (kargu-bridge--object "operation" "stage" "paths" (vconcat (kargu-seq-to-list paths)))))

(defun kargu-git-unstage (callback paths)
  "Unstage literal PATHS through one prepared native action into CALLBACK."
  (kargu-git--mutate callback (kargu-bridge--object "operation" "unstage" "paths" (vconcat (kargu-seq-to-list paths)))))

(defun kargu-git-branch (callback action &optional name)
  "Perform branch ACTION on NAME through native Git into CALLBACK."
  (if (equal (or action "list") "list")
      (kargu-git-native-read callback (kargu-permission-project-root) kargu-git-timeout kargu-process-max-bytes
                             (kargu-bridge--object "operation" "branches"))
    (kargu-git--mutate callback (kargu-bridge--object "operation" (concat "branch_" action) "name" name))))

(cl-defun kargu-git-stash (callback action &optional message &key stash)
  "Perform stash ACTION with MESSAGE or explicit STASH through native CALLBACK."
  (pcase (or action "list")
    ("list" (kargu-git-native-read callback (kargu-permission-project-root) kargu-git-timeout kargu-process-max-bytes
                                    (kargu-bridge--object "operation" "stashes")))
    ("push" (kargu-git--mutate callback (kargu-bridge--object "operation" "stash_push" "message" (or (kargu-nonempty message) :json-null))))
    ("apply" (kargu-git--mutate callback (kargu-bridge--object "operation" "stash_apply" "stash" stash)))
    (_ (user-error "Use stash list, push or explicit apply; pop/drop require manual Git/Magit"))))

;;;; Blame ----------------------------------------------------------------

(defun kargu-git-blame (callback file-path &optional start-line end-line)
  "Read native blame for FILE-PATH/START-LINE/END-LINE into CALLBACK.
Range parsing, Git argv and executable configuration policy belong to Rust."
  (kargu-git-native-read
   callback (kargu-permission-project-root) kargu-git-timeout kargu-process-max-bytes
   (kargu-bridge--object "operation" "blame" "path" file-path
                         "from" (or start-line :json-null)
                         "to" (or end-line :json-null))))

;;;; Interactive Magit launcher -------------------------------------------

(defun kargu-git-magit-status ()
  "Open Magit status buffer for current project."
  (interactive)
  (cond
   ((fboundp 'magit-status-setup-buffer)
    (magit-status-setup-buffer (kargu-permission-project-root)))
   ((fboundp 'magit-status)
    (with-no-warnings (magit-status (kargu-permission-project-root))))
   (t
    (message "Magit package is not installed; install magit to view interactive git buffers"))))

;;;; Register tools -------------------------------------------------------

(defun kargu-git--executor (body)
  "Tool executor for a git tool.
BODY takes the decoded arguments and a DONE function, and starts the git
work; DONE receives the result string.  Changing commands approve their
prepared arguments without replaying BODY."
  (lambda (args &optional callback)
    (if callback
        (let* ((state :pending)
               (done (lambda (result)
                       (when (eq state :pending)
                         (setq state :done)
                         (funcall callback result)))))
          (condition-case-unless-debug error
              (funcall body args done)
            (error (funcall done (format "ERROR: %s" (error-message-string error))))))
      "ERROR: git tools run asynchronously; call them with a callback")))

(defconst kargu-git--tool-specs
  (list
   (list
    "git_branches"
    "List local and remote Git branches. Read-only, available in every mode."
    '(("type" . "object") ("properties" . :json-empty-object))
    (kargu-git--executor
     (lambda (_args done) (kargu-git-branch done "list"))))
   (list
    "git_stashes"
    "List Git stash entries and their indices. Read-only, available in every mode."
    '(("type" . "object") ("properties" . :json-empty-object))
    (kargu-git--executor
     (lambda (_args done) (kargu-git-stash done "list"))))
   (list
    "git_status"
    "Show structured Git repository status (branch, upstream, staged, unstaged, untracked). Magit-style. Read-only, available in all modes."
    '(("type" . "object")
      ("properties" . ()))
    (kargu-git--executor
     (lambda (_args done) (kargu-git-status done))))
   (list
    "git_diff"
    "Show Git diff (staged changes with staged:true, unstaged, or specific commit/path). Read-only, available in all modes."
    '(("type" . "object")
      ("properties" . (("staged" . (("type" . "boolean")
                                    ("description" . "If true, show staged changes (--cached).")))
                       ("path" . (("type" . "string")
                                  ("description" . "Optional file or directory path to diff.")))
                       ("commit" . (("type" . "string")
                                    ("description" . "Optional commit hash or reference.")))))
      ("required" . []))
    (kargu-git--executor
     (lambda (args done)
       (kargu-git-diff done
                       (kargu--tool-flag args "staged")
                       (kargu--tool-arg args "path" "file")
                       (kargu--tool-arg args "commit" "rev")))))
   (list
    "git_log"
    "Show recent Git commit log. Read-only, available in all modes."
    '(("type" . "object")
      ("properties" . (("max_count" . (("type" . "integer")
                                       ("description" . "Maximum commits to show (default 10).")))
                       ("path" . (("type" . "string")
                                  ("description" . "Optional file path to limit history to.")))))
      ("required" . []))
    (kargu-git--executor
     (lambda (args done)
       (kargu-git-log done
                      (kargu-to-int (kargu--tool-arg args "max_count" "limit" "n"))
                      (kargu--tool-arg args "path" "file")))))
   (list
    "git_commit"
    "Record staged changes in repository. Agent mode only."
    '(("type" . "object")
      ("properties" . (("message" . (("type" . "string")
                                     ("description" . "Commit message.")))
                       ("all" . (("type" . "boolean")
                                 ("description" . "If true, automatically stage all modified tracked files.")))))
      ("required" . ["message"]))
    (kargu-git--executor
     (lambda (args done)
       (kargu-git-commit done
                         (kargu--tool-arg args "message" "msg")
                         (kargu--tool-flag args "all")))))
   (list
    "git_stage"
    "Stage file(s) into git index (git add). Agent mode only."
    '(("type" . "object")
      ("properties" . (("paths" . (("type" . "string")
                                   ("description" . "Literal file or directory path to stage (e.g. '.' for all).")))))
      ("required" . ["paths"]))
    (kargu-git--executor
     (lambda (args done)
       (kargu-git-stage done
                        (kargu--tool-arg args "paths" "path" "file" "files")))))
   (list
    "git_unstage"
    "Unstage file(s) from git index (git restore --staged). Agent mode only."
    '(("type" . "object")
      ("properties" . (("paths" . (("type" . "string")
                                   ("description" . "File path to unstage.")))))
      ("required" . ["paths"]))
    (kargu-git--executor
     (lambda (args done)
       (kargu-git-unstage done
                          (kargu--tool-arg args "paths" "path" "file" "files")))))
   (list
    "git_branch"
    "Manage Git branches (list, create, switch, delete). Agent mode only."
    '(("type" . "object")
      ("properties" . (("action" . (("type" . "string")
                                    ("description" . "Action: list, create, switch, or delete.")))
                       ("name" . (("type" . "string")
                                  ("description" . "Branch name.")))))
      ("required" . ["action"]))
    (kargu-git--executor
     (lambda (args done)
       (kargu-git-branch done
                         (kargu--tool-arg args "action")
                         (kargu--tool-arg args "name" "branch")))))
   (list
    "git_stash"
    "Stash changes (push, apply, list). Apply pins the selected object before approval and never deletes it. Pop/drop are refused; delete manually with Git/Magit. Agent mode only."
    '(("type" . "object")
      ("properties" . (("action" . (("type" . "string")
                                    ("description" . "Action: push, apply, or list. Pop/drop are unsupported.")
                                    ("enum" . ["push" "apply" "list"])))
                       ("message" . (("type" . "string")
                                     ("description" . "Optional stash message for push.")))
                       ("stash" . (("type" . "string")
                                   ("description" . "Required for apply: explicit stash@{N} reference, for example stash@{1}.")))))
      ("required" . ["action"]))
    (kargu-git--executor
     (lambda (args done)
       (kargu-git-stash done
                        (kargu--tool-arg args "action")
                        (kargu--tool-arg args "message" "msg")
                        :stash (kargu--tool-arg args "stash")))))
   (list
    "git_blame"
    "Show line-by-line Git commit and author information for a file. Read-only, available in all modes."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "File path to blame.")))
                       ("start_line" . (("type" . "integer")
                                        ("minimum" . 1)
                                        ("description" . "Optional start line, defaults to 1.")))
                       ("end_line" . (("type" . "integer")
                                      ("minimum" . 1)
                                      ("description" . "Optional end line, defaults to end of file.")))))
      ("required" . ["file_path"]))
    (kargu-git--executor
     (lambda (args done)
       (kargu-git-blame done
                        (kargu--tool-arg args "file_path" "path" "file")
                        (kargu--tool-arg args "start_line")
                        (kargu--tool-arg args "end_line"))))))
  "Tool schemas and executors for git operations.")

(defun kargu-git-register-tools ()
  "Register the git tools."
  (kargu-register-tools kargu-git--tool-specs))

(provide 'kargu/tools/git)

;;; git.el ends here
