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
(require 'kargu/tools/registry)
(require 'kargu/tools/execution)

;;;; Tool registry ---------------------------------------------------------

(defvar kargu--tool-registry (kargu-tool-registry-create)
  "Legacy default registry awaiting explicit application ownership.")

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
  (kargu-tool-registry-register kargu--tool-registry
                                :name name :description description
                                :parameters parameters :executor executor
                                :policy policy)
  (kargu-log 'debug "tool registered: %s" name)
  name)

(defun kargu-registered-tools ()
  "Return the names of all registered tools."
  (kargu-tool-registry-names kargu--tool-registry))

(defun kargu-registered-tool-count ()
  "Return the number of registered tools, including compatibility aliases."
  (kargu-tool-registry-count kargu--tool-registry))

(defun kargu-find-tool (name)
  "Return the typed canonical definition of tool NAME, or nil.
Consumers must treat definition fields and nested values as read-only."
  (kargu-tool-registry-find kargu--tool-registry name))

(defun kargu-unregister-tool (name)
  "Remove tool NAME and its aliases, or just NAME when it is an alias.
Drains and cancels active tasks before unregistering."
  (kargu-tool-execution-drain kargu--tool-registry name :cancel-p t))

(defun kargu-canonical-tool-name (name)
  "Return the canonical tool name for NAME, resolving compatibility aliases."
  (kargu-tool-registry-canonical-name kargu--tool-registry name))

(defun kargu-advertised-tools ()
  "List visible canonical tool names in deterministic order."
  (sort (seq-filter (lambda (name)
                      (and (equal name (kargu-canonical-tool-name name))
                           (kargu-tool-visible-p name)))
                    (kargu-registered-tools)) #'string<))

(defun kargu-tool-description (name)
  "Return the registered description of tool NAME."
  (when-let* ((definition (kargu-find-tool name)))
    (kargu-tool-definition-description definition)))

(defun kargu-set-tool-policy (name policy)
  "Set POLICY for registered tool NAME and its aliases."
  (kargu-tool-registry-set-policy kargu--tool-registry name policy))

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
  (let* ((definition (kargu-find-tool name))
         (policy (and definition (kargu-tool-definition-policy definition)))
         (modes (plist-get policy :modes))
         (available (plist-get policy :available-p)))
    (cond
     ((and modes (not (memq (kargu-state-mode) modes)))
      (format "ERROR: Tool %s is unavailable in %s mode."
              name (kargu-state-mode)))
     (available (funcall available)))))

(defun kargu-tool-visible-p (name)
  "Return non-nil if tool NAME is visible to the model.
Delegates to `kargu--tools-visible-p' if set, otherwise to
`kargu-loop-tool-visible-p' if defined, defaulting to t."
  (cond
   (kargu--tools-visible-p
    (and (not (kargu-tool-policy-error name))
         (funcall kargu--tools-visible-p name)))
   ((fboundp 'kargu-loop-tool-visible-p) (kargu-loop-tool-visible-p name))
   (t (not (kargu-tool-policy-error name)))))

(defun kargu--build-tools-vector ()
  "Build the OpenAI \"tools\" array (as a vector) from the registry.
Visibility is decided once by `kargu-advertised-tools'."
  (cl-map 'vector
          (lambda (name)
            (let ((definition (kargu-find-tool name)))
              `(("type" . "function")
                ("function" . (("name" . ,name)
                               ("description" .
                                ,(kargu-tool-definition-description definition))
                               ("parameters" .
                                ,(kargu--sanitize-tool-parameters
                                  (kargu-tool-definition-parameters definition))))))))
          (kargu-advertised-tools)))

(defun kargu-tool-schema-char-count ()
  "Return the serialized character cost of currently advertised tool schemas."
  (length (kargu-json-encode-record (kargu--build-tools-vector))))

(defun kargu-register-tool-alias (alias name)
  "Expose registered tool NAME under ALIAS as well."
  (let ((registered (kargu-tool-registry-alias kargu--tool-registry alias name)))
    (if (null registered)
        (kargu-log 'warn "tool alias %s: no such tool %s" alias name)
      (kargu-log 'debug "tool alias %s -> %s" alias name)
      alias)))

(defun kargu--decode-tool-arguments (arguments)
  "Normalize tool ARGUMENTS to an object, nil, or :invalid.
A valid empty object {} becomes nil; nonobjects are rejected.
Concatenated JSON objects keep the last object."
  (cond
   ((memq arguments '(nil :json-null)) nil)
   ((stringp arguments)
    (let ((trimmed (string-trim arguments)))
      (if (or (string-empty-p trimmed) (equal trimmed "{}"))
          nil
        (let ((parsed (kargu--json-decode-lenient trimmed)))
          (if (and parsed (kargu--object-p (cdr parsed)))
              (cdr parsed)
            :invalid)))))
   ((kargu--object-p arguments) arguments)
   (t :invalid)))

(defun kargu--encode-tool-arguments (arguments)
  "Return ARGUMENTS as a single valid JSON object string.
Used when storing tool_calls so the next POST cannot 400 on
concatenated or empty snapshots."
  (let ((decoded (kargu--decode-tool-arguments arguments)))
    (if (kargu--object-p decoded) (kargu-json-encode-record decoded) "{}")))

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

(defun kargu--truncate-for-model (string)
  "Bound STRING through the shared tool output boundary."
  (kargu-tool-execution-truncate-for-model string))

(defmacro kargu-safe-tool-call (&rest body)
  "Execute BODY, catching errors and formatting as an ERROR string."
  `(condition-case-unless-debug err
       (progn ,@body)
     (error (format "ERROR: %s" (error-message-string err)))))

(defun kargu-execute-tool (name arguments &optional callback)
  "Execute NAME with ARGUMENTS through the shared gate once.
CALLBACK receives the asynchronous result; without it, no waiting occurs."
  (let* ((run (bound-and-true-p kargu--loop-run))
         (context (kargu-tool-execution-context-create
                   :root (or (plist-get run :project-root) (kargu-permission-project-root))
                   :mode (or (plist-get run :mode) (kargu-state-mode))
                   :budget-scope (plist-get run :budget)
                   :policy-revision (kargu-tool-registry-revision kargu--tool-registry))))
    (if callback
        (progn
          (kargu-tool-gate-execute kargu--tool-registry context name arguments
                                 :callback callback)
          nil)
      (kargu-tool-gate-execute-sync kargu--tool-registry context name arguments))))

(provide 'kargu/api/tools)

;;; tools.el ends here
