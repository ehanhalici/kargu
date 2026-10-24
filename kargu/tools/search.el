;;; search.el --- workspace_grep and glob -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Read-only workspace search.  Grep uses external tools; file discovery/listing is
;; owned by the Rust core through `kargu/bridge'.  Shared exclusions come from
;; `kargu/fs'.  Public: `kargu-search-grep',
;; `kargu-search-glob', `kargu-search-register-tools'.
;;
;; Read-only workspace search tools, modeled on OpenCode's grep/glob:
;;
;;  * `workspace_grep'  — ripgrep (`rg') when available, otherwise
;;    GNU grep.  Returns path:line:text hits, capped.
;;  * `find_files_by_glob' — bounded native Rust file discovery.
;;  * `list_files' — GNU ls through the bounded Rust command service.
;;
;; Both stay visible in ask/plan/debug (they do not mutate files).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/api/tools)
(require 'kargu/permission)
(require 'kargu/tools/process)
(require 'kargu/fs)
(require 'kargu/async)
(require 'kargu/bridge)

(defgroup kargu-search nil
  "Workspace grep and glob tools."
  :group 'kargu
  :prefix "kargu-search-")

(defcustom kargu-search-default-max-matches 50
  "Default cap on grep hits returned to the model."
  :type 'natnum
  :group 'kargu-search)

(defconst kargu-search--omitted-hits-note
  "\n... (additional hits omitted; raise max_matches or narrow the search)"
  "Notice appended when the global hit budget stopped a search.")

(defun kargu-search--root ()
  "Absolute project root used as the search cwd."
  (kargu-permission-project-root))

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
  (cl-loop for dir in kargu-fs-skip-dirs
           append (list "--glob" (format "!**/%s/**" dir))))

(cl-defun kargu-search--run (program args &key root callback max-lines)
  "Run PROGRAM with ARGS in ROOT without waiting.
CALLBACK receives (EXIT-CODE . STDOUT); a missing program is exit 127 and a
timeout or byte-truncated output is exit -1.  MAX-LINES optionally stops
after that many complete stdout records and accepts the intentional stop."
  (kargu-process-run
   program args
   (lambda (result)
     (let* ((code (plist-get result :code))
            (incomplete (or (plist-get result :timed-out)
                            (plist-get result :truncated)))
            (limited (and max-lines (plist-get result :line-limit-reached)))
            (failed (or incomplete (not (or limited (memq code '(0 1)))))))
       (funcall callback
                (cons (cond (incomplete -1) (limited 0) (t code))
                      (if failed (kargu-process-failure program result)
                        (or (plist-get result :output) ""))))))
   :dir root :max-lines max-lines))

(defun kargu-search--truncate-lines (text max-lines)
  "Keep the first MAX-LINES lines of TEXT; note if truncated."
  (let* ((lines (split-string text "\n" t))
         (n (length lines))
         (kept (if (> n max-lines)
                   (cl-subseq lines 0 max-lines)
                 lines)))
    (concat (string-join kept "\n")
            (if (> n max-lines)
                kargu-search--omitted-hits-note
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
         (cap (max 1 (kargu-to-int
                      max-matches kargu-search-default-max-matches))))
    (cond
     ((executable-find "rg")
      (kargu-search--grep-rg callback pattern
                             :target target :root root :glob glob :cap cap))
     ((executable-find "grep")
      (kargu-search--grep-gnu callback pattern
                              :target target :root root :glob glob :cap cap))
     (t
      (error "Neither rg nor grep is on PATH")))))

(cl-defun kargu-search--grep-report (callback result &key label pattern cap)
  "Turn the grep RESULT of tool LABEL into the text CALLBACK receives.
PATTERN names the search; CAP bounds its reported hits."
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

(cl-defun kargu-search--grep-rg (callback pattern &key target root glob cap)
  "Ripgrep PATTERN in TARGET; report at most CAP hits to CALLBACK.
ROOT is the working directory; GLOB optionally restricts files."
  (let ((args (append
               (list "-n" "-H" "--no-heading" "--color" "never" "--line-buffered")
               (kargu-search--rg-exclude-args)
               (when (and (stringp glob) (not (string-empty-p glob)))
                 (list "--glob" glob))
               (list "--" pattern target))))
    (kargu-search--run
     "rg" args :root root
     :callback (lambda (result)
                 (kargu-search--grep-report callback result
                                            :label "rg" :pattern pattern :cap cap))
     :max-lines (1+ cap))))

(cl-defun kargu-search--grep-gnu (callback pattern &key target root glob cap)
  "GNU grep fallback for PATTERN in TARGET; report to CALLBACK.
ROOT is the working directory; GLOB filters files; CAP bounds reported hits."
  (let* ((exclude (apply #'append
                         (mapcar (lambda (dir) (list "--exclude-dir" dir))
                                 kargu-fs-skip-dirs)))
         (include (when (and (stringp glob) (not (string-empty-p glob)))
                    (list "--include"
                          (save-match-data
                            (if (string-match
                                 (rx "/" (group (+ (not (any "/")))) string-end)
                                 glob)
                                (match-string 1 glob)
                              glob)))))
         (args (append (list "-r" "-n" "-H" "-I" "--line-buffered")
                       exclude include
                       (list "--" pattern target))))
    (kargu-search--run
     "grep" args :root root
     :callback (lambda (result)
                 (kargu-search--grep-report callback result
                                            :label "grep" :pattern pattern :cap cap))
     :max-lines (1+ cap))))

;;;; Glob -----------------------------------------------------------------

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

(defun kargu-search-list-files (&optional path callback)
  "Asynchronously list entries under PATH (default: project root) to CALLBACK.
Return an owned async task.  Without CALLBACK return an explicit error, never
wait for Rust or run the removed synchronous directory scanner."
  (if (not callback)
      "ERROR: directory listing runs asynchronously; provide a callback"
    (let* ((root (kargu-search--root))
           (target (kargu-search--resolve path root))
           (arguments (kargu-search--native-arguments root target)))
      (kargu-search--native-call callback arguments #'kargu-bridge-list-files))))

(defun kargu-search--native-arguments (root target)
  "Capture the shared immutable read arguments for ROOT and TARGET."
  (kargu-bridge--object
   "root" (copy-sequence root) "path" (copy-sequence target)
   "skip_directories" (vconcat (mapcar #'copy-sequence kargu-fs-skip-dirs))))

(defun kargu-search-glob (callback pattern &optional path)
  "List files matching glob PATTERN under PATH (default: project root).
The list goes to CALLBACK.  Rust owns matching, traversal and rendering.
Return an owned async task; Stop cancels its pending RPC, not sibling work."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p pattern
                         "pattern is required: %S" pattern)
  (let* ((root (kargu-search--root))
         (target (kargu-search--resolve path root))
         (arguments (kargu-search--native-arguments root target)))
    (puthash "pattern" (copy-sequence pattern) arguments)
    (puthash "max_files" kargu-fs-max-listed-files arguments)
    (puthash "max_directories" kargu-fs-max-visited-directories arguments)
    (kargu-search--native-call callback arguments #'kargu-bridge-find-files)))

(defun kargu-search--native-result (task result error-data)
  "Finish TASK from one native RESULT or ERROR-DATA without parsing display text."
  (cond
   (error-data (kargu-async-finish task nil (gethash "message" error-data "Native read failed")))
   ((and (hash-table-p result) (gethash "outcome" result)
         (not (equal (gethash "outcome" result) "ok")))
    (kargu-async-finish task nil (format "Listing failed (%s): %s"
                                       (gethash "outcome" result) (gethash "text" result ""))))
   ((not (and (hash-table-p result) (stringp (gethash "text" result))))
    (kargu-async-finish task nil "Invalid native read result"))
   (t (kargu-async-finish task (gethash "text" result)))))

(cl-defun kargu-search--native-dispatch (task &key owner arguments request connection failure)
  "Dispatch REQUEST with ARGUMENTS on CONNECTION for TASK and OWNER.
FAILURE is a startup error; a failed start never invokes a fallback."
  (if failure (kargu-async-finish task nil "Rust core unavailable; check kargu-bridge-binary-path")
    (let ((id (funcall request connection arguments
                       (kargu-async-wrap task (lambda (result error-data)
                                                (kargu-search--native-result task result error-data)))
                       :owner owner)))
      (when id
        (kargu-async-add-cleanup task (lambda () (kargu-bridge-cancel connection id)))))))

(defun kargu-search--native-call (callback arguments request)
  "Deliver CALLBACK through native REQUEST with captured ARGUMENTS.
Use the existing parent task, owner buffer and take-once RPC cleanup."
  (let* ((owner (current-buffer))
         (task (kargu-async-start
                (lambda (text error-data)
                  (funcall callback (if error-data (concat "ERROR: " error-data) text))))))
    (kargu-async-add-cleanup
     task
     (kargu-bridge-ensure
      (kargu-async-wrap
       task
       (lambda (connection failure)
         (kargu-search--native-dispatch task :owner owner :arguments arguments
                                        :request request :connection connection :failure failure)))))
    task))

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

(defconst kargu-search--tool-specs
  (list
   (list
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
   (list
    "find_files"
    "Find project files matching a glob pattern (e.g. **/*.rs, *.el, *test*) using bounded native Rust discovery. Includes hidden sources, applies configured directory/artifact exclusions, and reports incomplete searches. Read-only, available in all modes."
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
   (list
    "list_files"
    "List a project directory using GNU ls -lAh through the Rust command service. Read-only in all modes; returns ls text with bounded output and explicit truncation. For custom ls options use the bash tool with the full command."
    '(("type" . "object")
      ("properties" . (("path" . (("type" . "string")
                                  ("description" . "Directory path to list (default: project root).")))))
      ("required" . []))
    (kargu-search--executor
     (lambda (args done)
       (kargu-search-list-files
        (kargu--tool-arg args "path" "directory" "dir") done)))))
  "Tool schemas and executors for search operations.")

(defconst kargu-search--tool-aliases
  '(("grep" . "workspace_grep")
    ("rg" . "workspace_grep")
    ("find_files_by_glob" . "find_files")
    ("find" . "find_files")
    ("fd" . "find_files")
    ("glob" . "find_files")
    ("ls" . "list_files")
    ("dir" . "list_files"))
  "Aliases for the search tools.")

(defun kargu-search-register-tools ()
  "Register the search tools and their aliases."
  (kargu-register-tools kargu-search--tool-specs kargu-search--tool-aliases))

(provide 'kargu/tools/search)

;;; search.el ends here
