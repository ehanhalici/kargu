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
(require 'kargu/contract/file-window)
(require 'kargu/permission/guards)
(require 'kargu/api/tools)

(autoload 'kargu-file-read-async "kargu/files/async")

(defcustom kargu-diff-read-max-chars 15000
  "Character cap for the `read_file' tool result.
The text fed back to the model is additionally capped by
`kargu-tool-output-limit'."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-file-read-max-bytes (* 16 1024 1024)
  "Maximum cumulative disk bytes requested by one model-oriented read.
Reads beyond this prefix are unavailable, not EOF.  Full-text editing
snapshots use their separate explicit API."
  :type 'natnum :group 'kargu)

(defcustom kargu-file-read-max-scan-chars (* 16 1024 1024)
  "Maximum decoded characters scanned from one file or live-buffer snapshot."
  :type 'natnum :group 'kargu)

(cl-defstruct (kargu-file-revision (:constructor kargu-file--make-revision))
  "Filesystem identity and content revision of one disk snapshot."
  (inode nil :read-only t) (device nil :read-only t)
  (bytes nil :read-only t) (mtime nil :read-only t))

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

(defun kargu-file-text (path)
  "Return the complete permission-checked text at PATH, including unsaved edits."
  (cdr (kargu-file--resolve-read-target path)))

(defun kargu-file-current-revision (path)
  "Return `kargu-file-revision' for PATH on disk or in buffer, or nil.
PATH may be a file path string or a buffer.  Return nil if PATH is absent,
not visiting a file on disk, or unreadable."
  (let ((target (cond
                 ((bufferp path)
                  (and (buffer-live-p path) (buffer-file-name path)))
                 ((and (stringp path)
                       (not (string-empty-p (string-trim path)))
                       (not (file-remote-p path)))
                  (cond
                   ((file-exists-p path)
                    path)
                   ((and (get-buffer path)
                         (buffer-live-p (get-buffer path)))
                    (buffer-file-name (get-buffer path)))
                   (t path)))
                 (t nil))))
    (when (and (stringp target)
               (not (string-empty-p (string-trim target)))
               (not (file-remote-p target)))
      (condition-case nil
          (let ((truename (file-truename target)))
            (when (and (stringp truename)
                       (not (file-remote-p truename))
                       (file-exists-p truename))
              (let ((attrs (file-attributes truename)))
                (when attrs
                  (kargu-file--make-revision
                   :inode (file-attribute-inode-number attrs)
                   :device (file-attribute-device-number attrs)
                   :bytes (file-attribute-size attrs)
                   :mtime (file-attribute-modification-time attrs))))))
        (error nil)))))

(defun kargu-file--bound-argument (args keys)
  "Read integer aliases KEYS in ARGS, rejecting null and conflicting values."
  (let ((missing (make-symbol "missing")) value seen)
    (dolist (key keys)
      (let ((raw (kargu-aget args key missing)))
        (unless (eq raw missing)
          (unless (integerp raw) (error "Invalid %s: expected an integer" key))
          (when (and seen (/= raw value)) (error "Conflicting aliases for %s" (car keys)))
          (setq value raw seen t))))
    value))

(defun kargu-file--tool-window (args)
  "Decode ARGS into a canonical line window once, before reading anything."
  (kargu-file-window-create
   :from (kargu-file--bound-argument args '("from_line" "fromLine"))
   :to (kargu-file--bound-argument args '("to_line" "toLine"))
   :limit (kargu-file--bound-argument args '("limit"))
   :offset (kargu-file--bound-argument args '("offset"))))

(defun kargu-file--execute (args &optional callback)
  "Read validated ARGS, reporting the text or failure through CALLBACK."
  (let ((request (condition-case-unless-debug error
                     (let ((path (kargu--tool-file-path args)))
                       (if (not (kargu-nonempty path)) (kargu--tool-missing-file-path args)
                         (cons path (kargu-file--tool-window args))))
                   (error (format "ERROR: %s" (error-message-string error))))))
    (cond
     ((stringp request) (if callback (funcall callback request) request))
     (callback (kargu-file-read-async (car request) (cdr request) callback))
     (t "ERROR: read_file requires an asynchronous callback"))))

(defconst kargu-file--tool-specs
  (list
   (list
    "read_file"
    "Read a file with numbered lines (\"12 | code\"). Requires file_path. Search first, then use from_line/to_line (or limit) to read relevant sections rather than entire large files. Use structural inspection when available. NEVER pass search patterns or regex here."
    '(("type" . "object")
      ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file (or output buffer) to read. Must be a valid file path, NOT a search pattern or regex.")))
                       ("from_line" . (("type" . "integer")
                                       ("minimum" . 1)
                                       ("description" . "First 1-based line to return (inclusive).")))
                       ("to_line" . (("type" . "integer")
                                     ("minimum" . 1)
                                     ("description" . "Last 1-based line to return (inclusive).")))
                       ("limit" . (("type" . "integer")
                                   ("minimum" . 1)
                                   ("description" . "Maximum number of lines to return from from_line.")))))
      ("required" . ["file_path"]))
    #'kargu-file--execute))
  "Read-only file tool schema and executor.")

(defun kargu-file-register-tools ()
  "Register file reading and its legacy alias without mutation tools."
  (kargu-register-tools kargu-file--tool-specs '(("read" . "read_file"))))

(provide 'kargu/files)
;;; files.el ends here
