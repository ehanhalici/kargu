;;; search.el --- workspace_grep and glob -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Read-only workspace search.  Execution and budgets are owned by Rust through
;; `kargu/bridge'; rg/grep and ls perform their own work.  Exclusions come from
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
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/api/tools)
(require 'kargu/permission)
(require 'kargu/tools/process)
(require 'kargu/fs)
(require 'kargu/async)
(require 'kargu/bridge/read)

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

;;;; Grep -----------------------------------------------------------------

(defun kargu-search-grep (callback pattern &optional path glob max-matches)
  "Search for PATTERN under PATH (default: project root); report to CALLBACK.
GLOB optionally restricts files (ripgrep `--glob').  MAX-MATCHES
caps the number of hits returned."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p pattern
                         "pattern is required: %S" pattern)
  (let* ((root (kargu-search--root))
         (target (kargu-search--resolve path root))
         (arguments (kargu-search--native-arguments root target)))
    (unless (or (null kargu-process-timeout)
                (and (numberp kargu-process-timeout) (> kargu-process-timeout 0)))
      (error "Timeout must be positive or nil"))
    (puthash "pattern" (copy-sequence pattern) arguments)
    (puthash "glob" (if (and (stringp glob) (not (string-empty-p glob)))
                         (copy-sequence glob) :json-null) arguments)
    (puthash "max_matches" (max 1 (kargu-to-int max-matches kargu-search-default-max-matches)) arguments)
    (puthash "output_bytes" kargu-process-max-bytes arguments)
    (puthash "timeout_ms" (if kargu-process-timeout
                              (max 1 (ceiling (* 1000 kargu-process-timeout))) :json-null) arguments)
    (kargu-bridge-read-task callback arguments #'kargu-bridge-grep)))

;;;; Glob -----------------------------------------------------------------

(declare-function kargu-deps-executable-status "kargu/tools/deps" (exe &optional root))

(defun kargu-search-tool-recommendations ()
  "Describe only search executables observed by the native project probe."
  (concat
   (if (or (eq (kargu-deps-executable-status "fd") :present)
           (eq (kargu-deps-executable-status "fdfind") :present))
       "• `fd` is available for finding files.\n"
     "• Use the native find_files tool; `fd` availability is unconfirmed.\n")
   (if (eq (kargu-deps-executable-status "rg") :present)
       "• `rg` (ripgrep) is available for searching code.\n"
     "• Use workspace_grep; `rg` availability is unconfirmed.\n")))

(defun kargu-search-list-files (&optional path callback)
  "Asynchronously list entries under PATH (default: project root) to CALLBACK.
Return an owned async task.  Without CALLBACK return an explicit error, never
wait for Rust or run the removed synchronous directory scanner."
  (if (not callback)
      "ERROR: directory listing runs asynchronously; provide a callback"
    (let* ((root (kargu-search--root))
           (target (kargu-search--resolve path root))
           (arguments (kargu-search--native-arguments root target)))
      (kargu-bridge-read-task callback arguments #'kargu-bridge-list-files))))

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
    (kargu-bridge-read-task callback arguments #'kargu-bridge-find-files)))

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
