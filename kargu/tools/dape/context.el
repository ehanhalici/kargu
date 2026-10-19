;;; context.el --- Debug context, evaluation and breakpoints -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Fetch paused runtime data and manage source breakpoints.

;;; Code:

(require 'kargu/tools/dape/render)
(require 'kargu/async)
(require 'kargu/tools/dape/events)
(require 'kargu/tools/dape/selection)

(declare-function kargu--tool-arg "kargu/api/tools" (args &rest keys))
(declare-function kargu--tool-file-path "kargu/api/tools" (args))
(declare-function kargu--tool-arg-keys "kargu/api/tools" (args))
(declare-function kargu-session-id "kargu/core/session" ())

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
                          (kargu-dape--seq->list (plist-get thread :stackFrames))))
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
         (frames (kargu-dape--seq->list (plist-get thread :stackFrames)))
         (frame (kargu-dape-selection-frame selection)))
    (when (and (kargu-dape-selection-frame-id selection) (null frame))
      (error "Requested debug frame is absent from the captured thread's stack"))
    (if (null frame)
        (kargu-dape--deliver callback (kargu-dape--context-text conn thread frames nil) interactive)
      (kargu-dape--call
       #'dape--scopes conn frame
       (lambda (&rest _)
         (kargu-dape--fetch-variables
          conn (kargu-dape--seq->list (plist-get frame :scopes))
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

(defun kargu-dape--source-text (path)
  "Return bounded complete source text for canonical local PATH, or nil.
Prefer unsaved visiting buffers.  Disk reads bypass transformation handlers
and have a byte bound even if the file grows after its size was checked."
  (let ((buffer (find-buffer-visiting path)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (when (<= (buffer-size) kargu-dape--source-budget)
              (buffer-substring-no-properties (point-min) (point-max)))))
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
            (when-let* ((text (kargu-dape--source-text path)))
              (with-temp-buffer
                (insert text)
                (goto-char (point-min))
                (when (and (zerop (forward-line (1- line))) (not (eobp)))
                  (string-trim (buffer-substring-no-properties (point) (line-end-position))))))
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
            (when-let* ((text (kargu-dape--source-text path)))
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
                    (string-join (nreverse lines) "\n")))))
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

(defun kargu-dape-list-breakpoints ()
  "Return a structured text list of this workspace's source breakpoints."
  (let ((bps (kargu-dape--breakpoints)))
    (cond
     ((null (fboundp 'dape--breakpoint-file-name))
      "ERROR: dape is not installed or not loaded")
     ((null bps) "[ACTIVE BREAKPOINTS: 0]\nNo source breakpoints set.")
     (t
      (let ((count (length bps))
            (entries nil))
        (cl-loop for bp in bps
                 for i from 1
                 do (let* ((file (nth 0 bp))
                           (line (nth 1 bp))
                           (src (kargu-dape--source-line file line)))
                      (push (format "  %d. %s:%d%s"
                                    i file line
                                    (if src (format " -> `%s`" src) ""))
                            entries)))
        (format "[ACTIVE BREAKPOINTS: %d]\n%s"
                count (string-join (nreverse entries) "\n")))))))

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

(defun kargu-dape-set-breakpoint (file-path line)
  "Set a breakpoint at FILE-PATH:LINE if not already set.
Returns structured confirmation with file, line, code snippet, and total count."
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
      (if (kargu-dape--breakpoint-at-p abs-path line)
          (let ((src (kargu-dape--source-line abs-path line)))
            (format "[BREAKPOINT ALREADY SET]\nFile: %s\nLine: %d\nSource: %s\nStatus: Breakpoint is already active at this location.\nTotal breakpoints: %d"
                    abs-path line (or src "(unavailable)") (length (kargu-dape--breakpoints))))
        (let ((toggle-msg (kargu-dape-toggle-breakpoint abs-path line))
              (src (kargu-dape--source-line abs-path line))
              (bps (kargu-dape--breakpoints)))
          (if (kargu-dape--breakpoint-at-p abs-path line)
              (format "[BREAKPOINT SET]\nFile: %s\nLine: %d\nSource: %s\nStatus: Breakpoint registered. Execution will pause when this line is reached.\nTotal active breakpoints: %d"
                      abs-path line (or src "(unavailable)") (length bps))
            (format "ERROR: toggle breakpoint failed at %s:%d: %s" abs-path line toggle-msg))))))))

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
