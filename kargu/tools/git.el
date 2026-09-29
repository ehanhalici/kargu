;;; kargu/tools/git.el --- Magit and Git tools suite -*- lexical-binding: t; -*-

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

(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/api)
(require 'kargu/api/tools)
(require 'kargu/permission)
(require 'kargu/tools/process)
(require 'magit nil t)

(defgroup kargu-git nil
  "Git and Magit integration tools."
  :group 'kargu
  :prefix "kargu-git-")

;;;; Helpers --------------------------------------------------------------

(defun kargu-git--refresh ()
  "Refresh Magit status buffers if Magit is loaded."
  (when (fboundp 'magit-refresh)
    (ignore-errors (magit-refresh))))

(defun kargu-git--run (args root callback)
  "Run git with ARGS in project ROOT without waiting.
CALLBACK receives (EXIT-CODE . TRIMMED-OUTPUT); a missing git or a timeout
gives a nonzero code with the reason as output."
  (kargu-process-run
   "git" args
   (lambda (result)
     (let ((code (plist-get result :code))
           (out (string-trim (or (plist-get result :output) ""))))
       (funcall callback
                (cond
                 ((plist-get result :timed-out)
                  (cons -1 (kargu-process-failure "git" result)))
                 ((eql code 127) (cons 127 "git executable not found on PATH"))
                 (t (cons code out))))))
   :dir (or root (kargu-permission-project-root))))

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

(defun kargu-git--approve (description root)
  "Ask the human to approve the git change DESCRIPTION in ROOT, or signal."
  (unless (kargu-permission-approve (concat "git " description) root)
    (error "git %s was not approved by the user" description)))

;;;; Status ---------------------------------------------------------------

(defun kargu-git--parse-porcelain-status (lines)
  "Parse porcelain status LINES into a plist (:staged :unstaged :untracked)."
  (let (staged unstaged untracked)
    (dolist (line lines)
      (when (>= (length line) 3)
        (let ((x (aref line 0))
              (y (aref line 1))
              (path (string-trim (substring line 3))))
          (cond
           ((and (= x ??) (= y ??))
            (push path untracked))
           (t
            (unless (= x ?\s)
              (push (format "%c %s" x path) staged))
            (unless (= y ?\s)
              (push (format "%c %s" y path) unstaged)))))))
    (list :staged staged :unstaged unstaged :untracked untracked)))

(defun kargu-git--insert-status-section (title items)
  "Insert formatted status section for TITLE with ITEMS into current buffer."
  (insert (format "%s (%d):\n" title (length items)))
  (if (null items)
      (insert "  (none)\n")
    (dolist (item (nreverse items))
      (insert (format "  %s\n" item)))))

;; Every command function below validates and asks for approval first, then
;; starts git and passes its result string to CALLBACK.  An error after the
;; start reaches CALLBACK as an "ERROR: ..." string.

(defun kargu-git--first-line-branch (header)
  "Branch name in the porcelain -b HEADER line, `HEAD (detached)' when none."
  (let ((name (car (split-string (string-remove-prefix "## " header) "\\.\\.\\." t))))
    (if (or (null name) (string-prefix-p "HEAD (no branch)" name))
        "HEAD (detached)"
      (car (split-string name " \\[" t)))))

(defun kargu-git--format-status (root header lines)
  "Status report for ROOT from porcelain HEADER line and file LINES."
  (let ((parsed (kargu-git--parse-porcelain-status lines)))
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
      (buffer-string))))

(defun kargu-git-status (callback &optional root)
  "Pass a structured, Magit-style Git status report for ROOT to CALLBACK."
  (let ((proj-root (or root (kargu-permission-project-root))))
    (kargu-git--run
     '("status" "--porcelain=v1" "-b") proj-root
     (lambda (res)
       (kargu-process-deliver
        callback
        (lambda ()
          (unless (eql (car res) 0)
            (error "git status failed: %s" (cdr res)))
          (let ((lines (split-string (cdr res) "\n" t)))
            (kargu-git--format-status proj-root (or (car lines) "") (cdr lines)))))))))

;;;; Diff -----------------------------------------------------------------

(defun kargu-git--path-args (path root what)
  "Arguments limiting a command to PATH under ROOT, or nil for no PATH."
  (when (and (stringp path) (not (string-empty-p (string-trim path))))
    (let ((abs (kargu-permission-assert-within-project path root what)))
      (list "--" (file-relative-name abs root)))))

(defun kargu-git-diff (callback &optional staged path commit)
  "Pass git diff to CALLBACK.  STAGED non-nil diffs staged changes.
PATH optionally limits diff to a file.  COMMIT optionally specifies revision."
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
          (error "git %s failed (exit %d): %s" fail-what (car res) (cdr res))))))))

