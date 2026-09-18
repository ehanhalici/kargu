;;; kargu/api/tools.el --- Tool registry and execution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Register OpenAI-style tools and run them by name.  Public: `kargu-register-tool', `kargu-execute-tool'.
;; Requires: `kargu/core', `kargu/json'.

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
(require 'kargu/json)
(require 'kargu/contract)

;;;; Tool registry ---------------------------------------------------------

(defvar kargu--tool-registry (make-hash-table :test #'equal)
  "Map tool NAME (string) to spec alist with keys:
  \"description\"  one-line description shown to the model
  \"parameters\"   JSON schema as an alist (arrays as vectors)
  \"executor\"     function of one argument: the decoded
                  arguments alist.  Returns a string, an alist to
                  JSON-encode, or nil for \"OK\".")

(defvar kargu--tools-visible-p nil
  "Optional gate on which registered tools are advertised to the model.
When non-nil: a function of one argument, the tool name; non-nil
means the tool is included in the request's tool list.  Set by
kargu-loop to implement mode-aware gating (mutating tools
are only advertised in agent mode).  Tool EXECUTION is unaffected
by this gate; it only shapes what the model is told about.")

(defun kargu-register-tool (name description parameters executor)
  "Register (or replace) the tool NAME for the model.
DESCRIPTION is a string, PARAMETERS a JSON-schema alist, and
EXECUTOR a function of one argument (the decoded arguments
alist) whose return value becomes the tool result.  Long results
are truncated to `kargu-tool-output-limit'."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p name
                         "NAME must be a non-empty string: %S" name)
  (kargu-contract-assert #'stringp description
                         "DESCRIPTION must be a string: %S" description)
  (kargu-contract-assert #'kargu-contract-tool-schema-p parameters
                         "PARAMETERS must be a JSON schema data structure or nil: %S" parameters)
  (kargu-contract-assert #'kargu-contract-tool-executor-p executor
                         "EXECUTOR must be callable: %S" executor)
  (puthash name
           `(("description" . ,description)
             ("parameters" . ,parameters)
             ("executor" . ,executor))
           kargu--tool-registry)
  (kargu-log 'debug "tool registered: %s" name)
  name)

(defun kargu-unregister-tool (name)
  "Remove the tool NAME from the registry."
  (remhash name kargu--tool-registry))

(defun kargu-registered-tools ()
  "Return the names of all registered tools."
  (hash-table-keys kargu--tool-registry))

(defun kargu--tools-available-p ()
  "Non-nil when at least one tool is registered."
  (> (hash-table-count kargu--tool-registry) 0))

(defun kargu--sanitize-tool-parameters (parameters)
  "Ensure PARAMETERS has a valid properties object when type is object."
  (let ((params (or parameters '(("type" . "object")))))
    (if (and (kargu--object-p params)
             (equal (kargu--aget params "type") "object")
             (null (kargu--aget params "properties")))
        (let ((filtered (seq-remove (lambda (cell) (and (consp cell) (equal (car cell) "properties"))) params)))
          (append filtered '(("properties" . :json-empty-object))))
      params)))

(defun kargu--tool-visible-p (name)
  "Return non-nil if tool NAME is visible to the model.
Delegates to `kargu--tools-visible-p' if set, otherwise to
`kargu-loop--tool-visible-p' if defined, defaulting to t."
  (if kargu--tools-visible-p
      (funcall kargu--tools-visible-p name)
    (if (fboundp 'kargu-loop--tool-visible-p)
        (kargu-loop--tool-visible-p name)
      t)))

(defun kargu--build-tools-vector ()
  "Build the OpenAI \"tools\" array (as a vector) from the registry.
Tools hidden by `kargu--tool-visible-p' are skipped."
  (let (tools)
    (maphash (lambda (name spec)
               (when (kargu--tool-visible-p name)
                 (push `(("type" . "function")
                         ("function" . (("name" . ,name)
                                        ("description" .
                                         ,(kargu--aget spec "description"))
                                        ("parameters" .
                                         ,(kargu--sanitize-tool-parameters
                                           (kargu--aget spec "parameters"))))))
                       tools)))
             kargu--tool-registry)
    (vconcat (nreverse tools))))

(defun kargu-register-tool-alias (alias name)
  "Expose registered tool NAME under ALIAS as well."
  (let ((spec (gethash name kargu--tool-registry)))
    (if (null spec)
        (kargu-log 'warn "tool alias %s: no such tool %s" alias name)
      (puthash alias spec kargu--tool-registry)
      (kargu-log 'debug "tool alias %s -> %s" alias name)
      alias)))

(defun kargu--decode-tool-arguments (arguments)
  "Normalize tool ARGUMENTS (JSON string, alist or nil) to an alist.
A valid empty object {} becomes nil, not a raw fallback.
Concatenated JSON objects keep the last object."
  (cond
   ((null arguments) nil)
   ((eq arguments :json-null) nil)
   ((stringp arguments)
    (let ((trimmed (string-trim arguments)))
      (if (or (string-empty-p trimmed) (equal trimmed "{}"))
          nil
        (let ((parsed (kargu--json-decode-lenient trimmed)))
          (if parsed
              (cdr parsed)
            (list (cons "_raw" trimmed)))))))
   ((kargu--object-p arguments) arguments)
   (t arguments)))

(defun kargu--encode-tool-arguments (arguments)
  "Return ARGUMENTS as a single valid JSON object string.
Used when storing tool_calls so the next POST cannot 400 on
concatenated or empty snapshots."
  (let ((decoded (kargu--decode-tool-arguments arguments)))
    (cond
     ((null decoded) "{}")
     ((and (kargu--object-p decoded)
           (equal (car (car decoded)) "_raw")
           (null (cdr decoded)))
      "{}")
     ((or (kargu--object-p decoded) (vectorp decoded))
      (kargu--json-encode decoded))
     (t "{}"))))

(defun kargu--tool-arg (args &rest keys)
  "First non-empty value in ARGS for KEYS (string keys)."
  (let (found)
    (dolist (key keys)
      (unless found
        (let ((val (kargu--aget args key)))
          (cond
           ((and (stringp val) (not (string-empty-p (string-trim val))))
            (setq found (string-trim val)))
           ((and val (not (stringp val)) (not (eq val :json-null)))
            (setq found val))))))
    found))

(defun kargu--tool-arg-string (args &rest keys)
  "First string value in ARGS for KEYS, including the empty string."
  (let (found)
    (dolist (key keys)
      (unless found
        (let ((val (kargu--aget args key)))
          (when (stringp val)
            (setq found val)))))
    found))

(defun kargu--tool-file-path (args)
  "File path from ARGS, accepting file_path / filePath / path / file."
  (let ((val (kargu--tool-arg args "file_path" "filePath" "path" "file" "filepath")))
    (and (stringp val) val)))

(defun kargu--tool-arg-keys (args)
  "Comma-separated keys present in ARGS, or none."
  (if (not (kargu--object-p args))
      "(none)"
    (mapconcat (lambda (cell) (format "%s" (car cell))) args ", ")))

(defun kargu--tool-missing-file-path (args)
  "Error string when a file path argument was missing."
  (let ((keys (kargu--tool-arg-keys args)))
    (if (and (kargu--object-p args)
             (or (assoc "pattern" args)
                 (assoc "query" args)
                 (assoc "regex" args)))
        (format "ERROR: missing file_path (also accepted: filePath, path). Got keys: %s. Note: file reading/editing tools require an exact file_path, not a search pattern. To search file contents for a pattern, use 'workspace_grep'. To find files by pattern/glob, use 'find_files'."
                keys)
      (format "ERROR: missing file_path (also accepted: filePath, path). Got keys: %s"
              keys))))

(defvar kargu--truncated-counter 0
  "Monotonic counter for truncated output buffer names.")

(defun kargu--truncate-for-model (string)
  "Truncate STRING to `kargu-tool-output-limit' characters.
Preserves the complete output in a buffer named `*kargu-output-<N>*'
so the model can inspect remaining lines using `read_file'."
  (if (and (natnump kargu-tool-output-limit)
           (> (length string) kargu-tool-output-limit))
      (let* ((omitted (- (length string) kargu-tool-output-limit))
             (id (cl-incf kargu--truncated-counter))
             (buf-name (format "*kargu-output-%d*" id)))
        (with-current-buffer (get-buffer-create buf-name)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert string)
            (setq-local buffer-offer-save nil)))
        (concat (substring string 0 kargu-tool-output-limit)
                (format "\n... [Output truncated: omitted %d chars. Complete output (%d chars) preserved in buffer '%s'. You can read specific line ranges using read_file with path='%s' from_line=N to_line=M]"
                        omitted (length string) buf-name buf-name)))
    string))

(defun kargu-execute-tool (name arguments &optional callback)
  "Run tool NAME with ARGUMENTS; ALWAYS return a result string or invoke CALLBACK.
When CALLBACK is provided, run asynchronously if the tool supports it.
Errors are captured and returned as \"ERROR: ...\" results so the
agent loop can feed them back to the model for self-correction."
  (let* ((spec (gethash name kargu--tool-registry))
         (raw (cond
               ((stringp arguments) arguments)
               ((null arguments) "")
               ((eq arguments :json-null) "")
               (t (condition-case nil
                      (kargu--json-encode arguments)
                    (error (format "%S" arguments))))))
         (args (kargu--decode-tool-arguments arguments)))
    (kargu--log-block (format "tool %s arguments (raw)" name) raw
                      (kargu--log-looks-json-p raw))
    (kargu--log-block (format "tool %s arguments (parsed)" name)
                      (format "%S" args))
    (kargu-log 'debug "execute-tool %s args=%s" name
                     (truncate-string-to-width (format "%s" args) 200))
    (cond
     ((null spec)
      (let ((out (format "ERROR: no such tool: %s" name)))
        (if callback (funcall callback out) out)))
     (callback
      (condition-case-unless-debug err
          (let* ((executor (kargu--aget spec "executor"))
                 (on-done (lambda (res)
                            (let* ((formatted (cond
                                                ((null res) "OK (no output)")
                                                ((stringp res)
                                                 (if (string-empty-p res) "OK (no output)" res))
                                                (t (kargu--json-encode res))))
                                   (final (kargu--truncate-for-model formatted)))
                              (kargu--log-block (format "tool %s result" name) formatted)
                              (funcall callback final))))
                 (called-async nil))
            (condition-case _arity-err
                (progn
                  (funcall executor args on-done)
                  (setq called-async t))
              (wrong-number-of-arguments nil))
            (unless called-async
              (let ((sync-res (funcall executor args)))
                (funcall on-done sync-res))))
        (error
         (let ((out (format "ERROR: tool %s failed: %s"
                            name (error-message-string err))))
           (funcall callback out)))))
     (t
      (let ((out
             (condition-case-unless-debug err
                 (let ((result (funcall (kargu--aget spec "executor") args)))
                   (cond
                    ((null result) "OK (no output)")
                    ((stringp result)
                     (if (string-empty-p result) "OK (no output)" result))
                    (t (kargu--json-encode result))))
               (error
                (format "ERROR: tool %s failed: %s"
                        name (error-message-string err))))))
        (kargu--log-block (format "tool %s result" name) out)
        (kargu--truncate-for-model out))))))

(provide 'kargu/api/tools)

;;; kargu/api/tools.el ends here
