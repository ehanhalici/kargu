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

(defconst kargu-file--read-initial-bytes 65536
  "Initial bounded disk prefix; geometric growth keeps total work linear.")

(define-error 'kargu-file-prefix-incomplete "Read scan budget exhausted before from_line")

(cl-defstruct (kargu-file-excerpt (:constructor kargu-file--make-excerpt))
  "One bounded numbered excerpt; nil TOTAL means the tail was not scanned."
  (from nil :read-only t) (to nil :read-only t) (total nil :read-only t)
  (body nil :read-only t) (truncated nil :read-only t) (needs-more nil :read-only t))

(cl-defstruct (kargu-file-revision (:constructor kargu-file--make-revision))
  "Filesystem identity and content revision of one disk snapshot."
  (inode nil :read-only t) (device nil :read-only t)
  (bytes nil :read-only t) (mtime nil :read-only t))

(defun kargu-file--line-piece (line remaining)
  "Take LINE's numbered text at point using at most REMAINING characters."
  (let* ((prefix (format "%d | " line))
         (space (max 0 (- remaining (length prefix))))
         (end (min (line-end-position) (+ (point) space))))
    (cons (substring (concat prefix (buffer-substring-no-properties (point) end))
                     0 (min remaining (+ (length prefix) (- end (point)))))
          (or (< remaining (length prefix)) (< end (line-end-position))))))

(defun kargu-file--buffer-excerpt (window complete)
  "Format WINDOW from the current widened snapshot, respecting COMPLETE.
COMPLETE is nil when only a bounded prefix of the file was read."
  (save-excursion
    (save-restriction
      (widen)
      (when (> (buffer-size) kargu-file-read-max-scan-chars)
        (narrow-to-region (point-min) (+ (point-min) kargu-file-read-max-scan-chars))
        (setq complete nil))
      (let* ((from (kargu-file-window-from window)) (to (kargu-file-window-to window))
             (remaining kargu-diff-read-max-chars) (line from) (last from)
             (boundary (eq (char-before (point-max)) ?\n))
             pieces total truncated needs-more (more t))
        (when (eq (char-before (point-max)) ?\n)
          (narrow-to-region (point-min) (1- (point-max))))
        (goto-char (point-min))
        (when (or (> (forward-line (1- from)) 0)
                  (and (> from 1) (eobp) (not (eq (char-before) ?\n))))
          (if complete (error "From_line exceeds file line count")
            (signal 'kargu-file-prefix-incomplete nil)))
        (while (and more (or (null to) (<= line to)))
          (let* ((end (line-end-position))
                 (piece (kargu-file--line-piece line remaining)))
            (push (car piece) pieces)
            (setq last line remaining (max 0 (- remaining (length (car piece)) 1)))
            (cond
             ((cdr piece) (setq truncated t more nil))
             ((= end (point-max))
              (setq total (and complete line) more nil
                    needs-more (and (not complete)
                                    (or (null to) (< line to) (not boundary)))
                    truncated needs-more))
             ((zerop remaining) (setq truncated (or (null to) (< line to)) more nil))
             (t (forward-line 1) (cl-incf line)))))
        (kargu-file--make-excerpt
         :from from :to last :total total :truncated truncated :needs-more needs-more
         :body (string-join (nreverse pieces) "\n"))))))

(defun kargu-file--describe-excerpt (path excerpt)
  "Render the bounded EXCERPT belonging to PATH."
  (format "(file %s, lines %d-%d of %s%s)\n%s%s"
          path (kargu-file-excerpt-from excerpt) (kargu-file-excerpt-to excerpt)
          (or (kargu-file-excerpt-total excerpt) "unknown")
          (if (kargu-file-excerpt-truncated excerpt) ", truncated" "")
          (kargu-file-excerpt-body excerpt)
          (if (kargu-file-excerpt-truncated excerpt)
              "\n... [truncated; request a smaller line range]" "")))

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

(defun kargu-file--file-revision (path)
  "Capture PATH's filesystem identity, size and content modification time."
  (or (kargu-file-current-revision path)
      (error "File disappeared while reading its snapshot")))

(defun kargu-file--checked-excerpt (window complete)
  "Read text WINDOW from the current snapshot described by COMPLETE."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward (string 0) (min (point-max) (+ (point-min) 1000)) t)
      (error "Binary data is unavailable through read_file")))
  (kargu-file--buffer-excerpt window complete))

(defun kargu-file--disk-excerpt (path window)
  "Read a bounded prefix of PATH sufficient for WINDOW, or report truncation."
  (when (file-remote-p path) (user-error "Kargu: asynchronous remote file reading is unavailable"))
  (unless (file-exists-p path)
    (error "No such file: '%s'; use find_files or list_files inside the project" path))
  (unless (file-regular-p path) (error "Read_file requires a regular file"))
  (unless (and (natnump kargu-file-read-max-bytes) (> kargu-file-read-max-bytes 0))
    (error "Read_file disk scan budget must be positive"))
  (let* ((before (kargu-file--file-revision path))
         (bytes (min kargu-file-read-max-bytes kargu-file--read-initial-bytes))
         (spent 0) excerpt done)
    (while (not done)
      (setq excerpt
            (with-temp-buffer
              (let ((file-name-handler-alist nil) (format-alist nil)
                    (after-insert-file-functions nil))
                (insert-file-contents path nil 0 bytes))
              (condition-case nil
                  (kargu-file--checked-excerpt window (<= (kargu-file-revision-bytes before) bytes))
                (kargu-file-prefix-incomplete nil))))
      (cl-incf spent bytes)
      (let ((next (min (* 2 bytes) (- kargu-file-read-max-bytes spent))))
        (setq done (or (and excerpt (not (kargu-file-excerpt-needs-more excerpt))) (<= next bytes)))
        (unless done (setq bytes next))))
    (unless (equal before (kargu-file--file-revision path))
      (error "File changed while its snapshot was being read"))
    (or excerpt (signal 'kargu-file-prefix-incomplete nil))))

(defun kargu-file-read-window (file-path window)
  "Read FILE-PATH using the validated inclusive line WINDOW.
Prefer unsaved visiting buffers without copying their full contents."
  (kargu-contract-assert #'kargu-contract-filepath-p file-path)
  (kargu-contract-assert #'kargu-file-window-p window)
  (when (file-remote-p file-path)
    (user-error "Kargu: remote read_file requires an asynchronous remote adapter"))
  (save-match-data
    (let* ((output (kargu-tool-output-buffer file-path))
           (path (if output file-path (kargu-permission-resolve file-path "file")))
           (visiting (or output (find-buffer-visiting path))))
      (kargu-file--describe-excerpt
       path (if (buffer-live-p visiting)
                (with-current-buffer visiting
                  (save-restriction (widen) (kargu-file--checked-excerpt window t)))
              (kargu-file--disk-excerpt path window))))))

(defun kargu-file-read (file-path &optional from-line to-line)
  "Return a bounded numbered excerpt of FILE-PATH, preferring unsaved buffers.
FROM-LINE and TO-LINE are positive 1-based inclusive integers.  Explicit
ranges still respect the output and scan budgets.  Report an unknown total
instead of scanning the remaining file just to count its lines."
  (kargu-file-read-window
   file-path (kargu-file-window-create :from from-line :to to-line)))

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
     ((not noninteractive) "ERROR: read_file requires an asynchronous callback")
     (t (condition-case-unless-debug error
            (kargu-file-read-window (car request) (cdr request))
          (error (format "ERROR: %s" (error-message-string error))))))))

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