(defun kargu-git-commit (callback message &optional all)
  "Create a git commit with MESSAGE and pass the outcome to CALLBACK.
ALL optionally stages modified files."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p message
                         "commit message is required: %S" message)
  (let* ((root (kargu-permission-project-root))
         (args (append (list "commit" "-m" (string-trim message))
                       (and all (list "-a")))))
    (kargu-git--approve (string-join (cons "commit" (cdr args)) " ") root)
    (kargu-git--change args root callback
                       (lambda (out) (format "Commit successful:\n%s" out))
                       "commit")))

;;;; Stage & Unstage ------------------------------------------------------

(defun kargu-git--relative-paths (paths action proj-root)
  "Project-relative PATHS for ACTION under PROJ-ROOT, in input order.
`.` stays `.'.  Empty entries are dropped."
  (let (clean)
    (dolist (p (if (listp paths) paths (list paths)))
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
      (error "at least one path must be specified to %s" action)))

(defun kargu-git-stage (callback paths)
  "Stage PATHS (string or list of strings) via git add; report to CALLBACK."
  (let* ((root (kargu-permission-project-root))
         (clean (kargu-git--require-paths
                 (kargu-git--relative-paths paths "stage path" root)
                 "stage")))
    (kargu-git--approve (concat "add -- " (string-join clean " ")) root)
    (kargu-git--change (append '("add" "--") clean) root callback
                       (lambda (_) (format "Staged: %s" (string-join clean ", ")))
                       "add")))

(defun kargu-git-unstage (callback paths)
  "Unstage PATHS (string or list of strings) via git restore --staged."
  (let* ((root (kargu-permission-project-root))
         (clean (kargu-git--require-paths
                 (kargu-git--relative-paths paths "unstage path" root)
                 "unstage")))
    (kargu-git--approve (concat "restore --staged -- " (string-join clean " ")) root)
    (kargu-git--run
     (append '("restore" "--staged" "--") clean) root
     (lambda (res)
       (if (eql (car res) 0)
           (kargu-git--refresh-and-deliver callback (format "Unstaged: %s" (string-join clean ", ")))
         (kargu-git--change (append '("reset" "HEAD" "--") clean) root callback
                            (lambda (_) (format "Unstaged: %s" (string-join clean ", ")))
                            "unstage"))))))

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
  "Run the changing branch action ACT on NAME in ROOT after approval."
  (let* ((spec (cdr (assoc act kargu-git--branch-actions)))
         (branch (kargu-git--check-ref name "branch name"))
         (args (append (nth 0 spec) (list branch))))
    (kargu-git--approve (string-join args " ") root)
    (kargu-git--change args root callback
                       (lambda (_) (format (nth 1 spec) branch))
                       (format "branch %s" act))))

(defun kargu-git-branch (callback action &optional name)
  "Perform branch ACTION: list, create, switch, or delete.  NAME is branch."
  (let* ((root (kargu-permission-project-root))
         (act (downcase (string-trim (or action "list")))))
    (cond
     ((string= act "list")
      (kargu-git--run '("branch" "-a") root
                      (lambda (res) (funcall callback (cdr res)))))
     ((assoc act kargu-git--branch-actions)
      (kargu-git--branch-change act name root callback))
     (t
      (error "unknown branch action: %s; use list, create, switch, or delete" action)))))

;;;; Stash ----------------------------------------------------------------

(defun kargu-git--stash-change (act message root callback)
  "Run stash ACT (push, pop, drop) with optional MESSAGE after approval."
  (let ((args (append (list "stash" act)
                      (and (equal act "push")
                           (stringp message)
                           (not (string-empty-p (string-trim message)))
                           (list "-m" (string-trim message))))))
    (kargu-git--approve (string-join args " ") root)
    (kargu-git--change args root callback #'identity (format "stash %s" act))))

(defun kargu-git-stash (callback action &optional message)
  "Perform stash ACTION: push, pop, list, or drop.  MESSAGE is optional label."
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
     ((member act '("push" "pop" "drop"))
      (kargu-git--stash-change act message root callback))
     (t
      (error "unknown stash action: %s; use list, push, pop, or drop" action)))))

;;;; Blame ----------------------------------------------------------------

(defun kargu-git-blame (callback file-path &optional start-line end-line)
  "Pass git blame for FILE-PATH between START-LINE and END-LINE to CALLBACK."
  (unless (and (stringp file-path) (not (string-empty-p (string-trim file-path))))
    (error "file_path is required"))
  (let* ((root (kargu-permission-project-root))
         (abs (kargu-permission-assert-within-project file-path root "blame file"))
         (args (append (list "blame" "--date=short")
                       (and start-line end-line
                            (list (format "-L%d,%d" start-line end-line)))
                       (list "--" (file-relative-name abs root)))))
    (kargu-git--run
     args root
     (lambda (res)
       (kargu-process-deliver
        callback
        (lambda ()
          (if (eql (car res) 0)
              (cdr res)
            (error "git blame failed: %s" (cdr res)))))))))

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
work; DONE receives the result string.  The executor needs a callback:
git never runs while Emacs waits.  A changing command asks for approval
through `kargu-permission-approve', which may re-run BODY after the answer."
  (lambda (args &optional callback)
    (if callback
        (kargu-permission-call-async
         (lambda (done) (funcall body args done))
         callback)
      "ERROR: git tools run asynchronously; call them with a callback")))

