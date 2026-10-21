;;; context.el --- Debug context, evaluation and breakpoints -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Fetch paused runtime data and manage source breakpoints.

;;; Code:

(require 'kargu/tools/dape/render)
(require 'kargu/async)
(require 'kargu/contract/assert)
(require 'kargu/tools/process)
(require 'kargu/tools/dape/events)
(require 'kargu/tools/dape/selection)

(declare-function kargu--tool-arg "kargu/api/tools" (args &rest keys))
(declare-function kargu--tool-file-path "kargu/api/tools" (args))
(declare-function kargu--tool-arg-keys "kargu/api/tools" (args))
(declare-function kargu-session-id "kargu/core/session" ())
(declare-function kargu-session-context "kargu/core/session" (&optional buffer))

(defcustom kargu-dape-request-timeout 30
  "Seconds allowed for an entire debugger inspection callback chain."
  :type 'number
  :group 'kargu-dape)

(cl-defun kargu-dape--inspection-valid-p (selection origin &key root session implicit)
  "Check SELECTION in ORIGIN against ROOT, SESSION and IMPLICIT adapter choice."
  (and (buffer-live-p origin)
       (with-current-buffer origin
         (let ((conn (kargu-dape-selection-connection selection)))
           (and (equal root (kargu-permission-project-root))
                (equal session (kargu-session-id))
                (memq conn (kargu-dape-project-connections root))
                (or (not implicit) (eq conn (kargu-dape--raw-connection)))
                (kargu-dape-selection-valid-p selection))))))

(defun kargu-dape--admit-selection (conn selection)
  "Resolve SELECTION on CONN, returning an explanatory error on refusal."
  (condition-case err
      (let ((selection (or selection (kargu-dape-capture-selection conn))))
        (unless (eq conn (kargu-dape-selection-connection selection))
          (error "Captured debug selection belongs to another adapter"))
        (unless (kargu-dape-selection-valid-p selection)
          (error "Captured debug selection state changed before inspection"))
        selection)
    (error (concat "ERROR: DAP: " (error-message-string err)))))

(defun kargu-dape--prepare-inspection (selection continue levels)
  "Fetch SELECTION's isolated stack before CONTINUE, requesting LEVELS frames."
  (if (kargu-dape-selection-prepared selection)
      (funcall continue)
    (kargu-dape--call
     #'dape--stack-trace (kargu-dape-selection-connection selection)
     (kargu-dape-selection-thread selection) levels
     (lambda (&rest _)
       (when (and (kargu-dape-selection-frame-id selection)
                  (not (kargu-dape-selection-frame selection)))
         (error "Requested debug frame is absent from the captured thread's stack"))
       (setf (kargu-dape-selection-prepared selection) t)
       (funcall continue)))))

(cl-defun kargu-dape--run-chain (callback starter &key connection selection (levels kargu-dape-max-frames))
  "Run STARTER with guarded CALLBACK, CONNECTION, SELECTION and stack LEVELS.
STARTER receives the completion callback and the admitted selection."
  (let* ((conn (or connection (and selection (kargu-dape-selection-connection selection))
                   (kargu-dape--connection)))
         (selected (if (stringp conn) conn (kargu-dape--admit-selection conn selection)))
         (root (kargu-permission-project-root))
         (session (copy-sequence (kargu-session-id)))
         (origin (current-buffer)))
    (if (stringp selected) (kargu-dape--deliver callback selected nil)
      (let* ((task (kargu-async-start
                    (lambda (value error)
                      (funcall (or callback #'kargu-dape--show-report)
                               (if error (concat "ERROR: DAP: " error) value)))
                    :timeout kargu-dape-request-timeout
                    :valid-p (lambda ()
                               (kargu-dape--inspection-valid-p
                                selected origin :root root :session session
                                :implicit (not (or connection selection))))))
             (finish (kargu-async-wrap task (lambda (text) (kargu-async-finish task text)))))
        (funcall (kargu-async-wrap
                  task (lambda ()
                         (kargu-dape--prepare-inspection
                          selected (lambda () (funcall starter finish selected)) levels))))
        task))))

(defun kargu-dape--call (function &rest args)
  "Call DAP FUNCTION with ARGS, guarding its final callback."
  (let ((task kargu-async--current-task)
        (callback (car (last args)))
        (reply-state :pending))
    (unless task (error "DAP request needs a task lifecycle"))
    (apply (kargu-async-wrap task function)
           (append (butlast args)
                   (list (kargu-async-wrap
                          task (lambda (&rest values)
                                 (when (eq reply-state :pending)
                                   (setq reply-state :delivered)
                                   (if (cadr values)
                                       (kargu-async-finish task nil (format "%s" (cadr values)))
                                     (apply callback values))))))))))

(declare-function kargu-dape--show-report "kargu/tools/dape/execution" (report))

;;;; Context (stack + scopes + variables) ----------------------------------

(defun kargu-dape--deliver (callback text interactive)
  "Give TEXT to CALLBACK, or return it when CALLBACK is nil.
INTERACTIVE also shows a short prefix in the echo area."
  (when interactive
    (message "%s" (truncate-string-to-width (or text "") 200)))
  (if callback
      (progn (funcall callback text) nil)
    text))

(defun kargu-dape--fetch-variables (conn scopes callback)
  "Fetch inexpensive SCOPES on CONN, then invoke CALLBACK."
  (let ((rest (cl-remove-if (lambda (scope) (eq (plist-get scope :expensive) t))
                            (or scopes nil))))
    (cl-labels ((next ()
                  (if (null rest)
                      (funcall callback)
                    (kargu-dape--call #'dape--variables conn (pop rest) (lambda (&rest _) (next))))))
      (next))))

(defun kargu-dape-context-snapshot ()
  "Text of the context already stored on the connection, with no DAP request."
  (let ((conn (kargu-dape--connection)))
    (if (stringp conn)
        conn
      (let* ((thread (kargu-dape-inspection-thread conn))
             (frames (and thread
                          (kargu-seq-to-list (plist-get thread :stackFrames))))
             (id (dape--stack-id conn))
             (frame (if id (seq-find (lambda (item) (equal id (plist-get item :id))) frames)
                      (car frames))))
        (kargu-dape--render-context conn thread frames frame)))))

(defun kargu-dape--context-text (conn thread frames frame)
  "Log and return the context of THREAD, FRAMES and FRAME on CONN."
  (let ((text (kargu-dape--render-context conn thread frames frame)))
    (kargu-log 'info "dape context: %d frames, thread #%s"
               (length (or frames nil))
               (and thread (plist-get thread :id)))
    text))

(defun kargu-dape--collect-selection-context (selection callback interactive)
  "Collect SELECTION's scopes for CALLBACK, displaying when INTERACTIVE."
  (let* ((conn (kargu-dape-selection-connection selection))
         (thread (kargu-dape-selection-thread selection))
         (frames (kargu-seq-to-list (plist-get thread :stackFrames)))
         (frame (kargu-dape-selection-frame selection)))
    (when (and (kargu-dape-selection-frame-id selection) (null frame))
      (error "Requested debug frame is absent from the captured thread's stack"))
    (if (null frame)
        (kargu-dape--deliver callback (kargu-dape--context-text conn thread frames nil) interactive)
      (kargu-dape--call
       #'dape--scopes conn frame
       (lambda (&rest _)
         (kargu-dape--fetch-variables
          conn (kargu-seq-to-list (plist-get frame :scopes))
          (lambda ()
            (kargu-dape--deliver callback (kargu-dape--context-text conn thread frames frame) interactive))))))))

;;;; Expression evaluation -------------------------------------------------

(defun kargu-dape--format-language-hint (expr context-or-err)
  "Format a language hint string for EXPR and CONTEXT-OR-ERR if available."
  (let* ((active-lang (and (fboundp 'kargu-language-active)
                           (kargu-language-active)))
         (hint (and active-lang (kargu-language-eval-hint active-lang expr context-or-err))))
    (if hint
        (format "\n💡 Language Hint (%s): %s"
                (kargu-language-spec-name active-lang) hint)
      "")))

(defun kargu-dape--eval-text (expr body err-msg)
  "Text for evaluating EXPR that produced BODY or ERR-MSG."
  (cond
   (err-msg
    (format "ERROR: evaluate '%s' failed: %s%s"
            expr err-msg
            (kargu-dape--format-language-hint expr err-msg)))
   ((and body (plist-get body :result))
    (format "%s => %s" expr (kargu-dape--trunc (plist-get body :result))))
   (t (format "%s => (evaluated, no result value)" expr))))

(cl-defun kargu-dape--eval-expression (expr selection callback &key context)
  "Evaluate EXPR in prepared SELECTION and deliver its text to CALLBACK.
CONTEXT defaults to \"repl\" and also accepts \"hover\" or \"watch\"."
  (let ((frame (kargu-dape-selection-frame selection)))
    (unless frame (error "No stack frame available for evaluation"))
    (kargu-dape--call
     #'dape--evaluate-expression (kargu-dape-selection-connection selection)
     (plist-get frame :id) expr (or context "repl")
     (lambda (result error)
       (kargu-dape--deliver callback (kargu-dape--eval-text expr result error) nil)))))

;;;; Breakpoints -----------------------------------------------------------

(defun kargu-dape--project-source-path (file-path)
  "Return canonical FILE-PATH inside this workspace, or nil.
Adapter paths never authorize an implicit remote connection or external read."
  (save-match-data
    (when (and (stringp file-path) (not (string-empty-p file-path))
               (not (file-remote-p file-path)))
      (condition-case nil
          (let* ((root (kargu-permission-project-root))
                 (path (file-truename (expand-file-name file-path root))))
            (when (kargu-permission-within-project-p path root) path))
        (file-error nil)))))

(defconst kargu-dape--source-budget 65536
  "Maximum disk bytes or live buffer characters inspected for a source quote.
Oversized sources are unavailable, never represented by a partial read.")

(defconst kargu-dape--worker-root
  (file-name-directory (directory-file-name
                        (file-name-directory (locate-library "kargu/async"))))
  "Package source root used for isolated bounded Dape source workers.")

(defconst kargu-dape--worker-reply-overhead 8192
  "Allowance for JSON envelope and path bytes in a Dape source worker reply.")

(cl-defstruct (kargu-dape-source-read-operation
               (:constructor kargu-dape--make-source-read))
  "One bounded debugger source read operation and its ownership state."
  (path nil :read-only t) (origin nil :read-only t)
  (root nil :read-only t) (session nil :read-only t)
  (session-ctx nil :read-only t) (owner nil :read-only t)
  (budget nil :read-only t) (selection nil :read-only t)
  (buffer-ticks nil :read-only t) task)

(defun kargu-dape--capture-buffer-ticks ()
  "Snapshot live file-visiting buffer modification ticks in memory."
  (delq nil
        (mapcar (lambda (buffer)
                  (when (and (buffer-live-p buffer) (buffer-file-name buffer))
                    (cons buffer (buffer-chars-modified-tick buffer))))
                (buffer-list))))

(defun kargu-dape--buffer-source-text (buffer budget)
  "Return BUFFER's widened text when within BUDGET, preserving editor state."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (when (<= (buffer-size) budget)
          (buffer-substring-no-properties (point-min) (point-max)))))))

(defun kargu-dape--live-buffer-generation-valid-p (buffer buffer-ticks)
  "Return non-nil when BUFFER was not modified after BUFFER-TICKS snapshot."
  (let ((entry (assq buffer buffer-ticks)))
    (if entry
        (eql (cdr entry) (buffer-chars-modified-tick buffer))
      (not (buffer-modified-p buffer)))))

(defun kargu-dape--live-buffer-for-expanded (expanded root)
  "Return live buffer visiting EXPANDED when its truename is inside ROOT."
  (let ((buffer (get-file-buffer expanded)))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer
                 (and (stringp buffer-file-name)
                      (stringp buffer-file-truename)
                      (equal (expand-file-name buffer-file-name root) expanded)
                      (equal (expand-file-name buffer-file-truename root) expanded)
                      (or (string= buffer-file-truename (directory-file-name root))
                          (string-prefix-p root (file-name-as-directory buffer-file-truename))))))
      buffer)))

(defun kargu-dape--live-buffer-for-truename (canonical)
  "Return live buffer visiting CANONICAL truename without disk I/O."
  (or (get-file-buffer canonical)
      (seq-find (lambda (buffer)
                  (and (buffer-live-p buffer)
                       (or (equal (buffer-file-name buffer) canonical)
                           (equal (buffer-local-value 'buffer-file-truename buffer)
                                  canonical))))
                (buffer-list))))

(defun kargu-dape--source-read-valid-p (operation)
  "Return non-nil while OPERATION still owns its workspace, session and selection."
  (let ((origin (kargu-dape-source-read-operation-origin operation))
        (selection (kargu-dape-source-read-operation-selection operation)))
    (and (buffer-live-p origin)
         (eq (kargu-dape-source-read-operation-owner operation) kargu--loop-run)
         (with-current-buffer origin
           (and (equal (kargu-dape-source-read-operation-root operation)
                       (kargu-permission-project-root))
                (equal (kargu-dape-source-read-operation-session operation)
                       (kargu-session-id))
                (eq (kargu-dape-source-read-operation-session-ctx operation)
                    (kargu-session-context))
                (or (null selection)
                    (and (kargu-dape--inspection-valid-p
                          selection origin
                          :root (kargu-dape-source-read-operation-root operation)
                          :session (kargu-dape-source-read-operation-session operation))
                         (kargu-dape-selection-current-p selection))))))))

(defun kargu-dape--decode-source-read (operation process-result)
  "Validate PROCESS-RESULT against OPERATION and reconcile with live buffers."
  (unless (and (eql 0 (plist-get process-result :code))
               (not (plist-get process-result :timed-out))
               (not (plist-get process-result :truncated)))
    (error "%s" (kargu-process-failure "Debugger source read" process-result)))
  (let* ((reply (json-parse-string (plist-get process-result :output)
                                   :object-type 'plist :null-object nil
                                   :false-object :json-false))
         (status (plist-get reply :status))
         (canonical (plist-get reply :path))
         (disk-text (plist-get reply :text))
         (root (kargu-dape-source-read-operation-root operation))
         (budget (kargu-dape-source-read-operation-budget operation))
         (ticks (kargu-dape-source-read-operation-buffer-ticks operation)))
    (pcase status
      ("ok"
       (if (not (and (stringp canonical) (not (string-empty-p canonical))
                     (or (string= canonical (directory-file-name root))
                         (string-prefix-p root (file-name-as-directory canonical)))))
           (list :path nil :text nil)
         (let ((live (kargu-dape--live-buffer-for-truename canonical)))
           (cond
            ((buffer-live-p live)
             (list :path canonical
                   :text (when (kargu-dape--live-buffer-generation-valid-p live ticks)
                           (kargu-dape--buffer-source-text live budget))))
            ((and (stringp disk-text) (<= (string-bytes disk-text) budget))
             (list :path canonical :text disk-text))
            (t (list :path canonical :text nil))))))
      ("error" (error "%s" (or disk-text "Debugger source worker failed")))
      (_ (error "Debugger source reader returned an invalid status")))))

(defun kargu-dape--attach-source-read-owner (operation)
  "Cancel OPERATION immediately when its origin buffer closes or resets."
  (let* ((origin (kargu-dape-source-read-operation-origin operation))
         (task (kargu-dape-source-read-operation-task operation))
         (cancel (lambda (&rest _) (kargu-async-cancel task))))
    (when (buffer-live-p origin)
      (with-current-buffer origin
        (dolist (hook '(kill-buffer-hook change-major-mode-hook
                        kargu-session-before-replace-hook))
          (add-hook hook cancel nil t))))
    (kargu-async-add-cleanup
     task (lambda ()
            (when (buffer-live-p origin)
              (with-current-buffer origin
                (dolist (hook '(kill-buffer-hook change-major-mode-hook
                                kargu-session-before-replace-hook))
                  (remove-hook hook cancel t))))))))

(defun kargu-dape--start-source-worker (operation)
  "Start OPERATION's batch worker unless resolved in memory."
  (let* ((task (kargu-dape-source-read-operation-task operation))
         (file-path (kargu-dape-source-read-operation-path operation))
         (root (kargu-dape-source-read-operation-root operation))
         (budget (kargu-dape-source-read-operation-budget operation))
         (ticks (kargu-dape-source-read-operation-buffer-ticks operation))
         (expanded (and (stringp file-path) (not (string-empty-p file-path))
                        (not (file-remote-p file-path))
                        (expand-file-name file-path root)))
         (within-root (and expanded
                           (or (string= expanded (directory-file-name root))
                               (string-prefix-p root (file-name-as-directory expanded)))))
         (live (and within-root (kargu-dape--live-buffer-for-expanded expanded root))))
    (cond
     ((not within-root)
      (kargu-async-finish task (list :path nil :text nil)))
     ((buffer-live-p live)
      (kargu-async-finish
       task (list :path expanded
                  :text (when (kargu-dape--live-buffer-generation-valid-p live ticks)
                          (kargu-dape--buffer-source-text live budget)))))
     (t
      (let* ((payload (json-serialize
                       (list :mode "dape-source" :file file-path
                             :root root :max-bytes budget)
                       :null-object nil :false-object :json-false))
             (args (list "--batch" "-Q" "-L" kargu-dape--worker-root
                         "-l" "kargu/files/worker"
                         "--eval" "(kargu-file-worker-main)" "--"
                         (base64-encode-string payload t)))
             (process (kargu-process-run
                       (expand-file-name invocation-name invocation-directory) args
                       (kargu-async-wrap
                        task (lambda (result)
                               (kargu-async-finish
                                task (kargu-dape--decode-source-read operation result))))
                       :dir temporary-file-directory
                       :max-bytes (+ (* 4 budget) kargu-dape--worker-reply-overhead))))
        (when (processp process)
          (kargu-async-add-cleanup task (lambda () (kargu-process-cancel process)))))))))

(cl-defun kargu-dape--source-entry-async (file-path callback &key selection buffer-ticks)
  "Resolve FILE-PATH's canonical path and bounded source text asynchronously.
Deliver (:path PATH :text TEXT) once to CALLBACK while ownership remains valid.
Read against SELECTION and BUFFER-TICKS when provided."
  (kargu-contract-assert #'functionp callback)
  (kargu-contract-assert #'natnump kargu-dape--source-budget)
  (save-match-data
    (let* ((origin (if (and kargu-async--current-task
                            (buffer-live-p (kargu-async-task-buffer kargu-async--current-task)))
                       (kargu-async-task-buffer kargu-async--current-task)
                     (current-buffer)))
           (operation
            (kargu-dape--make-source-read
             :path (and (stringp file-path) (copy-sequence file-path))
             :origin origin
             :root (with-current-buffer origin (kargu-permission-project-root))
             :session (with-current-buffer origin (copy-sequence (kargu-session-id)))
             :session-ctx (with-current-buffer origin (kargu-session-context))
             :owner kargu--loop-run
             :budget kargu-dape--source-budget
             :selection selection
             :buffer-ticks (or buffer-ticks (kargu-dape--capture-buffer-ticks))))
           (task (kargu-async-start
                  (lambda (value error)
                    (when (kargu-dape--source-read-valid-p operation)
                      (funcall callback (if error (list :path nil :text nil :error error)
                                          value))))
                  :timeout kargu-dape-request-timeout
                  :valid-p (lambda () (kargu-dape--source-read-valid-p operation)))))
      (setf (kargu-dape-source-read-operation-task operation) task)
      (kargu-dape--attach-source-read-owner operation)
      (funcall (kargu-async-wrap
                task (lambda () (kargu-dape--start-source-worker operation))))
      task)))

(cl-defun kargu-dape--source-text-async (file-path callback &key selection buffer-ticks)
  "Deliver bounded source text for workspace FILE-PATH to CALLBACK, or nil."
  (kargu-dape--source-entry-async
   file-path (lambda (entry) (funcall callback (plist-get entry :text)))
   :selection selection :buffer-ticks buffer-ticks))

(defun kargu-dape--extract-line-from-text (text line)
  "Extract trimmed 1-based LINE from TEXT, or return nil."
  (when (and (stringp text) (integerp line) (> line 0))
    (save-match-data
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (when (and (zerop (forward-line (1- line))) (not (eobp)))
          (string-trim (buffer-substring-no-properties (point) (line-end-position))))))))

(defun kargu-dape--extract-snippet-from-text (text line &optional context-lines)
  "Extract source snippet around 1-based LINE from TEXT with an `=>' marker."
  (let ((ctx (or context-lines 4)))
    (when (and (stringp text) (integerp line) (> line 0) (natnump ctx))
      (save-match-data
        (with-temp-buffer
          (insert text)
          (let* ((start-line (max 1 (- line ctx)))
                 (end-line (+ line ctx))
                 (cur-line start-line)
                 (lines nil))
            (goto-char (point-min))
            (forward-line (1- start-line))
            (while (and (not (eobp)) (<= cur-line end-line))
              (let ((prefix (if (= cur-line line) "=>" "  "))
                    (line-str (buffer-substring-no-properties (point) (line-end-position))))
                (push (format "%s %4d: %s" prefix cur-line line-str) lines))
              (forward-line 1)
              (setq cur-line (1+ cur-line)))
            (when (> cur-line line)
              (string-join (nreverse lines) "\n"))))))))

(cl-defun kargu-dape--source-line-async (file-path line callback &key selection buffer-ticks)
  "Deliver workspace FILE-PATH's trimmed 1-based LINE to CALLBACK, or nil."
  (if (not (and (integerp line) (> line 0)))
      (progn (funcall callback nil) nil)
    (kargu-dape--source-text-async
     file-path
     (lambda (text)
       (funcall callback (kargu-dape--extract-line-from-text text line)))
     :selection selection :buffer-ticks buffer-ticks)))

(cl-defun kargu-dape--source-snippet-async (file-path line callback &key context-lines selection buffer-ticks)
  "Deliver workspace FILE-PATH's snippet around LINE to CALLBACK, or nil."
  (let ((ctx (or context-lines 4)))
    (if (not (and (integerp line) (> line 0) (natnump ctx)))
        (progn (funcall callback nil) nil)
      (kargu-dape--source-text-async
       file-path
       (lambda (text)
         (funcall callback (kargu-dape--extract-snippet-from-text text line ctx)))
       :selection selection :buffer-ticks buffer-ticks))))

(defun kargu-dape--source-text (path)
  "Return bounded complete source text for canonical local PATH, or nil.
Prefer unsaved visiting buffers.  Disk reads bypass transformation handlers
and have a byte bound even if the file grows after its size was checked."
  (let ((buffer (find-buffer-visiting path)))
    (if (buffer-live-p buffer)
        (kargu-dape--buffer-source-text buffer kargu-dape--source-budget)
      (when (and (file-regular-p path)
                 (<= (file-attribute-size (file-attributes path)) kargu-dape--source-budget))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (let ((file-name-handler-alist nil)
                (format-alist nil)
                (after-insert-file-functions nil))
            (insert-file-contents-literally path nil 0 (1+ kargu-dape--source-budget)))
          (when (<= (buffer-size) kargu-dape--source-budget)
            (decode-coding-string (buffer-string)
                                  (detect-coding-region (point-min) (point-max) t))))))))

(defun kargu-dape--source-line (file-path line)
  "Return workspace FILE-PATH's trimmed 1-based LINE, or nil if unavailable."
  (save-match-data
    (when (and (integerp line) (> line 0))
      (when-let* ((path (kargu-dape--project-source-path file-path)))
        (condition-case nil
            (kargu-dape--extract-line-from-text (kargu-dape--source-text path) line)
          (file-error nil))))))

(defun kargu-dape--source-snippet (file-path line &optional context-lines)
  "Return workspace FILE-PATH's source around LINE with an `=>' marker.
CONTEXT-LINES defaults to four surrounding lines.
Unavailable sources return nil."
  (save-match-data
    (let ((ctx (or context-lines 4)))
      (when-let* (((and (integerp line) (> line 0) (natnump ctx)))
                  (path (kargu-dape--project-source-path file-path)))
        (condition-case nil
            (kargu-dape--extract-snippet-from-text
             (kargu-dape--source-text path) line ctx)
          (file-error nil))))))

(defun kargu-dape--breakpoints ()
  "Return workspace-owned Dape source breakpoints as ((PATH LINE) ...)."
  (when (and (boundp 'dape--breakpoints)
             (fboundp 'dape--breakpoint-file-name)
             (fboundp 'dape--breakpoint-line))
    (delq nil
          (mapcar (lambda (bp)
                    (let ((file (kargu-dape--project-source-path
                                 (dape--breakpoint-file-name bp)))
                          (line (dape--breakpoint-line bp)))
                      (when (and file line) (list file line))))
                  dape--breakpoints))))

(defun kargu-dape--raw-breakpoints ()
  "Return raw Dape breakpoint candidates as ((FILE LINE) ...) without disk I/O."
  (when (and (boundp 'dape--breakpoints)
             (fboundp 'dape--breakpoint-file-name)
             (fboundp 'dape--breakpoint-line))
    (delq nil
          (mapcar (lambda (bp)
                    (let ((file (dape--breakpoint-file-name bp))
                          (line (dape--breakpoint-line bp)))
                      (when (and (stringp file) (not (string-empty-p file))
                                 (not (file-remote-p file))
                                 (integerp line) (> line 0))
                        (list file line))))
                  dape--breakpoints))))

(defun kargu-dape--format-breakpoint-entries (resolved)
  "Format RESOLVED ((PATH LINE SRC) ...) breakpoint list."
  (if (null resolved)
      "[ACTIVE BREAKPOINTS: 0]\nNo source breakpoints set."
    (let ((count (length resolved))
          (entries nil))
      (cl-loop for item in resolved
               for i from 1
               do (let ((file (nth 0 item))
                        (line (nth 1 item))
                        (src (nth 2 item)))
                    (push (format "  %d. %s:%d%s"
                                  i file line
                                  (if src (format " -> `%s`" src) ""))
                          entries)))
      (format "[ACTIVE BREAKPOINTS: %d]\n%s"
              count (string-join (nreverse entries) "\n")))))

(defun kargu-dape-list-breakpoints (&optional callback)
  "Return a structured text list of this workspace's source breakpoints.
When CALLBACK is non-nil, resolve paths and source lines asynchronously."
  (cond
   ((null (fboundp 'dape--breakpoint-file-name))
    (kargu-dape--deliver callback "ERROR: dape is not installed or not loaded" nil))
   (callback
    (let ((pending (kargu-dape--raw-breakpoints))
          (ticks (kargu-dape--capture-buffer-ticks))
          (resolved nil))
      (cl-labels
          ((next ()
             (if (null pending)
                 (funcall callback
                          (kargu-dape--format-breakpoint-entries (nreverse resolved)))
               (let* ((bp (pop pending))
                      (file (nth 0 bp))
                      (line (nth 1 bp)))
                 (kargu-dape--source-entry-async
                  file
                  (lambda (entry)
                    (when-let* ((path (plist-get entry :path)))
                      (push (list path line
                                  (kargu-dape--extract-line-from-text
                                   (plist-get entry :text) line))
                            resolved))
                    (next))
                  :buffer-ticks ticks)))))
        (next))))
   (t
    (let ((bps (kargu-dape--breakpoints)))
      (kargu-dape--format-breakpoint-entries
       (mapcar (lambda (bp)
                 (list (nth 0 bp) (nth 1 bp)
                       (kargu-dape--source-line (nth 0 bp) (nth 1 bp))))
               bps))))))

(defun kargu-dape-toggle-breakpoint (file-path line)
  "Toggle a source breakpoint at FILE-PATH:LINE through dape.
Works with or without a live session: dape records the breakpoint
and (re) sends it to the adapter when appropriate."
  (cond
   ((not (fboundp 'dape-breakpoint-toggle))
    "ERROR: dape is not installed or not loaded")
   ((not (and (stringp file-path) (not (string-empty-p file-path))))
    "ERROR: file_path is required")
   ((not (and (natnump line) (> line 0)))
    "ERROR: line must be a positive integer (1-based)")
   (t
    (condition-case-unless-debug err
        (let* ((path (kargu-permission-resolve file-path "dape path"))
               (buffer (find-file-noselect path)))
          (with-current-buffer buffer
            (save-excursion
              (save-restriction
                (widen)
                (goto-char (point-min))
                (forward-line (1- line))
                (dape-breakpoint-toggle)
                (let ((set-p
                       (and (boundp 'dape--breakpoints)
                            (cl-some
                             (lambda (bp)
                               (and (equal (dape--breakpoint-file-name bp)
                                           (expand-file-name path))
                                    (equal (dape--breakpoint-line bp) line)))
                             dape--breakpoints))))
                  (format "Breakpoint %s at %s:%d"
                          (if set-p "SET" "REMOVED")
                          path line))))))
      (error
       (format "ERROR: toggle breakpoint: %s" (error-message-string err)))))))

(defun kargu-dape--breakpoint-at-p (path line)
  "Return non-nil if a breakpoint exists at PATH:LINE."
  (let ((abs (expand-file-name path)))
    (cl-some (lambda (bp)
               (and (equal (expand-file-name (nth 0 bp)) abs)
                    (= (nth 1 bp) line)))
             (kargu-dape--breakpoints))))

(defun kargu-dape-set-breakpoint (file-path line &optional callback)
  "Set a breakpoint at FILE-PATH:LINE if not already set.
Returns structured confirmation with file, line, code snippet, and total count.
When CALLBACK is non-nil, resolves the source line excerpt asynchronously."
  (cond
   ((not (fboundp 'dape-breakpoint-toggle))
    (kargu-dape--deliver callback "ERROR: dape is not installed or not loaded" nil))
   ((not (and (stringp file-path) (not (string-empty-p file-path))))
    (kargu-dape--deliver callback "ERROR: file_path is required" nil))
   ((not (and (natnump line) (> line 0)))
    (kargu-dape--deliver callback "ERROR: line must be a positive integer (1-based)" nil))
   (t
    (let* ((resolved (kargu-permission-resolve file-path "dape path"))
           (abs-path (expand-file-name resolved))
           (already-set (kargu-dape--breakpoint-at-p abs-path line))
           (toggle-msg (unless already-set (kargu-dape-toggle-breakpoint abs-path line)))
           (now-set (or already-set (kargu-dape--breakpoint-at-p abs-path line)))
           (count (length (kargu-dape--breakpoints)))
           (format-result
            (lambda (src)
              (cond
               (already-set
                (format "[BREAKPOINT ALREADY SET]\nFile: %s\nLine: %d\nSource: %s\nStatus: Breakpoint is already active at this location.\nTotal breakpoints: %d"
                        abs-path line (or src "(unavailable)") count))
               (now-set
                (format "[BREAKPOINT SET]\nFile: %s\nLine: %d\nSource: %s\nStatus: Breakpoint registered. Execution will pause when this line is reached.\nTotal active breakpoints: %d"
                        abs-path line (or src "(unavailable)") count))
               (t
                (format "ERROR: toggle breakpoint failed at %s:%d: %s"
                        abs-path line toggle-msg))))))
      (if (not now-set)
          (kargu-dape--deliver callback (funcall format-result nil) nil)
        (if callback
            (kargu-dape--source-line-async
             abs-path line
             (lambda (src) (funcall callback (funcall format-result src))))
          (funcall format-result (kargu-dape--source-line abs-path line))))))))

(defun kargu-dape-clear-breakpoint (file-path line)
  "Remove a breakpoint at FILE-PATH:LINE if set.
Returns structured confirmation with file, line, and remaining count."
  (cond
   ((not (fboundp 'dape-breakpoint-toggle))
    "ERROR: dape is not installed or not loaded")
   ((not (and (stringp file-path) (not (string-empty-p file-path))))
    "ERROR: file_path is required")
   ((not (and (natnump line) (> line 0)))
    "ERROR: line must be a positive integer (1-based)")
   (t
    (let* ((resolved (kargu-permission-resolve file-path "dape path"))
           (abs-path (expand-file-name resolved)))
      (if (not (kargu-dape--breakpoint-at-p abs-path line))
          (format "[BREAKPOINT NOT FOUND]\nNo breakpoint exists at %s:%d to remove.\nActive breakpoints: %d"
                  abs-path line (length (kargu-dape--breakpoints)))
        (kargu-dape-toggle-breakpoint abs-path line)
        (format "[BREAKPOINT REMOVED]\nFile: %s\nLine: %d\nRemaining active breakpoints: %d"
                abs-path line (length (kargu-dape--breakpoints))))))))

(defun kargu-dape--validate-bp-args (args tool-name)
  "Validate ARGS for breakpoint TOOL-NAME, returning an error string or nil."
  (let ((path (kargu--tool-file-path args))
        (line (kargu--tool-arg args "line")))
    (cond
     ((and (not (kargu-nonempty path)) (null line))
      (format "ERROR: %s requires 'file_path' (string) and 'line' (1-based positive integer).\nExample: {\"file_path\": \"src/main.rs\", \"line\": 42}\nGot keys: %s"
              tool-name (kargu--tool-arg-keys args)))
     ((not (kargu-nonempty path))
      (format "ERROR: %s requires 'file_path'. Example: {\"file_path\": \"src/main.rs\", \"line\": %s}"
              tool-name (or line 42)))
     ((or (null line) (not (and (integerp line) (> line 0))))
      (format "ERROR: %s requires 1-based positive integer 'line'. Example: {\"file_path\": \"%s\", \"line\": 42}"
              tool-name path))
     (t nil))))

(defun kargu-dape-get-context (&optional callback connection selection)
  "Collect paused context and complete CALLBACK once, optionally on CONNECTION.
An explicit CONNECTION must still be paused and owned by the current project.
SELECTION optionally supplies a previously captured thread/frame identity."
  (interactive)
  (kargu-dape--run-chain
   callback (lambda (done selected) (kargu-dape--collect-selection-context selected done nil))
   :connection connection :selection selection))

(cl-defun kargu-dape-eval-expression (expr &optional context callback &key selection)
  "Evaluate EXPR in CONTEXT and deliver one guarded result to CALLBACK.
SELECTION optionally reuses an admitted inspection's prepared frame."
  (let ((conn (if selection (kargu-dape-selection-connection selection) (kargu-dape--connection))))
    (if (stringp conn)
        (kargu-dape--deliver callback (concat conn (kargu-dape--format-language-hint expr conn)) nil)
      (kargu-dape--run-chain callback
                             (lambda (done selected)
                               (kargu-dape--eval-expression expr selected done :context context))
                             :selection selection))))

(provide 'kargu/tools/dape/context)

;;; context.el ends here
