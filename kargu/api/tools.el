;;; tools.el --- Tool registry and execution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Register OpenAI-style tools and run them by name.  Public: `kargu-register-tool', `kargu-execute-tool'.
;; Requires: `kargu/core', `kargu/json'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/contract)
(require 'kargu/async)
(require 'kargu/permission/guards)

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

(defun kargu-register-tool (name description parameters executor &optional policy)
  "Register (or replace) the tool NAME for the model.
DESCRIPTION is a string, PARAMETERS a JSON-schema alist, and
EXECUTOR a function of one argument (the decoded arguments
alist) whose return value becomes the tool result.  POLICY optionally
declares :modes and an :available-p function returning a refusal or nil.
Long results
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
           `(("name" . ,name)
             ("description" . ,description)
             ("parameters" . ,parameters)
             ("executor" . ,executor)
             ("policy" . ,policy))
           kargu--tool-registry)
  (kargu-log 'debug "tool registered: %s" name)
  name)

(defun kargu-registered-tools ()
  "Return the names of all registered tools."
  (hash-table-keys kargu--tool-registry))

(defun kargu-canonical-tool-name (name)
  "Return the canonical tool name for NAME, resolving compatibility aliases."
  (or (kargu-aget (gethash name kargu--tool-registry) "name") name))

(defun kargu--tool-spec (name)
  "Return the current canonical specification of tool NAME."
  (gethash (kargu-canonical-tool-name name) kargu--tool-registry))

(defun kargu-advertised-tools ()
  "List visible canonical tool names in deterministic order."
  (sort (seq-filter (lambda (name)
                      (and (equal name (kargu-canonical-tool-name name))
                           (kargu-tool-visible-p name)))
                    (kargu-registered-tools)) #'string<))

(defun kargu-tool-description (name)
  "Return the registered description of tool NAME."
  (kargu-aget (kargu--tool-spec name) "description"))

(defun kargu-set-tool-policy (name policy)
  "Set POLICY for registered tool NAME and its aliases."
  (setcdr (assoc "policy" (kargu--tool-spec name)) policy))

(defun kargu-register-tools (specs &optional aliases policy)
  "Register tool SPECS and their optional ALIASES.
Each spec is (NAME DESCRIPTION PARAMETERS EXECUTOR).
Each alias is (ALIAS . NAME).  POLICY is shared by the group unless
a spec supplies its own fifth element."
  (dolist (spec specs)
    (apply #'kargu-register-tool
           (append (seq-take spec 4) (list (or (nth 4 spec) policy)))))
  (dolist (alias aliases)
    (kargu-register-tool-alias (car alias) (cdr alias))))

(defun kargu--sanitize-tool-parameters (parameters)
  "Ensure PARAMETERS has a valid properties object when type is object."
  (let ((params (or parameters '(("type" . "object")))))
    (if (and (kargu--object-p params)
             (equal (kargu-aget params "type") "object")
             (null (kargu-aget params "properties")))
        (let ((filtered (seq-remove (lambda (cell) (and (consp cell) (equal (car cell) "properties"))) params)))
          (append filtered '(("properties" . :json-empty-object))))
      params)))

(defun kargu-tool-policy-error (name)
  "Return a refusal for unavailable tool NAME, or nil when allowed."
  (let* ((policy (kargu-aget (kargu--tool-spec name) "policy"))
         (modes (plist-get policy :modes))
         (available (plist-get policy :available-p)))
    (cond
     ((and modes (not (memq (kargu-state-mode) modes)))
      (format "ERROR: Tool %s is unavailable in %s mode."
              name (kargu-state-mode)))
     (available (funcall available)))))

(defun kargu--tool-visible-p (name)
  "Return non-nil if tool NAME is visible to the model.
Delegates to `kargu--tools-visible-p' if set, otherwise to
`kargu-loop-tool-visible-p' if defined, defaulting to t."
  (and (not (kargu-tool-policy-error name))
       (if kargu--tools-visible-p
	   (funcall kargu--tools-visible-p name)
	 (if (fboundp 'kargu-loop-tool-visible-p)
             (kargu-loop-tool-visible-p name)
	   t))))

(defun kargu--build-tools-vector ()
  "Build the OpenAI \"tools\" array (as a vector) from the registry.
Tools hidden by `kargu--tool-visible-p' are skipped."
  (let (tools)
    (dolist (name (kargu-advertised-tools))
      (let ((spec (gethash name kargu--tool-registry)))
        (when (kargu--tool-visible-p name)
          (push `(("type" . "function")
                  ("function" . (("name" . ,name)
                                 ("description" .
                                  ,(kargu-aget spec "description"))
                                 ("parameters" .
                                  ,(kargu--sanitize-tool-parameters
                                    (kargu-aget spec "parameters"))))))
                tools))))
    (vconcat (nreverse tools))))

(defalias 'kargu-tool-visible-p #'kargu--tool-visible-p)

(defun kargu-tool-schema-char-count ()
  "Return the serialized character cost of currently advertised tool schemas."
  (length (kargu-json-encode-record (kargu--build-tools-vector))))

(defun kargu-register-tool-alias (alias name)
  "Expose registered tool NAME under ALIAS as well."
  (let ((spec (gethash name kargu--tool-registry)))
    (if (null spec)
        (kargu-log 'warn "tool alias %s: no such tool %s" alias name)
      (puthash alias spec kargu--tool-registry)
      (kargu-log 'debug "tool alias %s -> %s" alias name)
      alias)))

(defun kargu--decode-tool-arguments (arguments)
  "Normalize tool ARGUMENTS to a typed object, native alist or nil.
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

(defun kargu--tool-arguments-invalid-p (arguments)
  "Non-nil when ARGUMENTS is text that is not one JSON object.
An empty string and `{}' are valid: they mean no arguments."
  (and (stringp arguments)
       (let ((trimmed (string-trim arguments)))
         (and (not (string-empty-p trimmed))
              (not (equal trimmed "{}"))
              (let ((parsed (kargu--json-decode-lenient trimmed)))
                (not (and parsed (or (null (cdr parsed))
                                     (kargu--object-p (cdr parsed))))))))))

(defun kargu--encode-tool-arguments (arguments)
  "Return ARGUMENTS as a single valid JSON object string.
Used when storing tool_calls so the next POST cannot 400 on
concatenated or empty snapshots."
  (let ((decoded (kargu--decode-tool-arguments arguments)))
    (cond
     ((null decoded) "{}")
     ((and (consp decoded)
           (equal (car (car decoded)) "_raw")
           (null (cdr decoded)))
      "{}")
     ((kargu--object-p decoded)
      (kargu-json-encode-record decoded))
     (t "{}"))))

(defun kargu--json-true-p (val)
  "Return t only when VAL is an explicit true.
JSON false, nil, \"false\", and 0 are false.  A missing value is false."
  (cond
   ((eq val t) t)
   ((eq val :json-true) t)
   ((and (numberp val) (not (zerop val))) t)
   ((and (stringp val)
         (member (downcase (string-trim val)) '("true" "yes" "1" "on")))
    t)
   (t nil)))

(defun kargu--tool-flag (args &rest keys)
  "Non-nil when ARGS has an explicit true value for one of KEYS.
`:json-false' stays false.  Use this for boolean tool arguments."
  (kargu--json-true-p (apply #'kargu--tool-arg args keys)))

(defun kargu--tool-arg (args &rest keys)
  "First non-empty value in ARGS for KEYS (string keys)."
  (let (found)
    (dolist (key keys)
      (unless found
        (let ((val (kargu-aget args key)))
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
        (let ((val (kargu-aget args key)))
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
    (mapconcat (lambda (key) (format "%s" key))
               (if (hash-table-p args) (hash-table-keys args) (mapcar #'car args)) ", ")))

(defun kargu--tool-missing-file-path (args)
  "Describe the missing file path in tool ARGS."
  (let ((keys (kargu--tool-arg-keys args)))
    (if (and (kargu--object-p args)
             (or (kargu-aget args "pattern")
                 (kargu-aget args "query")
                 (kargu-aget args "regex")))
        (format "ERROR: missing file_path (also accepted: filePath, path). Got keys: %s. Note: file reading/editing tools require an exact file_path, not a search pattern. To search file contents for a pattern, use 'workspace_grep'. To find files by pattern/glob, use 'find_files'."
                keys)
      (format "ERROR: missing file_path (also accepted: filePath, path). Got keys: %s"
              keys))))

(defvar kargu--truncated-counter 0
  "Monotonic counter for truncated output buffer names.")

(defvar-local kargu--tool-output-root nil
  "Canonical project owning this generated tool output buffer.")

(defun kargu-tool-output-buffer (name)
  "Return the generated output buffer NAME owned by the current project.
User buffers and buffers converted into visiting files are never accepted."
  (when (stringp name)
    (let ((buffer (get-buffer name))
          (root (kargu-permission-project-root)))
      (when (and (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (and (not buffer-file-name) (equal kargu--tool-output-root root))))
        buffer))))

(defun kargu--preserve-tool-output (string)
  "Preserve STRING in a fresh buffer owned by the current project."
  (let* ((root (kargu-permission-project-root))
         (buffer (generate-new-buffer
                  (format "*kargu-output-%d*" (cl-incf kargu--truncated-counter)))))
    (with-current-buffer buffer
      (insert string)
      (setq-local kargu--tool-output-root root
                  buffer-offer-save nil
                  buffer-read-only t)
      (set-buffer-modified-p nil))
    (buffer-name buffer)))

(defun kargu--truncate-for-model (string)
  "Truncate STRING to `kargu-tool-output-limit' characters.
Preserves the complete output in a buffer named `*kargu-output-<N>*'
so the model can inspect remaining lines using `read_file'."
  (let ((kargu-tool-output-limit
         (kargu-usage-limit kargu-tool-output-limit kargu-low-usage-output-limit)))
    (if (and (natnump kargu-tool-output-limit)
             (> (length string) kargu-tool-output-limit))
	(let* ((omitted (- (length string) kargu-tool-output-limit))
               (buf-name (kargu--preserve-tool-output string)))
          (concat (substring string 0 kargu-tool-output-limit)
                  (format "\n... [Output truncated: omitted %d chars. Complete output (%d chars) preserved in buffer '%s'. You can read specific line ranges using read_file with path='%s' from_line=N to_line=M]"
                          omitted (length string) buf-name buf-name)))
      string)))

(defmacro kargu-safe-tool-call (&rest body)
  "Execute BODY, catching errors and formatting as an ERROR string."
  `(condition-case-unless-debug err
       (progn ,@body)
     (error (format "ERROR: %s" (error-message-string err)))))

(defun kargu--format-tool-result (res)
  "Format tool execution result RES as a string for consumption."
  (cond
   ((null res) "OK (no output)")
   ((stringp res)
    (if (string-empty-p res) "OK (no output)" res))
   (t (kargu-json-encode-record res))))

(defun kargu--tool-raw-args (arguments)
  "Return raw string representation of ARGUMENTS for logging."
  (cond
   ((stringp arguments) arguments)
   ((or (null arguments) (eq arguments :json-null)) "")
   (t (condition-case nil
          (kargu-json-encode-record arguments)
        (error (format "%S" arguments))))))

(defun kargu--executor-async-p (executor)
  "Non-nil when EXECUTOR accepts a completion callback as second argument."
  (let ((arity (func-arity executor)))
    (or (eq (cdr arity) 'many)
        (>= (cdr arity) 2))))

(defun kargu--execute-tool-async (executor args name callback)
  "Run tool NAME's EXECUTOR with ARGS and deliver once to CALLBACK."
  (let* ((task (kargu-async-start
                (lambda (value error)
                  (funcall callback (if error (format "ERROR: tool %s failed: %s" name error)
                                      value)))))
         (on-done
          (kargu-async-wrap
           task (lambda (res)
                  (let* ((formatted (kargu--format-tool-result res))
                         (final (kargu--truncate-for-model formatted)))
                    (kargu--log-block (format "tool %s result" name) formatted)
                    (kargu-async-finish task final))))))
    (funcall
     (kargu-async-wrap
      task (lambda ()
             (if (kargu--executor-async-p executor)
                 (let ((result (funcall executor args on-done)))
                   (when (and (stringp result) (string-prefix-p "ERROR:" result))
                     (funcall on-done result)))
               (funcall on-done (funcall executor args))))))))

(defun kargu--execute-tool-sync (executor args name)
  "Run tool NAME's EXECUTOR with ARGS and return the truncated result."
  (let ((out
         (condition-case-unless-debug err
             (kargu--format-tool-result (funcall executor args))
           (error
            (format "ERROR: tool %s failed: %s"
                    name (error-message-string err))))))
    (kargu--log-block (format "tool %s result" name) out)
    (kargu--truncate-for-model out)))

(defun kargu-execute-tool (name arguments &optional callback)
  "Run tool NAME with ARGUMENTS; ALWAYS return a result string or invoke CALLBACK.
When CALLBACK is provided, run asynchronously if the tool supports it.
Errors are captured and returned as \"ERROR: ...\" results so the
agent loop can feed them back to the model for self-correction."
  (let* ((spec (kargu--tool-spec name))
         (raw (kargu--tool-raw-args arguments))
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
     ((kargu-tool-policy-error name)
      (let ((out (kargu-tool-policy-error name)))
        (if callback (funcall callback out) out)))
     ((kargu--tool-arguments-invalid-p arguments)
      (let ((out (format "ERROR: the arguments of tool %s are not a valid JSON object; send one JSON object. Received: %s"
                         name (truncate-string-to-width raw 200))))
        (if callback (funcall callback out) out)))
     (callback
      (kargu--execute-tool-async (kargu-aget spec "executor") args name callback))
     (t
      (kargu--execute-tool-sync (kargu-aget spec "executor") args name)))))

(provide 'kargu/api/tools)

;;; tools.el ends here