(defun kargu-git-register-tools ()
  "Register Git and Magit tools with Kargu."
  ;; 1. git_status
  (kargu-register-tool
   "git_status"
   "Show structured Git repository status (branch, upstream, staged, unstaged, untracked). Magit-style. Read-only, available in all modes."
   '(("type" . "object")
     ("properties" . ()))
   (kargu-git--executor
    (lambda (_args done) (kargu-git-status done))))

  ;; 2. git_diff
  (kargu-register-tool
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

  ;; 3. git_log
  (kargu-register-tool
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

  ;; 4. git_commit
  (kargu-register-tool
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

  ;; 5. git_stage
  (kargu-register-tool
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

  ;; 6. git_unstage
  (kargu-register-tool
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

  ;; 7. git_branch
  (kargu-register-tool
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

  ;; 8. git_stash
  (kargu-register-tool
   "git_stash"
   "Stash changes in a dirty working directory (push, pop, list, drop). Agent mode only."
   '(("type" . "object")
     ("properties" . (("action" . (("type" . "string")
                                   ("description" . "Action: push, pop, list, or drop.")))
                      ("message" . (("type" . "string")
                                    ("description" . "Optional stash message for push.")))))
     ("required" . ["action"]))
   (kargu-git--executor
    (lambda (args done)
      (kargu-git-stash done
       (kargu--tool-arg args "action")
       (kargu--tool-arg args "message" "msg")))))

  ;; 9. git_blame
  (kargu-register-tool
   "git_blame"
   "Show line-by-line Git commit and author information for a file. Read-only, available in all modes."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "File path to blame.")))
                      ("start_line" . (("type" . "integer")
                                       ("description" . "Optional start line.")))
                      ("end_line" . (("type" . "integer")
                                     ("description" . "Optional end line.")))))
     ("required" . ["file_path"]))
   (kargu-git--executor
    (lambda (args done)
      (kargu-git-blame done
       (kargu--tool-arg args "file_path" "path" "file")
       (kargu-to-int (kargu--tool-arg args "start_line"))
       (kargu-to-int (kargu--tool-arg args "end_line")))))))

(kargu-git-register-tools)

(provide 'kargu/tools/git)

;;; kargu/tools/git.el ends here
