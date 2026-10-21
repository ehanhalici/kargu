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
(require 'kargu/permission/execute)
(require 'kargu/tools/process)
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

(defun kargu-git--result (result)
  "Convert process RESULT to an exit-code/output pair."
  (let ((code (plist-get result :code))
        (out (string-trim (or (plist-get result :output) ""))))
    (cond
     ((or (plist-get result :timed-out) (plist-get result :truncated))
      (cons -1 (kargu-process-failure "Git" result)))
     ((eql code 127) (cons 127 "Git executable not found on PATH"))
     ((not (eql code 0)) (cons code (kargu-process-failure "Git" result)))
     (t (cons code out)))))

(defun kargu-git--run (args root callback)
  "Run git with ARGS in project ROOT without waiting.
CALLBACK receives (EXIT-CODE . TRIMMED-OUTPUT); a missing git or a timeout
gives a nonzero code with the reason as output."
  (let* ((task kargu-async--current-task)
         (deliver (lambda (result) (funcall callback (kargu-git--result result))))
         (process (kargu-process-run
                   "git" args (if task (kargu-async-wrap task deliver) deliver)
                   :dir (or root (kargu-permission-project-root)) :timeout kargu-git-timeout)))
    (when (and task (processp process))
      (kargu-async-add-cleanup task (lambda () (kargu-process-cancel process))))
    process))

(defun kargu-git--check-ref (value what)
  "VALUE as a trimmed string, or an error when it cannot be a plain WHAT.
A name that starts with a dash would be read by git as an option."
  (let ((v (and (stringp value) (string-trim value))))
    (cond
     ((or (null v) (string-empty-p v))
      (error "%s is required" what))
     ((or (string-prefix-p "-" v) (string-match-p "[[:space:][:cntrl:]]" v))
      (error "%s `%s' is not a plain reference (no leading dash, no whitespace)" what v))
     (t v))))

;;;; Status ---------------------------------------------------------------

(cl-defstruct (kargu-git--file-status (:constructor kargu-git--make-file-status)
                                      (:copier kargu-git--copy-file-status))
  "One raw path and optional rename source from a porcelain status record."
  path old-path status)

(defconst kargu-git--conflict-states '("DD" "AU" "UD" "UA" "DU" "AA" "UU")
  "Porcelain XY states representing unresolved merge conflicts.")

(defun kargu-git--parse-porcelain-status (records)
  "Parse NUL-separated porcelain RECORDS without unquoting or trimming paths."
  (let (staged unstaged untracked conflicts)
    (while records
      (let* ((record (pop records))
             (state (substring record 0 2))
             (x (aref state 0)) (y (aref state 1))
             (entry (kargu-git--make-file-status :path (substring record 3))))
        (when (or (memq x '(?R ?C)) (memq y '(?R ?C)))
          (unless records (error "Incomplete Git rename record"))
          (setf (kargu-git--file-status-old-path entry) (pop records)))
        (cond
         ((equal state "??") (push entry untracked))
         ((member state kargu-git--conflict-states)
          (setf (kargu-git--file-status-status entry) state)
          (push entry conflicts))
         (t
          (unless (= x ?\s)
            (let ((item (kargu-git--copy-file-status entry)))
              (setf (kargu-git--file-status-status item) (char-to-string x))
              (push item staged)))
          (unless (= y ?\s)
            (setf (kargu-git--file-status-status entry) (char-to-string y))
            (push entry unstaged))))))
    (list :staged staged :unstaged unstaged :untracked untracked :conflicts conflicts)))

(defun kargu-git--display-path (path)
  "Render PATH on one line, quoting control characters but preserving Unicode."
  (if (string-match-p (rx (or cntrl (any "\"\\"))) path)
      (let ((print-escape-newlines t) (print-escape-control-characters t)
            (print-escape-nonascii nil))
        (prin1-to-string path))
    path))

(defun kargu-git--status-entry-text (entry)
  "Format one parsed status ENTRY without changing its raw path."
  (let ((status (kargu-git--file-status-status entry))
        (old (kargu-git--file-status-old-path entry)))
    (concat (when status (concat status " "))
            (when old (concat (kargu-git--display-path old) " -> "))
            (kargu-git--display-path (kargu-git--file-status-path entry)))))

(defun kargu-git--insert-status-section (title items)
  "Insert formatted status section for TITLE with ITEMS into current buffer."
  (insert (format "%s (%d):\n" title (length items)))
  (if (null items)
      (insert "  (none)\n")
    (dolist (item (nreverse items))
      (insert (format "  %s\n" (kargu-git--status-entry-text item))))))

;; Every command function below validates and asks for approval first, then
;; starts git and passes its result string to CALLBACK.  An error after the
;; start reaches CALLBACK as an "ERROR: ..." string.

(defun kargu-git--first-line-branch (header)
  "Branch name in the porcelain -b HEADER line, `HEAD (detached)' when none."
  (let ((name (car (split-string (string-remove-prefix "## " header) "\\.\\.\\." t))))
    (if (or (null name) (string-prefix-p "HEAD (no branch)" name))
        "HEAD (detached)"
      (car (split-string name " \\[" t)))))

(defun kargu-git--format-status (root header records)
  "Format ROOT's status from branch HEADER and parsed file RECORDS."
  (let ((parsed (kargu-git--parse-porcelain-status records)))
    (with-temp-buffer
      (insert (format "Head:     %s\n" (kargu-git--first-line-branch header)))
      (when (string-match-p "\\[" header)
        (insert (format "Tracking: %s\n" (string-trim header))))
      (insert (format "Root:     %s\n\n" root))
      (kargu-git--insert-status-section "Staged changes" (plist-get parsed :staged))
      (insert "\n")
      (kargu-git--insert-status-section "Unstaged changes" (plist-get parsed :unstaged))
      (insert "\n")
      (kargu-git--insert-status-section "Untracked files" (plist-get parsed :untracked))
      (insert "\n")
      (kargu-git--insert-status-section "Merge conflicts" (plist-get parsed :conflicts))
      (buffer-string))))

(defun kargu-git-status (callback &optional root)
  "Pass a structured, Magit-style Git status report for ROOT to CALLBACK."
  (let ((proj-root (or root (kargu-permission-project-root))))
    (kargu-git--run
     '("status" "--porcelain=v1" "-b" "-z") proj-root
     (lambda (res)
       (kargu-process-deliver
        callback
        (lambda ()
          (unless (eql (car res) 0)
            (error "Git status failed: %s" (cdr res)))
          (unless (string-suffix-p "\0" (cdr res))
            (error "Git status returned incomplete records"))
          (let ((lines (split-string (cdr res) "\0" t)))
            (kargu-git--format-status proj-root (or (car lines) "") (cdr lines)))))))))

;;;; Diff -----------------------------------------------------------------

(defun kargu-git--path-args (path root what)
  "Resolve optional PATH under ROOT, using WHAT in refusal messages."
  (when (and (stringp path) (not (string-empty-p (string-trim path))))
    (let ((abs (kargu-permission-assert-within-project path root what)))
      (list "--" (file-relative-name abs root)))))

(defun kargu-git-diff (callback &optional staged path commit)
  "Deliver the Git diff to CALLBACK.
Use the index when STAGED is non-nil, restrict to PATH when provided,
and compare against COMMIT when specified."
  (let* ((root (kargu-permission-project-root))
         (args (append (list "diff" "--no-color")
                       (and staged (list "--cached"))
                       (and (stringp commit)
                            (not (string-empty-p (string-trim commit)))
                            (list (kargu-git--check-ref commit "commit")))
                       (kargu-git--path-args path root "diff path"))))
    (kargu-git--run
     args root
     (lambda (res)
       (kargu-process-deliver
        callback
        (lambda ()
          (if (string-empty-p (cdr res)) "(no diff output)" (cdr res))))))))

;;;; Log ------------------------------------------------------------------

(defun kargu-git-log (callback &optional max-count path)
  "Pass recent commit log to CALLBACK.  MAX-COUNT caps results (default 10).
PATH optionally filters by file path."
  (let* ((root (kargu-permission-project-root))
         (args (append (list "log" "-n" (number-to-string (max 1 (or max-count 10)))
                             "--oneline" "--graph" "--decorate")
                       (kargu-git--path-args path root "log path"))))
    (kargu-git--run
     args root
     (lambda (res)
       (kargu-process-deliver
        callback
        (lambda ()
          (if (string-empty-p (cdr res)) "(no commits found)" (cdr res))))))))

;;;; Changing commands ----------------------------------------------------

(defun kargu-git--change (args root callback ok-text fail-what)
  "Approve changing git ARGS in ROOT and deliver the result to CALLBACK.
OK-TEXT formats successful output; FAIL-WHAT names failure."
  (let ((args (copy-tree args)))
    (kargu-permission-execute
     :command (mapconcat #'shell-quote-argument (cons "git" args) " ")
     :directory root :callback callback
     :start (lambda (done)
              (kargu-git--commit-change args root done ok-text fail-what)))))

(defun kargu-git--commit-change (args root callback ok-text fail-what)
  "Run the changing git ARGS in ROOT and pass the outcome to CALLBACK.
OK-TEXT is a function of the output giving the success text.  FAIL-WHAT
names the operation in the error."
  (kargu-git--run
   args root
   (lambda (res)
     (kargu-git--refresh)
     (kargu-process-deliver
      callback
      (lambda ()
        (if (eql (car res) 0)
            (funcall ok-text (cdr res))
          (error "Git %s failed (exit %d): %s" fail-what (car res) (cdr res))))))))

(defun kargu-git-commit (callback message &optional all)
  "Create a git commit with MESSAGE and pass the outcome to CALLBACK.
ALL optionally stages modified files."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p message
                         "commit message is required: %S" message)
  (let* ((root (kargu-permission-project-root))
         (args (append (list "commit" "-m" (string-trim message))
                       (and all (list "-a")))))
    (kargu-git--change args root callback
                       (lambda (out) (format "Commit successful:\n%s" out))
                       "commit")))

;;;; Stage & Unstage ------------------------------------------------------

(defun kargu-git--relative-paths (paths action proj-root)
  "Project-relative PATHS for ACTION under PROJ-ROOT, in input order.
`.` stays `.'.  Empty entries are dropped."
  (let (clean)
    (dolist (p (kargu-seq-to-list paths))
      (let ((trim (string-trim (format "%s" (or p "")))))
        (unless (string-empty-p trim)
          (push (if (string= trim ".")
                    "."
                  (file-relative-name
                   (kargu-permission-assert-within-project trim proj-root action)
                   proj-root))
                clean))))
    (nreverse clean)))

(defun kargu-git--require-paths (paths action)
  "PATHS, or an error naming ACTION."
  (or paths
      (error "At least one path must be specified to %s" action)))

(defun kargu-git-stage (callback paths)
  "Stage PATHS (string or list of strings) via git add; report to CALLBACK."
  (let* ((root (kargu-permission-project-root))
         (clean (kargu-git--require-paths
                 (kargu-git--relative-paths paths "stage path" root)
                 "stage")))
    (kargu-git--change (append '("add" "--") clean) root callback
                       (lambda (_) (format "Staged: %s" (string-join clean ", ")))
                       "add")))

(defun kargu-git-unstage (callback paths)
  "Unstage PATHS and deliver the result to CALLBACK."
  (let* ((root (kargu-permission-project-root))
         (clean (kargu-git--require-paths
                 (kargu-git--relative-paths paths "unstage path" root)
                 "unstage")))
    (kargu-permission-execute
     :command (mapconcat #'shell-quote-argument (append '("git" "restore" "--staged" "--") clean) " ")
     :directory root :callback callback
     :start (lambda (done) (kargu-git--unstage-approved clean root done)))))

(defun kargu-git--unstage-approved (paths root callback)
  "Unstage approved PATHS in ROOT and deliver the result to CALLBACK."
  (kargu-git--run
   (append '("restore" "--staged" "--") paths) root
   (lambda (res)
     (if (eql (car res) 0)
         (kargu-git--refresh-and-deliver callback (format "Unstaged: %s" (string-join paths ", ")))
       (kargu-git--unstage-fallback paths :root root :callback callback)))))

(cl-defun kargu-git--unstage-fallback (paths &key root callback)
  "Unstage PATHS in ROOT even before the first commit; report to CALLBACK."
  (kargu-git--run
   '("rev-parse" "--verify" "HEAD") root
   (lambda (result)
     (let ((command (pcase (car result)
                      (0 '("reset" "HEAD" "--"))
                      (128 '("rm" "--cached" "-r" "--ignore-unmatch" "--")))))
       (if command
           (kargu-git--commit-change
            (append command paths) root callback
            (lambda (_) (format "Unstaged: %s" (string-join paths ", "))) "unstage")
         (funcall callback (format "ERROR: Cannot inspect Git HEAD: %s" (cdr result))))))))

(defun kargu-git--refresh-and-deliver (callback text)
  "Refresh Magit and pass TEXT to CALLBACK."
  (kargu-git--refresh)
  (funcall callback text))

;;;; Branch ---------------------------------------------------------------

(defconst kargu-git--branch-actions
  '(("create" ("checkout" "-b") "Created and switched to branch %s")
    ("switch" ("checkout") "Switched to branch %s")
    ("delete" ("branch" "-d") "Deleted branch %s"))
  "Branch action -> (GIT-ARGS-BEFORE-NAME SUCCESS-FORMAT).")

(defun kargu-git--branch-change (act name root callback)
  "Run branch action ACT on NAME in ROOT and report to CALLBACK."
  (let* ((spec (cdr (assoc act kargu-git--branch-actions)))
         (branch (kargu-git--check-ref name "branch name"))
         (args (append (nth 0 spec) (list branch))))
    (kargu-git--change args root callback
                       (lambda (_) (format (nth 1 spec) branch))
                       (format "branch %s" act))))

(defun kargu-git-branch (callback action &optional name)
  "Perform branch ACTION on optional NAME and report to CALLBACK."
  (let* ((root (kargu-permission-project-root))
         (act (downcase (string-trim (or action "list")))))
    (cond
     ((string= act "list")
      (kargu-git--run '("branch" "-a") root
                      (lambda (res) (funcall callback (cdr res)))))
     ((assoc act kargu-git--branch-actions)
      (kargu-git--branch-change act name root callback))
     (t
      (error "Unknown branch action: %s; use list, create, switch, or delete" action)))))

;;;; Stash ----------------------------------------------------------------

(cl-defun kargu-git--stash-change (act &key message root callback)
  "Run stash ACT with MESSAGE in ROOT and report to CALLBACK.
Only push is accepted; applying a stash has a separate identity-bound path."
  (let ((args (append (list "stash" act)
                      (and (equal act "push")
                           (stringp message)
                           (not (string-empty-p (string-trim message)))
                           (list "-m" (string-trim message))))))
    (kargu-git--change args root callback #'identity (format "stash %s" act))))

(defconst kargu-git--object-id-regexp
  (rx bos (or (= 40 xdigit) (= 64 xdigit)) eos)
  "Full Git object IDs for the supported repository object formats.")

(defun kargu-git--apply-stash-object (task root object)
  "Ask to apply immutable stash OBJECT under ROOT, owned by TASK."
  (kargu-git--change
   (list "stash" "apply" object) root
   (lambda (result) (kargu-async-finish task result))
   (lambda (output)
     (format "%s\nStash %s retained; delete manually with Git/Magit if desired." output object))
   "stash apply"))

(defun kargu-git--stash-apply (stash root callback)
  "Resolve STASH in ROOT before approval; deliver its application to CALLBACK."
  (unless (and (stringp stash)
               (string-match-p (rx bos "stash@{" (+ digit) "}" eos) stash))
    (user-error "Explicit stash@{N} reference required; list entries with git_stashes"))
  (let* ((resolution-state :pending)
         (task (kargu-async-start
                (lambda (value error)
                  (funcall callback (if error (concat "ERROR: " error) value)))))
         (kargu-async--current-task task))
    (kargu-git--run
     (list "rev-parse" "--verify" (concat stash "^{commit}")) root
     (kargu-async-wrap
      task (lambda (result)
             (when (eq resolution-state :pending)
               (setq resolution-state :answered)
               (let ((object (string-trim (cdr result))))
                 (if (and (zerop (car result))
                          (string-match-p kargu-git--object-id-regexp object))
                     (kargu-git--apply-stash-object task root object)
                   (kargu-async-finish task nil "Cannot resolve the selected stash")))))))))

(cl-defun kargu-git-stash (callback action &optional message &key stash)
  "Perform stash ACTION with optional MESSAGE and report to CALLBACK.
For apply, STASH must name a stash@{N} entry.  Its object ID is captured
before approval.  Pop/drop are refused; delete manually with Git/Magit."
  (let* ((root (kargu-permission-project-root))
         (act (downcase (string-trim (or action "list")))))
    (cond
     ((string= act "list")
      (kargu-git--run '("stash" "list") root
                      (lambda (res)
                        (funcall callback
                                 (if (string-empty-p (cdr res))
                                     "(no stash entries)"
                                   (cdr res))))))
     ((string= act "push")
      (kargu-git--stash-change act :message message :root root :callback callback))
     ((string= act "apply") (kargu-git--stash-apply stash root callback))
     ((member act '("pop" "drop"))
      (user-error "Stash pop/drop are unsafe across approval; use apply, then delete manually with Git/Magit"))
     (t
      (error "Unknown stash action: %s; use list, push, or apply" action)))))

;;;; Blame ----------------------------------------------------------------

(defun kargu-git--blame-range (start-line end-line)
  "Build a validated blame range for START-LINE and END-LINE."
  (let ((start (kargu-to-int start-line))
        (end (kargu-to-int end-line)))
    (unless (and (or (null start-line) (and start (> start 0)))
                 (or (null end-line) (and end (> end 0))))
      (error "Blame line numbers must be positive integers"))
    (when (and start end (> start end))
      (error "Blame start line must not exceed end line"))
    (when (or start end)
      (list (format "-L%d,%s" (or start 1) (or end ""))))))

(defun kargu-git-blame (callback file-path &optional start-line end-line)
  "Pass git blame for FILE-PATH between START-LINE and END-LINE to CALLBACK.
An omitted start defaults to the first line; an omitted end means EOF."
  (unless (and (stringp file-path) (not (string-empty-p (string-trim file-path))))
    (error "File_path is required"))
  (let* ((root (kargu-permission-project-root))
         (abs (kargu-permission-assert-within-project file-path root "blame file"))
         (args (append (list "blame" "--date=short")
                       (kargu-git--blame-range start-line end-line)
                       (list "--" (file-relative-name abs root)))))
    (kargu-git--run
     args root
     (lambda (res)
       (kargu-process-deliver
        callback
        (lambda ()
          (if (eql (car res) 0)
              (cdr res)
            (error "Git blame failed: %s" (cdr res)))))))))

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
                                   ("description" . "File path or pattern to stage (e.g. '.' for all).")))))
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
