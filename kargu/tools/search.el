;;; kargu/tools/search.el --- workspace_grep and glob -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Read-only workspace search.  Skip dirs and the Elisp glob walk
;; come from `kargu/fs'.  Requires: `kargu/core', `kargu/api',
;; `kargu/fs', `kargu/tools/lsp'.  Public: `kargu-search-grep',
;; `kargu-search-glob', `kargu-search-register-tools'.
;;
;; Read-only workspace search tools, modeled on OpenCode's grep/glob:
;;
;;  * `workspace_grep'  — ripgrep (`rg') when available, otherwise
;;    GNU grep.  Returns path:line:text hits, capped.
;;  * `find_files_by_glob' — `rg --files -g PATTERN', with an Emacs
;;    bounded Elisp directory walk fallback.
;;
;; Both stay visible in ask/plan/debug (they do not mutate files).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/api)
(require 'kargu/api/tools)
(require 'kargu/permission)
(require 'kargu/tools/process)
(require 'kargu/tools/lsp)
(require 'kargu/fs)

(defgroup kargu-search nil
  "Workspace grep and glob tools."
  :group 'kargu
  :prefix "kargu-search-")

(defcustom kargu-search-default-max-matches 50
  "Default cap on grep hits returned to the model."
  :type 'natnum
  :group 'kargu-search)

(defun kargu-search--root ()
  "Absolute project root used as the search cwd."
  (kargu-permission-project-root))

(defun kargu-search--to-int (value default)
  "Coerce VALUE to an integer, or DEFAULT."
  (or (kargu-to-int value default) default))

(defalias 'kargu-search--rel #'kargu-rel-path)

(defun kargu-search--resolve (path root)
  "Resolve optional PATH against ROOT; assert it is strictly inside ROOT."
  (let* ((effective-root (or root (kargu-permission-project-root)))
         (blank (or (null path) (and (stringp path) (string-empty-p (string-trim path)))))
         (abs (if blank
                  effective-root
                (kargu-permission-resolve path "search path" effective-root))))
    (unless (file-exists-p abs)
      (error (concat "No such search path: '%s'\n"
                     "  - Attempted search path: '%s'\n"
                     "  - Allowed project root: '%s'\n"
                     "  - Reason: The specified path does not exist inside the project boundary.\n"
                     "  - Guidance: Please ensure the directory exists within '%s', or omit the path parameter to search the entire project root.")
             abs (or path "") effective-root effective-root))
    abs))

(defun kargu-search--rg-exclude-args ()
  "Ripgrep `--glob' arguments that skip junk directories."
  (let (args)
    (dolist (dir kargu-fs-skip-dirs)
      (setq args (append args (list "--glob" (format "!**/%s/**" dir)))))
    args))

(defun kargu-search--run (program args root callback)
  "Run PROGRAM with ARGS in ROOT without waiting.
CALLBACK receives (EXIT-CODE . STDOUT); a missing program is exit 127 and a
timeout is exit -1."
  (kargu-process-run
   program args
   (lambda (result)
     (funcall callback
              (cons (if (plist-get result :timed-out) -1 (plist-get result :code))
                    (or (plist-get result :output) ""))))
   :dir root))

(defun kargu-search--truncate-lines (text max-lines)
  "Keep the first MAX-LINES lines of TEXT; note if truncated."
  (let* ((lines (split-string text "\n" t))
         (n (length lines))
         (kept (if (> n max-lines)
                   (cl-subseq lines 0 max-lines)
                 lines)))
    (concat (string-join kept "\n")
            (if (> n max-lines)
                (format "\n... (%d more hits truncated; raise max_matches or narrow the search)"
                        (- n max-lines))
              (if (string-empty-p (string-trim text))
                  ""
                "\n")))))

;;;; Grep -----------------------------------------------------------------

(defun kargu-search-grep (callback pattern &optional path glob max-matches)
  "Search for PATTERN under PATH (default: project root); report to CALLBACK.
GLOB optionally restricts files (ripgrep `--glob').  MAX-MATCHES
caps the number of hits returned."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p pattern
                         "pattern is required: %S" pattern)
  (let* ((root (kargu-search--root))
         (target (kargu-search--resolve path root))
         (cap (max 1 (kargu-search--to-int
                      max-matches kargu-search-default-max-matches))))
    (cond
     ((executable-find "rg")
      (kargu-search--grep-rg callback pattern target root glob cap))
     ((executable-find "grep")
      (kargu-search--grep-gnu callback pattern target root glob cap))
     (t
      (error "Neither rg nor grep is on PATH")))))

(defun kargu-search--grep-report (callback label pattern cap result)
  "Turn the grep RESULT of tool LABEL into the text CALLBACK receives."
  (kargu-process-deliver
   callback
   (lambda ()
     (let ((code (car result))
           (out (cdr result)))
       (unless (memq code '(0 1))
         (error "%s failed (exit %s): %s" label code (string-trim (or out ""))))
       (if (string-empty-p (string-trim out))
           (format "No matches for %S" pattern)
         (kargu-search--truncate-lines out cap))))))

(defun kargu-search--grep-rg (callback pattern target root glob cap)
  "Ripgrep PATTERN in TARGET; report at most CAP hits to CALLBACK."
  (let ((args (append
               (list "-n" "-H" "--no-heading" "--color" "never"
                     "--max-count" (number-to-string cap))
               (kargu-search--rg-exclude-args)
               (when (and (stringp glob) (not (string-empty-p glob)))
                 (list "--glob" glob))
               (list "--" pattern target))))
    (kargu-search--run
     "rg" args root
     (lambda (result)
       (kargu-search--grep-report callback "rg" pattern cap result)))))

(defun kargu-search--grep-gnu (callback pattern target root glob cap)
  "GNU grep fallback for PATTERN in TARGET; report to CALLBACK."
  (let* ((exclude (apply #'append
                         (mapcar (lambda (dir) (list "--exclude-dir" dir))
                                 kargu-fs-skip-dirs)))
         (include (when (and (stringp glob) (not (string-empty-p glob)))
                    (list "--include"
                          (if (string-match "/\\([^/]+\\)\\'" glob)
                              (match-string 1 glob)
                            glob))))
         (args (append (list "-R" "-n" "-H" "-I")
                       exclude include
                       (list "--" pattern target))))
    (kargu-search--run
     "grep" args root
     (lambda (result)
       (kargu-search--grep-report callback "grep" pattern cap result)))))

;;;; Glob -----------------------------------------------------------------

(defun kargu-search--normalize-glob (glob)
  "Treat a basename glob like `*.el' as `**/*.el'."
  (cond
   ((or (null glob) (string-empty-p glob)) "**/*")
   ((string-match-p "/" glob) glob)
   (t (concat "**/" glob))))

(defun kargu-search--glob-to-regexp (glob)
  "Regexp matching a project-relative path against GLOB."
  (let* ((g (kargu-search--normalize-glob glob))
         (g (replace-regexp-in-string "\\*\\*" "\0" g))
         (re (mapconcat
              (lambda (ch)
                (pcase ch
                  (?\0 ".*")
                  (?* "[^/]*")
                  (?? "[^/]")
                  (c (regexp-quote (char-to-string c)))))
              (string-to-list g)
              "")))
    (concat "\\`" re "\\'")))

(defun kargu-search-fd-executable ()
  "Return the path to fd (or fdfind) if available on PATH."
  (or (executable-find "fd")
      (executable-find "fdfind")))

(defun kargu-search-rg-executable ()
  "Return the path to rg if available on PATH."
  (executable-find "rg"))

(defun kargu-search-tool-recommendations ()
  "Return a human-readable recommendation string of installed search tools."
  (let ((fd (kargu-search-fd-executable))
        (rg (kargu-search-rg-executable)))
    (concat
     (if fd
         "• `fd` is available and recommended for finding files (preferred over `find`).\n"
       "• `find` is available for finding files.\n")
     (if rg
         "• `rg` (ripgrep) is available and recommended for searching code (preferred over `grep`).\n"
       "• `grep` is available for searching code.\n"))))

(defun kargu-search-list-files (&optional path)
  "List files and directories directly under PATH (default: project root)."
  (let* ((root (kargu-search--root))
         (target (kargu-search--resolve path root)))
    (unless (file-directory-p target)
      (error "path %s is not a directory" target))
    (let* ((entries (directory-files target nil directory-files-no-dot-files-regexp t))
           (lines nil))
      (dolist (entry entries)
        (unless (member entry kargu-fs-skip-dirs)
          (let* ((full (expand-file-name entry target))
                 (is-dir (file-directory-p full))
                 (rel (kargu-search--rel full root)))
            (push (format "%s %s" (if is-dir "[DIR] " "[FILE]") rel) lines))))
      (if (null lines)
          "(empty directory)"
        (string-join (sort (nreverse lines) #'string<) "\n")))))

(defun kargu-search-glob (callback pattern &optional path)
  "List files matching glob PATTERN under PATH (default: project root).
The list goes to CALLBACK.  Prefers fd, then ripgrep, then a bounded Elisp walk."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p pattern
                         "pattern is required: %S" pattern)
  (let* ((root (kargu-search--root))
         (target (kargu-search--resolve path root))
         (fd (kargu-search-fd-executable)))
    (cond
     (fd (kargu-search--glob-fd callback fd pattern target root))
     ((kargu-search-rg-executable)
      (kargu-search--glob-rg callback pattern target root))
     (t
      (kargu-process-deliver
       callback
       (lambda () (kargu-search--glob-elisp pattern target root)))))))

(defun kargu-search--format-files (files pattern)
  "Text for the project-relative FILES matching PATTERN, capped."
  (if (null files)
      (format "No files matching %S" pattern)
    (let ((n (length files))
          (cap 200))
      (concat (string-join (cl-subseq files 0 (min cap n)) "\n")
              (if (> n cap)
                  (format "\n... (%d more files truncated)" (- n cap))
                "\n")))))

(defun kargu-search--glob-fallback (callback pattern target root)
  "List PATTERN under TARGET with rg, or a bounded walk when rg is missing."
  (if (kargu-search-rg-executable)
      (kargu-search--glob-rg callback pattern target root)
    (kargu-process-deliver
     callback (lambda () (kargu-search--glob-elisp pattern target root)))))

(defun kargu-search--glob-fd (callback fd-exe pattern target root)
  "List files matching PATTERN under TARGET via fd; report to CALLBACK."
  (kargu-search--run
   fd-exe
   (list "--color" "never" "--hidden"
         "--glob" (kargu-search--normalize-glob pattern)
         "--base-directory" target)
   root
   (lambda (result)
     (if (/= (car result) 0)
         (kargu-search--glob-fallback callback pattern target root)
       (kargu-process-deliver
        callback
        (lambda ()
          (kargu-search--format-files
           (mapcar (lambda (f) (kargu-search--rel (expand-file-name f target) root))
                   (split-string (cdr result) "\n" t))
           pattern)))))))

(defun kargu-search--glob-rg (callback pattern target root)
  "List files matching PATTERN under TARGET via ripgrep; report to CALLBACK."
  (kargu-search--run
   "rg"
   (append (list "--files" "--color" "never")
           (kargu-search--rg-exclude-args)
           (list "--glob" (kargu-search--normalize-glob pattern) "--" target))
   root
   (lambda (result)
     (kargu-process-deliver
      callback
      (lambda ()
        (unless (memq (car result) '(0 1))
          (error "rg --files failed (exit %s): %s"
                 (car result) (string-trim (or (cdr result) ""))))
        (kargu-search--format-files
         (mapcar (lambda (f) (kargu-search--rel f root))
                 (split-string (cdr result) "\n" t))
         pattern))))))

(defun kargu-search--glob-elisp (pattern target root)
  "List files matching PATTERN under TARGET without ripgrep (a bounded walk)."
  (let* ((re (kargu-search--glob-to-regexp pattern))
         (match-p (lambda (path)
                    (or (string-match-p re (kargu-search--rel path root))
                        (string-match-p re (kargu-search--rel path target))
                        (string-match-p re (file-name-nondirectory path)))))
         (files
          (if (file-directory-p target)
              (kargu-fs-walk target kargu-fs-max-listed-files match-p)
            (let ((path (expand-file-name target)))
              (and (funcall match-p path)
                   (list path))))))
    (kargu-search--format-files
     (mapcar (lambda (p) (kargu-search--rel p root)) files)
     pattern)))

;;;; Tool registration -----------------------------------------------------

(defun kargu-search--executor (body)
  "Tool executor for a search tool.
BODY takes the decoded arguments and a DONE function and starts the
search; DONE receives the result string.  The search never blocks Emacs, so
a callback is required."
  (lambda (args &optional callback)
    (if (null callback)
        "ERROR: search tools run asynchronously; call them with a callback"
      (condition-case-unless-debug err
          (funcall body args callback)
        (error (funcall callback (format "ERROR: %s" (error-message-string err))))))))

(defun kargu-search-register-tools ()
  "Register workspace search and listing tools.
All tools are read-only and available in all modes."
  ;; 1. workspace_grep (grep, rg)
  (kargu-register-tool
   "workspace_grep"
   "Search file contents for regex or literal text pattern. ALWAYS use this (or rg/grep) instead of reading entire files when searching for definitions, usages, or text. Uses `rg' (ripgrep) if available, otherwise GNU grep. Read-only, available in all modes."
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Search pattern (regex or literal).")))
                      ("path" . (("type" . "string")
                                 ("description" . "File or directory to search (default: project root).")))
                      ("glob" . (("type" . "string")
                                 ("description" . "Optional file glob, e.g. *.el or **/*.rs.")))
                      ("max_matches" . (("type" . "integer")
                                        ("description" . "Maximum hits to return (default 50).")))))
     ("required" . ["pattern"]))
   (kargu-search--executor
    (lambda (args done)
      (kargu-search-grep
       done
       (kargu--tool-arg args "pattern")
       (kargu--tool-arg args "path" "file_path" "filePath")
       (kargu--tool-arg args "glob")
       (kargu--tool-arg args "max_matches" "maxMatches" "limit")))))

  ;; 2. find_files (find, fd, glob, find_files_by_glob)
  (kargu-register-tool
   "find_files"
   "Find project files matching a glob pattern (e.g. **/*.rs, *.el, *test*). Uses `fd' if available (preferred over `find'), otherwise `rg --files' or directory walk. Read-only, available in all modes."
   '(("type" . "object")
     ("properties" . (("pattern" . (("type" . "string")
                                    ("description" . "Glob pattern such as **/*.rs or *.el.")))
                      ("path" . (("type" . "string")
                                 ("description" . "Directory to search (default: project root).")))))
     ("required" . ["pattern"]))
   (kargu-search--executor
    (lambda (args done)
      (kargu-search-glob
       done
       (kargu--tool-arg args "pattern")
       (kargu--tool-arg args "path" "file_path" "filePath")))))

  ;; 3. list_files (ls, dir)
  (kargu-register-tool
   "list_files"
   "List files and directories directly under a project path (similar to `ls'). Read-only, available in all modes."
   '(("type" . "object")
     ("properties" . (("path" . (("type" . "string")
                                 ("description" . "Directory path to list (default: project root).")))))
     ("required" . []))
   (lambda (args)
     (kargu-safe-tool-call
      (kargu-search-list-files
       (kargu--tool-arg args "path" "directory" "dir")))))

  ;; Aliases
  (kargu-register-tool-alias "grep" "workspace_grep")
  (kargu-register-tool-alias "rg" "workspace_grep")
  (kargu-register-tool-alias "find_files_by_glob" "find_files")
  (kargu-register-tool-alias "find" "find_files")
  (kargu-register-tool-alias "fd" "find_files")
  (kargu-register-tool-alias "glob" "find_files")
  (kargu-register-tool-alias "ls" "list_files")
  (kargu-register-tool-alias "dir" "list_files"))

(kargu-search-register-tools)

(provide 'kargu/tools/search)

;;; kargu/tools/search.el ends here
