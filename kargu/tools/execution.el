;;; execution.el --- Unified tool execution gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Single gate for tool execution, parameter schema validation, mode check,
;; single-use approval verification, output budgeting, and async task tracking.
;; (Contract 5, MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'kargu/contract/assert)
(require 'kargu/contract/types)
(require 'kargu/contract/result)
(require 'kargu/async)
(require 'kargu/json)
(require 'kargu/core/custom)
(require 'kargu/tools/registry)
(require 'kargu/application/budget)
(require 'kargu/application/coordinator)
(require 'kargu/permission/guards)
(require 'kargu/permission/policy)
(require 'kargu/core/session)

(declare-function kargu-random-uuid "kargu/config/connection" ())
(declare-function kargu-usage-limit "kargu/core/custom" (limit low-limit))
(defvar kargu-permission-confirm-bash)
(defvar kargu-loop-mutating-tools)

;;; Output Archive Options & State -----------------------------------------

(defcustom kargu-tool-output-archive-max-buffers 32
  "Maximum number of unmodified generated output buffers to retain.
Zero disables new archives.  User-edited and visiting buffers are detached
from the archive and never killed to enforce its quota."
  :type 'natnum :group 'kargu)

(defcustom kargu-tool-output-archive-max-chars 8000000
  "Total character budget for generated tool output archives.
A larger single result keeps only its initial characters.  Zero disables
new archives; detached user buffers do not count toward this budget."
  :type 'natnum :group 'kargu)

(defvar kargu--tool-output-archive nil
  "Generated output buffers ordered from oldest to newest.")

(defvar-local kargu--tool-output-tick nil
  "Modification tick immediately after generated output was inserted.")

(defvar-local kargu--tool-output-root nil
  "Canonical project owning this generated tool output buffer.")

(defvar kargu--truncated-counter 0
  "Monotonic counter for unique archive buffer names.")

;;; Active execution tracking table ---------------------------------------

(defun kargu-tool-execution-active-task-count (registry name)
  "Return number of running tasks for NAME in REGISTRY."
  (let ((canonical (kargu-tool-registry-canonical-name registry name)))
    (length (gethash canonical (kargu-tool-registry-tasks registry)))))

(defun kargu-tool-execution--track-task (registry name task)
  "Track TASK for NAME in REGISTRY."
  (let* ((table (kargu-tool-registry-tasks registry))
         (existing (gethash name table)))
    (puthash name (cons task existing) table)))

(defun kargu-tool-execution--untrack-task (registry name task)
  "Untrack TASK for NAME in REGISTRY."
  (let* ((table (kargu-tool-registry-tasks registry))
         (existing (gethash name table))
         (updated (delq task existing)))
    (if updated
        (puthash name updated table)
      (remhash name table))))

(defun kargu-tool-execution--random-uuid ()
  "Generate a pseudo-random UUID string."
  (if (fboundp 'kargu-random-uuid)
      (funcall 'kargu-random-uuid)
    (format "%08x-%04x-%04x-%04x-%012x"
            (random #xffffffff)
            (random #xffff)
            (logior #x4000 (logand (random #xffff) #x0fff))
            (logior #x8000 (logand (random #xffff) #x3fff))
            (random #xffffffffffff))))

;;; Context & Approval structs --------------------------------------------

(cl-defstruct (kargu-tool-execution-context
               (:constructor kargu-tool-execution-context--create))
  "Context passed to tool execution gate."
  (context-id
   (format "exec-%s" (kargu-tool-execution--random-uuid)) :read-only t)
  (app nil :read-only t)
  (run-id nil :read-only t)
  (session-id nil :read-only t)
  (root default-directory :read-only t)
  (mode 'agent :read-only t)
  (budget-scope nil :read-only t)
  (policy-revision 0 :read-only t))

(cl-defun kargu-tool-execution-context-create
    (&key app run-id session-id root (mode 'agent)
          budget-scope (policy-revision 0))
  "Construct a validated `kargu-tool-execution-context'.
APP, RUN-ID, and SESSION-ID bind ownership.  ROOT is project boundary.
MODE defaults to agent.  BUDGET-SCOPE is an optional `kargu-run-budget'.
POLICY-REVISION is the monotonic policy revision."
  (let ((effective-root
         (file-name-as-directory
          (file-truename (or root (kargu-permission-project-root))))))
    (when app (kargu-contract-assert #'kargu-application-p app))
    (kargu-contract-assert #'kargu-contract-mode-p mode
                           "Invalid mode: %S" mode)
    (when budget-scope
      (kargu-contract-assert #'kargu-run-budget-p budget-scope
                             "Invalid budget: %S" budget-scope))
    (kargu-tool-execution-context--create
     :app app
     :run-id run-id
     :session-id session-id
     :root effective-root
     :mode mode
     :budget-scope budget-scope
     :policy-revision (or policy-revision 0))))

(cl-defstruct (kargu-tool-approval
               (:constructor kargu-tool-approval--create))
  "Single-use captured approval token for guarded execution."
  (token-id
   (format "appr-%s" (kargu-tool-execution--random-uuid)) :read-only t)
  (tool-name nil :read-only t)
  (args-hash nil :read-only t)
  (root nil :read-only t)
  (policy-revision 0 :read-only t)
  (environment-hash nil :read-only t)
  (claimed-p nil))

(defun kargu-tool-approval--hash-args (args)
  "Compute deterministic SHA256 hash of ARGS."
  (secure-hash 'sha256 (format "%S" args)))

(defun kargu-tool-approval--hash-env ()
  "Compute deterministic SHA256 hash of current `process-environment'."
  (secure-hash
   'sha256
   (format "%S" (sort (copy-sequence process-environment) #'string<))))

(cl-defun kargu-tool-approval-create
    (&key tool-name args root (policy-revision 0))
  "Create an unconsumed `kargu-tool-approval' token for TOOL-NAME.
Token binds ARGS and ROOT.  POLICY-REVISION binds to policy revision."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p tool-name)
  (let ((canon-root
         (file-name-as-directory
          (file-truename (or root default-directory)))))
    (kargu-tool-approval--create
     :tool-name tool-name
     :args-hash (kargu-tool-approval--hash-args args)
     :root canon-root
     :policy-revision (or policy-revision 0)
     :environment-hash (kargu-tool-approval--hash-env)
     :claimed-p nil)))

(cl-defun kargu-tool-approval-claim
    (approval &key tool-name args root policy-revision)
  "Attempt to claim single-use APPROVAL token.
TOOL-NAME, ARGS, ROOT, and POLICY-REVISION must match the captured token.
Returns (kargu-ok approval) on valid first claim, or (kargu-err ...)."
  (unless (kargu-tool-approval-p approval)
    (cl-return-from kargu-tool-approval-claim
      (kargu-err "Invalid approval structure" :invalid-approval)))
  (when (kargu-tool-approval-claimed-p approval)
    (cl-return-from kargu-tool-approval-claim
      (kargu-err "Approval token has already been claimed (replay rejected)"
                 :approval-stale)))
  (unless (equal (kargu-tool-approval-environment-hash approval)
                 (kargu-tool-approval--hash-env))
    (cl-return-from kargu-tool-approval-claim
      (kargu-err "Approval environment changed" :approval-mismatch)))
  (let ((cur-args-hash (kargu-tool-approval--hash-args args))
        (cur-root (file-name-as-directory
                   (file-truename (or root default-directory)))))
    (unless (equal (kargu-tool-approval-tool-name approval) tool-name)
      (cl-return-from kargu-tool-approval-claim
        (kargu-err "Approval tool name mismatch" :approval-mismatch)))
    (unless (equal (kargu-tool-approval-args-hash approval) cur-args-hash)
      (cl-return-from kargu-tool-approval-claim
        (kargu-err "Approval arguments hash mismatch" :approval-mismatch)))
    (unless (equal (kargu-tool-approval-root approval) cur-root)
      (cl-return-from kargu-tool-approval-claim
        (kargu-err "Approval directory root mismatch" :approval-mismatch)))
    (when (numberp policy-revision)
      (unless (eql (kargu-tool-approval-policy-revision approval)
                   policy-revision)
        (cl-return-from kargu-tool-approval-claim
          (kargu-err "Approval policy revision mismatch" :approval-mismatch))))
    (setf (kargu-tool-approval-claimed-p approval) t)
    (kargu-ok approval)))

;;; Output Redaction -------------------------------------------------------

(defconst kargu-tool-execution--secret-patterns
  '(;; Bearer tokens
    ("Bearer[ \t]+[-A-Za-z0-9_.]+" . "Bearer [REDACTED]")
    ;; Standard OpenAI/Anthropic/generic API keys (sk-...)
    ("\\(sk-[-A-Za-z0-9]\\{20,\\}\\)" . "[REDACTED-KEY]")
    ;; Key/secret fields in key-value pairs
    ("\\(\\(?:api[-_]?key\\|secret\\|token\\|password\\|auth\\)[\"']?[ \t]*[:=][ \t]*[\"']?\\)\\([-A-Za-z0-9_./+=]\\{8,\\}\\)"
     . "\\1[REDACTED]"))
  "Regex patterns and replacements for secret redaction in tool output.")

(defun kargu-tool-execution-redact (text)
  "Redact secrets and sensitive tokens from TEXT."
  (if (not (stringp text))
      text
    (let ((result text))
      (save-match-data
        (dolist (pair kargu-tool-execution--secret-patterns result)
          (setq result
                (replace-regexp-in-string (car pair) (cdr pair) result t)))))))

;;; Output Truncation & Archive Helpers ------------------------------------

(defun kargu--tool-output-evictable-p (buffer)
  "Return non-nil when BUFFER remains an untouched generated archive."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and kargu--tool-output-root (not buffer-file-name)
              (not (buffer-modified-p))
              (eql kargu--tool-output-tick (buffer-chars-modified-tick))))))

(defun kargu--prune-tool-output (incoming)
  "Evict oldest untouched archives to make room for INCOMING characters."
  (setq kargu--tool-output-archive
        (seq-filter #'kargu--tool-output-evictable-p
                    kargu--tool-output-archive))
  (let ((count (length kargu--tool-output-archive))
        (chars (cl-loop for buffer in kargu--tool-output-archive
                        sum (with-current-buffer buffer (buffer-size)))))
    (while (and kargu--tool-output-archive
                (or (>= count kargu-tool-output-archive-max-buffers)
                    (> (+ chars incoming)
                       kargu-tool-output-archive-max-chars)))
      (let ((oldest (pop kargu--tool-output-archive)))
        (cl-decf count)
        (cl-decf chars (with-current-buffer oldest (buffer-size)))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer oldest))))))

(defun kargu-tool-output-buffer (name)
  "Return the generated output buffer NAME owned by the current project."
  (when (stringp name)
    (let ((buffer (get-buffer name))
          (root (kargu-permission-project-root)))
      (when (and (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (and (not buffer-file-name)
                        (equal kargu--tool-output-root root))))
        buffer))))

(defun kargu--preserve-tool-output (string &optional root)
  "Archive STRING within the quotas; return its buffer name, or nil.
ROOT is the owning project (default `kargu-permission-project-root')."
  (when (and (> kargu-tool-output-archive-max-buffers 0)
             (> kargu-tool-output-archive-max-chars 0))
    (let ((chars (min (length string) kargu-tool-output-archive-max-chars))
          (effective-root (or root (kargu-permission-project-root))))
      (kargu--prune-tool-output chars)
      (let ((buffer (generate-new-buffer
                     (format "*kargu-output-%d*"
                             (cl-incf kargu--truncated-counter)))))
        (with-current-buffer buffer
          (insert (substring string 0 chars))
          (setq-local kargu--tool-output-root effective-root
                      kargu--tool-output-tick (buffer-chars-modified-tick)
                      buffer-offer-save nil
                      buffer-read-only t)
          (set-buffer-modified-p nil))
        (setq kargu--tool-output-archive
              (nconc kargu--tool-output-archive (list buffer)))
        (buffer-name buffer)))))

(defun kargu--tool-output-archive-note (name total)
  "Describe archived output NAME against TOTAL characters."
  (if (not name) "Output not archived (archive quota is zero)."
    (let ((stored (with-current-buffer (get-buffer name) (buffer-size))))
      (format "%s preserved in buffer '%s'. Archives may be evicted; read ranges with read_file path='%s' from_line=N to_line=M."
              (if (= stored total)
                  (format "Complete output (%d chars)" total)
                (format "Only the first %d of %d chars" stored total))
              name name))))

(defun kargu-tool-execution-truncate-for-model (string &optional root)
  "Truncate STRING to `kargu-tool-output-limit' and archive excess under ROOT."
  (let ((limit (if (boundp 'kargu-tool-output-limit)
                   (if (fboundp 'kargu-usage-limit)
                       (kargu-usage-limit
                        kargu-tool-output-limit
                        (and (boundp 'kargu-low-usage-output-limit)
                             kargu-low-usage-output-limit))
                     kargu-tool-output-limit)
                 30000)))
    (if (and (natnump limit) (> (length string) limit))
        (let* ((omitted (- (length string) limit))
               (buf-name (kargu--preserve-tool-output string root)))
          (concat (substring string 0 limit)
                  (format "\n... [Output truncated: omitted %d chars. %s]"
                          omitted
                          (kargu--tool-output-archive-note
                           buf-name (length string)))))
      string)))

(defun kargu-tool-execution-format-result (res)
  "Format tool execution result RES as a string for consumption."
  (cond
   ((null res) "OK (no output)")
   ((stringp res)
    (if (string-empty-p res) "OK (no output)" res))
   (t (kargu-json-encode-record res))))

(defun kargu-tool-execution-decode-arguments (arguments)
  "Normalize tool ARGUMENTS to an object, nil, or :invalid."
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

(defun kargu--executor-async-p (executor)
  "Non-nil when EXECUTOR accepts a completion callback as second argument."
  (let ((arity (func-arity executor)))
    (or (eq (cdr arity) 'many)
        (>= (cdr arity) 2))))

;;; Execution Gate Pipeline ------------------------------------------------

(defconst kargu-tool-execution--write-tools
  '("edit_file" "write_file" "edit" "write" "apply_patch" "patch" "bash"
    "edit_by_lsp" "replace_symbol" "edit_symbol" "edit_with_lsp" "edit_by_symbol"
    "git_commit" "git_stage" "git_unstage" "git_branch" "git_stash")
  "Built-in write restrictions; custom mode policy may only add restrictions.")

(defun kargu-tool-execution--mode-error (definition context name)
  "Return a mode refusal for DEFINITION in CONTEXT under NAME, or nil."
  (let* ((mode (kargu-tool-execution-context-mode context))
         (modes (plist-get (kargu-tool-definition-policy definition) :modes))
         (canonical (kargu-tool-definition-name definition))
         (restricted (append kargu-tool-execution--write-tools
                             (and (boundp 'kargu-loop-mutating-tools)
                                  kargu-loop-mutating-tools))))
    (when (or (and modes (not (memq mode modes)))
              (and (not (eq mode 'agent))
                   (or (member canonical restricted) (member name restricted))))
      (kargu-err (format "ERROR: Tool %s is unavailable in %s mode." name mode)
                 :mode-forbidden))))

(defun kargu-tool-execution--policy-error (definition context name)
  "Return the first availability or budget refusal for DEFINITION in CONTEXT.
NAME identifies the tool without including its arguments."
  (let* ((available (plist-get (kargu-tool-definition-policy definition) :available-p))
         (refusal (and available (funcall available)))
         (budget (kargu-tool-execution-context-budget-scope context)))
    (cond
     (refusal (kargu-err (if (stringp refusal) refusal
                           (format "ERROR: tool %s unavailable" name)) :tool-unavailable))
     ((and budget (not (kargu-budget-live-p budget)))
      (kargu-err "ERROR: Run budget exhausted before tool execution" :budget-exhausted)))))

(cl-defun kargu-tool-execution--validate-gate (registry context name raw-args)
  "Decode RAW-ARGS and validate REGISTRY, CONTEXT and tool NAME once.
Domain-specific fields remain the handler's validation responsibility."
  (unless (kargu-tool-registry-p registry)
    (cl-return-from kargu-tool-execution--validate-gate
      (kargu-err "ERROR: Invalid registry handle" :invalid-registry)))
  (unless (kargu-tool-execution-context-p context)
    (cl-return-from kargu-tool-execution--validate-gate
      (kargu-err "ERROR: Invalid execution context" :invalid-context)))
  (let* ((definition (kargu-tool-registry-find registry name))
         (refusal
          (cond
           ((null definition) (kargu-err (format "ERROR: no such tool: %s" name) :no-such-tool))
           ((kargu-tool-registry-draining-p registry name)
            (kargu-err (format "ERROR: tool %s is currently draining/unloading" name) :tool-draining))
           (t (or (kargu-tool-execution--mode-error definition context name)
                  (kargu-tool-execution--policy-error definition context name))))))
    (if refusal refusal
      (let ((decoded (kargu-tool-execution-decode-arguments raw-args)))
        (if (eq decoded :invalid)
            (kargu-err (format "ERROR: the arguments of tool %s are not a valid JSON object; send one JSON object."
                               name) :invalid-arguments)
          (kargu-ok (list (kargu-tool-definition-name definition) definition decoded)))))))

(cl-defstruct (kargu-tool-invocation (:constructor kargu-tool-invocation--create))
  "One prepared invocation, tied to registry revision and caller authority."
  registry context definition args revision origin session environment path task synchronous app-run)

(defun kargu-tool-execution--current-p (invocation)
  "Return non-nil while INVOCATION still owns its prepared authority."
  (let ((origin (kargu-tool-invocation-origin invocation)))
    (and (buffer-live-p origin)
         (= (kargu-tool-invocation-revision invocation)
            (kargu-tool-registry-revision (kargu-tool-invocation-registry invocation)))
         (with-current-buffer origin
           (and (equal (kargu-tool-invocation-environment invocation) process-environment)
                (equal (kargu-tool-invocation-path invocation) exec-path)))
         (let ((app (kargu-tool-execution-context-app
                     (kargu-tool-invocation-context invocation))))
           (or (null app)
               (eq (kargu-tool-invocation-app-run invocation)
                   (or (kargu-application-active-claim-token app)
                       (kargu-application-current-run app)))))
         (or (null (kargu-tool-invocation-session invocation))
             (eq (kargu-tool-invocation-session invocation)
                 (kargu-session-context origin))))))

(defun kargu-tool-execution--complete (invocation result)
  "Format, sanitize and deliver RESULT for INVOCATION once."
  (let* ((context (kargu-tool-invocation-context invocation))
         (text (kargu-tool-execution-redact
                (kargu-tool-execution-format-result result))))
    ;; Tool output is not a provider request or a provider usage measurement.
    (kargu-async-finish
     (kargu-tool-invocation-task invocation)
     (kargu-tool-execution-truncate-for-model
      text (kargu-tool-execution-context-root context)))))

(defun kargu-tool-execution--dispatch (invocation)
  "Enter INVOCATION's executor once, using its captured project."
  (let* ((task (kargu-tool-invocation-task invocation))
         (executor (kargu-tool-definition-executor
                    (kargu-tool-invocation-definition invocation)))
         (args (kargu-tool-invocation-args invocation))
         (root (kargu-tool-execution-context-root
                (kargu-tool-invocation-context invocation)))
         (done (kargu-async-wrap task
                                 (lambda (result)
                                   (kargu-tool-execution--complete invocation result)))))
    (funcall
     (kargu-async-wrap
      task
      (lambda ()
        (let ((kargu-permission--override-root root))
          (cond
           ((and (kargu-tool-invocation-synchronous invocation)
                 (<= (car (func-arity executor)) 1))
            (funcall done (funcall executor args)))
           ((kargu--executor-async-p executor)
            (let ((result (funcall executor args done)))
              (when (and (stringp result) (string-prefix-p "ERROR:" result))
                (funcall done result))))
           (t (funcall done (funcall executor args))))))))))

(defun kargu-tool-execution--claim-approval (invocation approval)
  "Consume APPROVAL for INVOCATION before dispatching any effect."
  (let* ((context (kargu-tool-invocation-context invocation))
         (claim (kargu-tool-approval-claim
                 approval
                 :tool-name (kargu-tool-definition-name
                             (kargu-tool-invocation-definition invocation))
                 :args (kargu-tool-invocation-args invocation)
                 :root (kargu-tool-execution-context-root context)
                 :policy-revision (kargu-tool-execution-context-policy-revision context))))
    (if (kargu-err-p claim)
        (kargu-async-finish (kargu-tool-invocation-task invocation) nil
                            (kargu-result-err-message claim))
      (kargu-tool-execution--dispatch invocation))))

(defun kargu-tool-execution--request-approval (invocation)
  "Capture authority before asking for INVOCATION's one-use approval."
  (let* ((task (kargu-tool-invocation-task invocation))
         (context (kargu-tool-invocation-context invocation))
         (name (kargu-tool-definition-name (kargu-tool-invocation-definition invocation)))
         (root (kargu-tool-execution-context-root context))
         (approval (kargu-tool-approval-create
                    :tool-name name :args (kargu-tool-invocation-args invocation)
                    :root root
                    :policy-revision (kargu-tool-execution-context-policy-revision context)))
         (handle
          (kargu-permission-request-approval-async
           (format "Execute tool %s" name) root nil
           (kargu-async-wrap
            task (lambda (accepted)
                   (if accepted
                       (kargu-tool-execution--claim-approval invocation approval)
                     (kargu-async-finish task nil "Command was not approved by the user")))))))
    (when handle
      (kargu-async-add-cleanup task (lambda () (kargu-cancel-confirmation handle))))))

(cl-defun kargu-tool-gate-execute
    (registry context name raw-args &key callback approval synchronous)
  "Execute NAME with RAW-ARGS in REGISTRY and CONTEXT through one gate.
CALLBACK receives one result; APPROVAL is a captured capability.
SYNCHRONOUS selects a legacy one-argument executor boundary, never a wait."
  (let* ((checked (condition-case nil
                      (kargu-tool-execution--validate-gate registry context name raw-args)
                    (error (kargu-err "ERROR: Tool validation failed" :invalid-arguments))))
         (data (and (kargu-ok-p checked) (kargu-result-value checked)))
         (invocation (kargu-tool-invocation--create
                      :registry registry :context context
                      :definition (nth 1 data) :args (nth 2 data)
                      :revision (and data (kargu-tool-registry-revision registry))
                      :origin (current-buffer) :session (kargu-session-context)
                      :app-run (and data (kargu-tool-execution-context-app context)
                                    (let ((app (kargu-tool-execution-context-app context)))
                                      (or (kargu-application-active-claim-token app)
                                          (kargu-application-current-run app))))
                      :environment (copy-sequence process-environment)
                      :path (copy-sequence exec-path) :synchronous synchronous))
         (task (kargu-async-start
                (lambda (value error)
                  (when callback
                    (funcall callback (if error (format "ERROR: %s" error) value))))
                :valid-p (and data (lambda () (kargu-tool-execution--current-p invocation))))))
    (setf (kargu-tool-invocation-task invocation) task)
    (cond
     ((kargu-err-p checked)
      (kargu-async-finish task (kargu-result-err-message checked)))
     (t
      (kargu-tool-execution--track-task registry (car data) task)
      (kargu-async-add-cleanup
       task (lambda () (kargu-tool-execution--untrack-task registry (car data) task)))
      (funcall
       (kargu-async-wrap
        task (lambda ()
               (cond
                (approval (kargu-tool-execution--claim-approval invocation approval))
                ((plist-get (kargu-tool-definition-policy (nth 1 data)) :needs-approval-p)
                 (kargu-tool-execution--request-approval invocation))
                (t (kargu-tool-execution--dispatch invocation))))))))
    task))

(cl-defun kargu-tool-gate-execute-sync (registry context name raw-args &key approval)
  "Invoke NAME with RAW-ARGS in REGISTRY and CONTEXT, without waiting.
APPROVAL is optional; asynchronous decisions return a pending notice."
  (let (result)
    (kargu-tool-gate-execute
     registry context name raw-args :approval approval :synchronous t
     :callback (lambda (value) (setq result value)))
    (or result "STAGED: operation pending; use a completion callback for its final result.")))

;;; Draining & Unload Lifecycle --------------------------------------------

(cl-defun kargu-tool-execution-drain
    (registry name &key cancel-p callback)
  "Safely drain active tasks for NAME in REGISTRY before unload.
If CANCEL-P is non-nil, cancels active tasks.  Calls CALLBACK once drained."
  (let* ((canonical (kargu-tool-registry-canonical-name registry name))
         (active
          (copy-sequence
           (gethash canonical (kargu-tool-registry-tasks registry)))))
    (kargu-tool-registry-mark-draining registry canonical)
    (when cancel-p
      (dolist (task active)
        (kargu-async-cancel task)))
    (if (zerop (kargu-tool-execution-active-task-count registry canonical))
        (let ((removed (kargu-tool-registry-remove registry canonical)))
          (when callback (funcall callback t))
          removed)
      (let ((poller nil))
        (setq poller
              (run-with-timer
               0.02 0.02
               (lambda ()
                 (when (zerop (kargu-tool-execution-active-task-count
                               registry canonical))
                   (cancel-timer poller)
                   (kargu-tool-registry-remove registry canonical)
                   (when callback (funcall callback t))))))))))

(provide 'kargu/tools/execution)
;;; execution.el ends here
