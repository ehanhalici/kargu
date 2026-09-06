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

(defun kargu-git--run (args &optional root)
  "Run git with ARGS in project ROOT.  Return (EXIT-CODE . OUTPUT)."
  (let* ((proj-root (or root (kargu-permission-project-root)))
         (default-directory proj-root)
         (git (executable-find "git")))
    (unless git
      (error "git executable not found on PATH"))
    (with-temp-buffer
      (let ((code (apply #'call-process git nil t nil args)))
        (cons code (string-trim (buffer-string)))))))

;;;; Status ---------------------------------------------------------------

(defun kargu-git-status (&optional root)
  "Return a structured, Magit-style Git status report for ROOT."
  (let* ((proj-root (or root (kargu-permission-project-root)))
         ;; 1. Branch info
         (branch-res (kargu-git--run '("branch" "--show-current") proj-root))
         (branch (if (string-empty-p (cdr branch-res)) "HEAD (detached)" (cdr branch-res)))
         ;; 2. Tracking upstream info
         (up-res (kargu-git--run '("status" "-sb") proj-root))
         (up-line (car (split-string (cdr up-res) "\n" t)))
         ;; 3. Porcelain status
         (porc-res (kargu-git--run '("status" "--porcelain=v1") proj-root))
         (lines (split-string (cdr porc-res) "\n" t))
         staged unstaged untracked)
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
    (with-temp-buffer
      (insert (format "Head:     %s\n" branch))
      (when (and up-line (string-match-p "\\[" up-line))
        (insert (format "Tracking: %s\n" (string-trim up-line))))
      (insert (format "Root:     %s\n\n" proj-root))
      ;; Staged
      (insert (format "Staged changes (%d):\n" (length staged)))
      (if (null staged)
          (insert "  (none)\n")
        (dolist (item (nreverse staged))
          (insert (format "  %s\n" item))))
      ;; Unstaged
      (insert (format "\nUnstaged changes (%d):\n" (length unstaged)))
      (if (null unstaged)
          (insert "  (none)\n")
        (dolist (item (nreverse unstaged))
          (insert (format "  %s\n" item))))
      ;; Untracked
      (insert (format "\nUntracked files (%d):\n" (length untracked)))
      (if (null untracked)
          (insert "  (none)\n")
        (dolist (item (nreverse untracked))
          (insert (format "  %s\n" item))))
      (buffer-string))))

;;;; Diff -----------------------------------------------------------------

(defun kargu-git-diff (&optional staged path commit)
  "Return git diff.  When STAGED is non-nil, diff staged changes.
PATH optionally limits diff to a file.  COMMIT optionally specifies revision."
  (let* ((proj-root (kargu-permission-project-root))
         (args (list "diff" "--no-color")))
    (when staged (setq args (append args (list "--cached"))))
    (when (and (stringp commit) (not (string-empty-p (string-trim commit))))
      (setq args (append args (list (string-trim commit)))))
    (when (and (stringp path) (not (string-empty-p (string-trim path))))
      (let ((abs (kargu-permission-assert-within-project path proj-root "diff path")))
        (setq args (append args (list "--" (file-relative-name abs proj-root))))))
    (let* ((res (kargu-git--run args proj-root))
           (out (cdr res)))
      (if (string-empty-p out)
          "(no diff output)"
        out))))

;;;; Log ------------------------------------------------------------------

(defun kargu-git-log (&optional max-count path)
  "Return recent commit log.  MAX-COUNT caps results (default 10).
PATH optionally filters by file path."
  (let* ((proj-root (kargu-permission-project-root))
         (cap (number-to-string (max 1 (or max-count 10))))
         (args (list "log" "-n" cap "--oneline" "--graph" "--decorate")))
    (when (and (stringp path) (not (string-empty-p (string-trim path))))
      (let ((abs (kargu-permission-assert-within-project path proj-root "log path")))
        (setq args (append args (list "--" (file-relative-name abs proj-root))))))
    (let* ((res (kargu-git--run args proj-root))
           (out (cdr res)))
      (if (string-empty-p out)
          "(no commits found)"
        out))))

;;;; Commit ---------------------------------------------------------------

(defun kargu-git-commit (message &optional all)
  "Create a git commit with MESSAGE.  ALL optionally stages modified files."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p message
                         "commit message is required: %S" message)
  (let* ((proj-root (kargu-permission-project-root))
         (args (list "commit" "-m" (string-trim message))))
    (when all (setq args (append args (list "-a"))))
    (let* ((res (kargu-git--run args proj-root))
           (code (car res))
           (out (cdr res)))
      (kargu-git--refresh)
      (if (= code 0)
          (format "Commit successful:\n%s" out)
        (error "git commit failed (exit %d): %s" code out)))))

;;;; Stage & Unstage ------------------------------------------------------

(defun kargu-git-stage (paths)
  "Stage PATHS (string or list of strings) via git add."
  (let* ((proj-root (kargu-permission-project-root))
         (path-list (if (listp paths) paths (list paths)))
         (clean-paths nil))
    (dolist (p path-list)
      (let ((trim (string-trim (format "%s" p))))
        (when (not (string-empty-p trim))
          (if (string= trim ".")
              (push "." clean-paths)
            (let ((abs (kargu-permission-assert-within-project trim proj-root "stage path")))
              (push (file-relative-name abs proj-root) clean-paths))))))
    (unless clean-paths
      (error "at least one path must be specified to stage"))
    (let* ((args (append (list "add" "--") (nreverse clean-paths)))
           (res (kargu-git--run args proj-root))
           (code (car res))
           (out (cdr res)))
      (kargu-git--refresh)
      (if (= code 0)
          (format "Staged: %s" (string-join clean-paths ", "))
        (error "git add failed (exit %d): %s" code out)))))

(defun kargu-git-unstage (paths)
  "Unstage PATHS (string or list of strings) via git restore --staged."
  (let* ((proj-root (kargu-permission-project-root))
         (path-list (if (listp paths) paths (list paths)))
         (clean-paths nil))
    (dolist (p path-list)
      (let ((trim (string-trim (format "%s" p))))
        (when (not (string-empty-p trim))
          (if (string= trim ".")
              (push "." clean-paths)
            (let ((abs (kargu-permission-assert-within-project trim proj-root "unstage path")))
              (push (file-relative-name abs proj-root) clean-paths))))))
    (unless clean-paths
      (error "at least one path must be specified to unstage"))
    ;; Try git restore --staged, fallback to git reset HEAD
    (let* ((args (append (list "restore" "--staged" "--") (nreverse clean-paths)))
           (res (kargu-git--run args proj-root)))
      (when (/= (car res) 0)
        (setq res (kargu-git--run (append (list "reset" "HEAD" "--") clean-paths) proj-root)))
      (kargu-git--refresh)
      (if (= (car res) 0)
          (format "Unstaged: %s" (string-join clean-paths ", "))
        (error "git unstage failed: %s" (cdr res))))))

;;;; Branch ---------------------------------------------------------------

(defun kargu-git-branch (action &optional name)
  "Perform branch ACTION: list, create, switch, or delete.  NAME is branch."
  (let* ((proj-root (kargu-permission-project-root))
         (act (downcase (string-trim (or action "list")))))
    (cond
     ((string= act "list")
      (cdr (kargu-git--run '("branch" "-a") proj-root)))
     ((string= act "create")
      (unless (and (stringp name) (not (string-empty-p (string-trim name))))
        (error "branch name is required for create"))
      (let* ((res (kargu-git--run (list "checkout" "-b" (string-trim name)) proj-root)))
        (kargu-git--refresh)
        (if (= (car res) 0)
            (format "Created and switched to branch %s" name)
          (error "git branch create failed: %s" (cdr res)))))
     ((string= act "switch")
      (unless (and (stringp name) (not (string-empty-p (string-trim name))))
        (error "branch name is required for switch"))
      (let* ((res (kargu-git--run (list "checkout" (string-trim name)) proj-root)))
        (kargu-git--refresh)
        (if (= (car res) 0)
            (format "Switched to branch %s" name)
          (error "git switch failed: %s" (cdr res)))))
     ((string= act "delete")
      (unless (and (stringp name) (not (string-empty-p (string-trim name))))
        (error "branch name is required for delete"))
      (let* ((res (kargu-git--run (list "branch" "-d" (string-trim name)) proj-root)))
        (kargu-git--refresh)
        (if (= (car res) 0)
            (format "Deleted branch %s" name)
          (error "git branch delete failed: %s" (cdr res)))))
     (t
      (error "unknown branch action: %s; use list, create, switch, or delete" action)))))

;;;; Stash ----------------------------------------------------------------

(defun kargu-git-stash (action &optional message)
  "Perform stash ACTION: push, pop, list, or drop.  MESSAGE is optional label."
  (let* ((proj-root (kargu-permission-project-root))
         (act (downcase (string-trim (or action "list")))))
    (cond
     ((string= act "list")
      (let ((out (cdr (kargu-git--run '("stash" "list") proj-root))))
        (if (string-empty-p out) "(no stash entries)" out)))
     ((string= act "push")
      (let* ((args (list "stash" "push"))
             (_ (when (and (stringp message) (not (string-empty-p (string-trim message))))
                  (setq args (append args (list "-m" (string-trim message))))))
             (res (kargu-git--run args proj-root)))
        (kargu-git--refresh)
        (if (= (car res) 0) (cdr res) (error "git stash push failed: %s" (cdr res)))))
     ((string= act "pop")
      (let ((res (kargu-git--run '("stash" "pop") proj-root)))
        (kargu-git--refresh)
        (if (= (car res) 0) (cdr res) (error "git stash pop failed: %s" (cdr res)))))
     ((string= act "drop")
      (let ((res (kargu-git--run '("stash" "drop") proj-root)))
        (kargu-git--refresh)
        (if (= (car res) 0) (cdr res) (error "git stash drop failed: %s" (cdr res)))))
     (t
      (error "unknown stash action: %s; use list, push, pop, or drop" action)))))

;;;; Blame ----------------------------------------------------------------

(defun kargu-git-blame (file-path &optional start-line end-line)
  "Return git blame for FILE-PATH between START-LINE and END-LINE."
  (unless (and (stringp file-path) (not (string-empty-p (string-trim file-path))))
    (error "file_path is required"))
  (let* ((proj-root (kargu-permission-project-root))
         (abs (kargu-permission-assert-within-project file-path proj-root "blame file"))
         (rel (file-relative-name abs proj-root))
         (args (list "blame" "--date=short")))
    (when (and start-line end-line)
      (setq args (append args (list (format "-L%d,%d" start-line end-line)))))
    (setq args (append args (list "--" rel)))
    (let* ((res (kargu-git--run args proj-root)))
      (if (= (car res) 0)
          (cdr res)
        (error "git blame failed: %s" (cdr res))))))

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

(defun kargu-git-register-tools ()
  "Register Git and Magit tools with Kargu."
  ;; 1. git_status
  (kargu-register-tool
   "git_status"
   "Show structured Git repository status (branch, upstream, staged, unstaged, untracked). Magit-style. Read-only, available in all modes."
   '(("type" . "object")
     ("properties" . ()))
   (lambda (_args)
     (condition-case-unless-debug err
         (kargu-git-status)
       (error (format "ERROR: %s" (error-message-string err))))))

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
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-git-diff
          (kargu--tool-arg args "staged")
          (kargu--tool-arg args "path" "file")
          (kargu--tool-arg args "commit" "rev"))
       (error (format "ERROR: %s" (error-message-string err))))))

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
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-git-log
          (let ((n (kargu--tool-arg args "max_count" "limit" "n")))
            (and n (if (stringp n) (string-to-number n) n)))
          (kargu--tool-arg args "path" "file"))
       (error (format "ERROR: %s" (error-message-string err))))))

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
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-git-commit
          (kargu--tool-arg args "message" "msg")
          (kargu--tool-arg args "all"))
       (error (format "ERROR: %s" (error-message-string err))))))

  ;; 5. git_stage
  (kargu-register-tool
   "git_stage"
   "Stage file(s) into git index (git add). Agent mode only."
   '(("type" . "object")
     ("properties" . (("paths" . (("type" . "string")
                                  ("description" . "File path or pattern to stage (e.g. '.' for all).")))))
     ("required" . ["paths"]))
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-git-stage
          (kargu--tool-arg args "paths" "path" "file" "files"))
       (error (format "ERROR: %s" (error-message-string err))))))

  ;; 6. git_unstage
  (kargu-register-tool
   "git_unstage"
   "Unstage file(s) from git index (git restore --staged). Agent mode only."
   '(("type" . "object")
     ("properties" . (("paths" . (("type" . "string")
                                  ("description" . "File path to unstage.")))))
     ("required" . ["paths"]))
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-git-unstage
          (kargu--tool-arg args "paths" "path" "file" "files"))
       (error (format "ERROR: %s" (error-message-string err))))))

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
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-git-branch
          (kargu--tool-arg args "action")
          (kargu--tool-arg args "name" "branch"))
       (error (format "ERROR: %s" (error-message-string err))))))

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
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-git-stash
          (kargu--tool-arg args "action")
          (kargu--tool-arg args "message" "msg"))
       (error (format "ERROR: %s" (error-message-string err))))))

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
   (lambda (args)
     (condition-case-unless-debug err
         (kargu-git-blame
          (kargu--tool-arg args "file_path" "path" "file")
          (let ((s (kargu--tool-arg args "start_line")))
            (and s (if (stringp s) (string-to-number s) s)))
          (let ((e (kargu--tool-arg args "end_line")))
            (and e (if (stringp e) (string-to-number e) e))))
       (error (format "ERROR: %s" (error-message-string err)))))))

(kargu-git-register-tools)

(provide 'kargu/tools/git)

;;; kargu/tools/git.el ends here
