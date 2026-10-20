;;; files.el --- Permission-checked text reading -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Read-only file context shared by tool and editor adapters.
;; Loading this service does not load the editing or review adapter.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core/data)
(require 'kargu/core/group)
(require 'kargu/contract/assert)
(require 'kargu/permission/guards)
(require 'kargu/api/tools)

(defcustom kargu-diff-read-max-chars 15000
  "Character cap for the `read_file' tool result.
The text fed back to the model is additionally capped by
`kargu-tool-output-limit'."
  :type 'natnum
  :group 'kargu)

(cl-defun kargu-file--format-numbered-lines (lines from to &key has-window)
  "Format LINES from 1-based indices FROM to TO.
Prefix each line with line number.  If HAS-WINDOW is nil and output
exceeds `kargu-diff-read-max-chars', truncate the output.
Returns a cons cell `(BODY . TRUNCATED-P)'."
  (let* ((picked (cl-subseq lines (1- from) to))
         (n from)
         (numbered
          (mapcar (lambda (line)
                    (prog1 (format "%d | %s" n line)
                      (setq n (1+ n))))
                  picked))
         (body (string-join numbered "\n"))
         (truncated (and (not has-window)
                         (> (length body) kargu-diff-read-max-chars)))
         (final-body (if truncated
                         (concat (substring body 0 kargu-diff-read-max-chars)
                                 "\n... [truncated; use from_line/to_line to read specific sections]")
                       body)))
    (cons final-body truncated)))

(defun kargu-file--resolve-read-target (file-path)
  "Resolve FILE-PATH to (PATH . TEXT).
Prefer the full unsaved visiting buffer without changing its narrowing.
Signal for a missing or binary target."
  (let* ((live-buf (kargu-tool-output-buffer file-path))
         (is-buf (and live-buf (buffer-live-p live-buf)))
         (path (if is-buf file-path (kargu-permission-resolve file-path "file")))
         (visiting (or live-buf (find-buffer-visiting path))))
    (if (and (not (buffer-live-p visiting)) (not (file-exists-p path)))
        (error (concat "No such file: '%s'\n"
                       "  - Attempted file: '%s'\n"
                       "  - Allowed project root: '%s'\n"
                       "  - Reason: The file does not exist within the permitted workspace boundary.\n"
                       "  - Guidance: Use `find_files' or `list_files' to locate existing files inside '%s', or use `write_file' if you intend to create a new file.")
               path file-path (kargu-permission-project-root) (kargu-permission-project-root))
      (let ((text (if (buffer-live-p visiting)
                      (with-current-buffer visiting
                        (save-restriction (widen) (buffer-string)))
                    (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string)))))
        (when (cl-position 0 (substring text 0 (min 1000 (length text))))
          (error "%s looks like a binary file; read_file only serves text" path))
        (cons path text)))))

(defun kargu-file--validate-read-bounds (from to total)
  "Validate that FROM and TO are within bounds of TOTAL lines."
  (when (> from total)
    (error "From_line (%d) exceeds file line count (%d)" from total))
  (when (< to from)
    (error "To_line (%d) is before from_line (%d)" to from)))

(defun kargu-file-text (path)
  "Return the complete permission-checked text at PATH, including unsaved edits."
  (cdr (kargu-file--resolve-read-target path)))

(defun kargu-file-read (file-path &optional from-line to-line)
  "Return a model-oriented dump of FILE-PATH.
FROM-LINE and TO-LINE (1-based, inclusive) select a line window;
without them the whole file is served, capped at
`kargu-diff-read-max-chars'.  Each served line is prefixed with
its 1-based file line number (`12 | ...') so the model can copy
an exact `old_string' without the prefix."
  (kargu-contract-assert #'kargu-contract-filepath-p file-path
                         "FILE-PATH must be a valid file path string: %S" file-path)
  (let* ((target (kargu-file--resolve-read-target file-path))
         (path (car target))
         (text (cdr target))
         (lines (split-string (string-remove-suffix "\n" text) "\n"))
         (total (max 1 (length lines)))
         (has-window (or from-line to-line))
         (from (max 1 (or (kargu-to-int from-line) 1)))
         (to (min (or (kargu-to-int to-line) total) total)))
    (kargu-file--validate-read-bounds from to total)
    (let* ((formatted (kargu-file--format-numbered-lines
                       lines from to :has-window has-window))
           (body (car formatted))
           (truncated (cdr formatted)))
      (format "(file %s, lines %d-%d of %d%s)\n%s"
              path from to total
              (if truncated
                  (format ", capped at %d chars"
                          kargu-diff-read-max-chars)
                "")
              body))))

(defconst kargu-file--tool-specs
  (list
   (list
    "read_file"
    "Read a file with numbered lines (\"12 | code\"). Requires file_path. Search first, then use from_line/to_line (or limit) to read relevant sections rather than entire large files. Use structural inspection when available. NEVER pass search patterns or regex here."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file (or output buffer) to read. Must be a valid file path, NOT a search pattern or regex.")))
                       ("from_line" . (("type" . "integer")
                                       ("description" . "First 1-based line to return (inclusive).")))
                       ("to_line" . (("type" . "integer")
                                     ("description" . "Last 1-based line to return (inclusive).")))
                       ("limit" . (("type" . "integer")
                                   ("description" . "Maximum number of lines to return from from_line.")))))
      ("required" . ["file_path"]))
    (lambda (args)
      (let* ((path (kargu--tool-file-path args))
             (from (or (kargu--tool-arg args "from_line" "fromLine")
                       (kargu--tool-arg args "offset")))
             (limit (kargu--tool-arg args "limit"))
             (to (or (kargu--tool-arg args "to_line" "toLine")
                     (and from limit
                          (let ((f (kargu-to-int from))
                                (n (kargu-to-int limit)))
                            (and f n (+ f n -1)))))))
        (if (not (kargu-nonempty path))
            (kargu--tool-missing-file-path args)
          (condition-case-unless-debug err
              (kargu-file-read path from to)
            (error (format "ERROR: %s" (error-message-string err)))))))))
  "Read-only file tool schema and executor.")

(defun kargu-file-register-tools ()
  "Register file reading and its legacy alias without mutation tools."
  (kargu-register-tools kargu-file--tool-specs '(("read" . "read_file"))))

(provide 'kargu/files)
;;; files.el ends here
