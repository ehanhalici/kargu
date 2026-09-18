;;; kargu/tools/dape.el --- dape stack, variables, eval -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Live dape stack, variables, eval, and breakpoints.
;; Requires: `kargu/core', `kargu/api', `kargu/tools/lsp' (dape optional).
;; Public: `kargu-dape-get-context', `kargu-dape-eval-expression',
;; `kargu-dape-list-breakpoints'.
;;
;; The debugger tool layer: lets the model read the live runtime
;; state of a paused dape (Debug Adapter Protocol) session instead of
;; guessing.
;;
;;  * `debug_get_context' — the paused thread's call-stack (frame
;;    name, file, line) plus every in-scope variable (name, value) of
;;    the selected frame.
;;  * `debug_eval' — evaluate an expression in the paused frame and
;;    return its value.
;;  * `debug_list_breakpoints' / `debug_toggle_breakpoint' —
;;    breakpoint management routed through dape's own state.
;;
;; dape internals used (verified against the dape sources):
;;   * `dape--live-connection' (types `stopped' / `last'),
;;     `dape--live-connections', `dape-active-mode' for liveness;
;;   * `dape--threads', `dape--current-thread',
;;     `dape--current-stack-frame', `dape--stopped-threads';
;;   * the request pipeline `dape--stack-trace' / `dape--scopes' /
;;     `dape--variables' / `dape--evaluate-expression', each taking a
;;     callback; every call below runs under
;;     `dape--request-blocking' so dape turns its jsonrpc request
;;     into a bounded synchronous one (jsonrpc pumps process output
;;     while waiting, and `dape-request-timeout' bounds the wait);
;;   * `dape--breakpoints' with `dape--breakpoint-file-name' /
;;     `dape--breakpoint-line' accessors and the point-based
;;     `dape-breakpoint-toggle' command.
;;
;; All dape structures are plists (dape decodes over jsonrpc.el).
;; The module soft-requires dape: tools are registered even when
;; dape is absent, and fail with a helpful string instead.

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
(require 'kargu/api)
(require 'kargu/languages)
(require 'kargu/tools/lsp)         ; for kargu--resolve-path
(require 'dape nil t)

(defvar dape--request-blocking)
(defvar dape--watched)

(declare-function dape "dape" (&optional config-diff))
(declare-function dape-stack-select-up "dape" (conn n))
(declare-function dape-stack-select-down "dape" (conn n))
(declare-function dape-select-stack "dape" (conn stack-id))
(declare-function dape-select-thread "dape" (conn thread-id))
(declare-function dape-watch-dwim "dape" (expression &optional remove-only-p add-only-p display-p))
(declare-function dape-kill "dape" (conn &optional cb with-disconnect))
(declare-function dape-disconnect-quit "dape" (conn))
(declare-function dape-quit "dape" ())

;;;; Customization --------------------------------------------------------

(defgroup kargu-dape nil
  "dape integration of kargu."
  :group 'kargu
  :prefix "kargu-dape-")

(defcustom kargu-dape-max-frames 12
  "Stack frames reported by `kargu-dape-get-context'."
  :type 'natnum
  :group 'kargu-dape)

(defcustom kargu-dape-max-scopes 4
  "Scopes (Locals, Arguments, Registers, ...) reported per frame."
  :type 'natnum
  :group 'kargu-dape)

(defcustom kargu-dape-max-variables 60
  "Variables reported per scope."
  :type 'natnum
  :group 'kargu-dape)

(defcustom kargu-dape-variable-value-width 160
  "Maximum characters of one variable value fed to the model."
  :type 'natnum
  :group 'kargu-dape)

;;;; Session access --------------------------------------------------------

(defun kargu-dape--seq->list (seq)
  "Normalize a JSON array (vector, list or single value) to a list."
  (cond
   ((vectorp seq) (append seq nil))
   ((listp seq) seq)
   (seq (list seq))
   (t nil)))

(defun kargu-dape--target-buffer ()
  "Return the best source/code buffer for launching dape.
Prefers `kargu-context-buffer' if valid and live, or a buffer in another
visible window visiting a file, or any project file buffer."
  (or (and (boundp 'kargu-context-buffer)
           (bufferp kargu-context-buffer)
           (buffer-live-p kargu-context-buffer)
           (not (with-current-buffer kargu-context-buffer (derived-mode-p 'kargu-chat-mode)))
           kargu-context-buffer)
      (and (boundp 'kargu-context-buffer)
           (stringp kargu-context-buffer)
           (get-file-buffer kargu-context-buffer))
      ;; Check visible windows in the current frame
      (cl-some (lambda (w)
                 (let ((b (window-buffer w)))
                   (and (buffer-live-p b)
                        (with-current-buffer b
                          (and (buffer-file-name b)
                               (derived-mode-p 'prog-mode)
                               (not (derived-mode-p 'kargu-chat-mode))))
                        b)))
               (window-list))
      ;; Check any buffer visiting a project file
      (cl-find-if (lambda (b)
                    (and (buffer-live-p b)
                         (buffer-file-name b)
                         (with-current-buffer b
                           (and (derived-mode-p 'prog-mode)
                                (not (derived-mode-p 'kargu-chat-mode))))))
                  (buffer-list))
      (current-buffer)))

(defun kargu-dape--ensure-stop-on-entry (config)
  "Ensure CONFIG has :stopOnEntry t so program pauses on startup."
  (let ((copy (copy-sequence config)))
    (if (plist-member copy :stopOnEntry)
        (plist-put copy :stopOnEntry t)
      (append copy '(:stopOnEntry t)))))

(defun kargu-dape--raw-connection ()
  "Return the live dape connection object, or nil."
  (when (fboundp 'dape--live-connections)
    (let ((conns (ignore-errors (dape--live-connections))))
      (when conns
        (or (and (fboundp 'dape--live-connection)
                 (or (ignore-errors (dape--live-connection 'stopped t))
                     (ignore-errors (dape--live-connection 'last t))))
            (car conns))))))

(defun kargu-dape-live-p ()
  "Return non-nil if a live dape session exists."
  (let ((conn (kargu-dape--raw-connection)))
    (and conn (not (stringp conn)))))

(defun kargu-dape-ready-p ()
  "Return non-nil if a dape session is active and ready for debugging.
Returns t when a thread is stopped or when the session is live and active."
  (let ((conn (kargu-dape--raw-connection)))
    (and conn
         (not (stringp conn))
         (or (and (fboundp 'dape--stopped-threads)
                  (ignore-errors (dape--stopped-threads conn)))
             (bound-and-true-p dape-active-mode)))))

(defun kargu-dape-ensure-session (on-ready &optional on-cancel)
  "Ensure a dape debug session is running and ready.
If already ready, calls ON-READY immediately.
Otherwise, interactively invokes `dape' in the context of the project
source buffer (so minibuffer completion works), ensures :stopOnEntry t,
and waits asynchronously until the session connects and stops.
If cancelled or start fails within timeout, calls ON-CANCEL."
  (cond
   ((kargu-dape-ready-p)
    (funcall on-ready))
   ((not (fboundp 'dape))
    (message "kargu: dape is not installed or loaded")
    (when on-cancel (funcall on-cancel "dape is not installed")))
   (t
    (condition-case err
        (let* ((target-buf (kargu-dape--target-buffer))
               (orig-config-fns (and (boundp 'dape-default-config-functions)
                                     dape-default-config-functions)))
          (when (and target-buf (buffer-live-p target-buf))
            (setq kargu-context-buffer target-buf))
          (message "kargu: launching dape in %s; please enter configuration in the minibuffer..."
                   (buffer-name target-buf))
          ;; Temporarily ensure :stopOnEntry so the program does not run away before AI can inspect
          (when (boundp 'dape-default-config-functions)
            (add-to-list 'dape-default-config-functions #'kargu-dape--ensure-stop-on-entry))
          (unwind-protect
              (with-current-buffer target-buf
                (call-interactively #'dape))
            (when (boundp 'dape-default-config-functions)
              (setq dape-default-config-functions orig-config-fns)))
          ;; Wait asynchronously for readiness
          (let* ((start-time (float-time))
                 (timer nil)
                 (hook-stop nil)
                 (hook-start nil)
                 (cleanup-fn nil)
                 (triggered nil))
            (setq cleanup-fn
                  (lambda ()
                    (when timer (cancel-timer timer))
                    (when (boundp 'dape-stopped-hook)
                      (remove-hook 'dape-stopped-hook hook-stop))
                    (when (boundp 'dape-start-hook)
                      (remove-hook 'dape-start-hook hook-start))))
            (setq hook-stop
                  (lambda (&rest _)
                    (unless triggered
                      (setq triggered t)
                      (funcall cleanup-fn)
                      (message "kargu: debug session ready (paused)!")
                      (funcall on-ready))))
            (setq hook-start
                  (lambda (&rest _)
                    ;; When session starts, wait briefly for initial stop (stopOnEntry)
                    ;; or trigger if ready
                    (run-at-time
                     0.5 nil
                     (lambda ()
                       (unless triggered
                         (when (or (kargu-dape-ready-p) (kargu-dape-live-p))
                           (setq triggered t)
                           (funcall cleanup-fn)
                           (message "kargu: debug session ready!")
                           (funcall on-ready)))))))
            ;; NOTE: hooks must be GLOBAL (nil for local arg), because dape fires hooks globally!
            (when (boundp 'dape-stopped-hook)
              (add-hook 'dape-stopped-hook hook-stop))
            (when (boundp 'dape-start-hook)
              (add-hook 'dape-start-hook hook-start))
            (setq timer
                  (run-with-timer
                   0.5 0.5
                   (lambda ()
                     (cond
                      ((kargu-dape-ready-p)
                       (unless triggered
                         (setq triggered t)
                         (funcall cleanup-fn)
                         (message "kargu: debug session ready!")
                         (funcall on-ready)))
                      ((> (- (float-time) start-time) 60.0)
                       (unless triggered
                         (setq triggered t)
                         (funcall cleanup-fn)
                         (message "kargu: debug session timed out waiting for adapter.")
                         (when on-cancel (funcall on-cancel "dape launch timed out"))))))))))
      (quit
       (message "kargu: debug session launch cancelled.")
       (when on-cancel (funcall on-cancel "cancelled by user")))
      (error
       (message "kargu: dape launch error: %s" (error-message-string err))
       (when on-cancel (funcall on-cancel (error-message-string err))))))))

(defun kargu-dape--connection ()
  "Return a live dape connection, or an explanatory string.
A connection with a stopped (paused) thread is preferred; when the
session is running, the string tells the model how to proceed."
  (cond
   ((not (fboundp 'dape--live-connection))
    "ERROR: dape is not installed or not loaded (install dape, then \
start a session with M-x dape)")
   ((not (or (bound-and-true-p dape-active-mode)
             (and (fboundp 'dape--live-connections)
                  (dape--live-connections))))
    "ERROR: no live dape session — start one with M-x dape (or \
dape-attach) first")
   (t
    (let ((conn (or (dape--live-connection 'stopped t)
                    (dape--live-connection 'last t))))
      (cond
       ((null conn)
        "ERROR: no live dape connection found")
       ((null (dape--stopped-threads conn))
        (format "The debug session is RUNNING; there is no paused thread \
to inspect. Set a breakpoint with debug_toggle_breakpoint and let the \
program reach it (or pause it), then call debug_get_context again. \
Threads: %s"
                (mapconcat
                 (lambda (thread)
                   (format "#%s (%s)"
                           (or (plist-get thread :id) "?")
                           (or (plist-get thread :status) "?")))
                 (kargu-dape--seq->list (dape--threads conn))
                 ", ")))
       (t conn))))))

;;;; Rendering helpers -----------------------------------------------------

(defun kargu-dape--trunc (string)
  "Truncate a variable value STRING for the model."
  (let ((one-line (replace-regexp-in-string
                   "\n" "\\\\n" (or string ""))))
    (truncate-string-to-width one-line
                              kargu-dape-variable-value-width)))

(defun kargu-dape--frame-path (conn frame)
  "Local file path of FRAME, translated through dape's config."
  (let ((path (plist-get (plist-get frame :source) :path)))
    (cond
     ((null path) "?")
     ((fboundp 'dape--file-name-local) (dape--file-name-local conn path))
     (t path))))

;;;; Context (stack + scopes + variables) ----------------------------------

(defun kargu-dape-get-context ()
  "Return a text snapshot of the paused debug session:
thread status, the call-stack (function, file, line) and all
in-scope variables of the selected frame.  Data is fetched with
synchronous (blocking, timeout-bounded) DAP requests."
  (interactive)
  (let ((conn (kargu-dape--connection)))
    (if (stringp conn)
        (progn
          (when (called-interactively-p 'any) (message "%s" conn))
          conn)
      (condition-case-unless-debug err
          (let (thread frames frame)
            ;; Fetch everything under dape's blocking mode; callbacks
            ;; fire synchronously before each call returns.
            (let ((dape--request-blocking t))
              (setq thread (or (dape--current-thread conn)
                               (car (dape--stopped-threads conn))))
              (when thread
                (dape--stack-trace conn thread kargu-dape-max-frames
                                   (lambda (&rest _)))
                (setq frames (kargu-dape--seq->list
                              (plist-get thread :stackFrames)))
                (setq frame (or (dape--current-stack-frame conn)
                                (car frames)))
                (when frame
                  (dape--scopes conn frame (lambda (&rest _)))
                  (dolist (scope (kargu-dape--seq->list
                                  (plist-get frame :scopes)))
                    (unless (eq (plist-get scope :expensive) t)
                      (dape--variables conn scope (lambda (&rest _))))))))
            (let ((text (kargu-dape--render-context
                         conn thread frames frame)))
              (kargu-log 'info "dape context: %d frames, thread #%s"
                               (length (or frames nil))
                               (and thread (plist-get thread :id)))
              (when (called-interactively-p 'any)
                (message "%s" (truncate-string-to-width text 200)))
              text))
        (error
         (let ((msg (format "ERROR: dape context: %s"
                            (error-message-string err))))
           (kargu-log 'warn "%s" msg)
           msg))))))

(defun kargu-dape--render-context (conn thread frames frame)
  "Render the session snapshot for THREAD/FRAMES/FRAME as text."
  (let ((lines
         (list
          (format "# dape session — thread #%s (%s), %d frame(s)"
                  (or (and thread (plist-get thread :id)) "?")
                  (or (and thread (plist-get thread :status)) "?")
                  (length (or frames nil))))))
    (push "## Stack" lines)
    (if (null frames)
        (push "  (no stack frames available)" lines)
      (let ((selected-id (and frame (plist-get frame :id))))
        (cl-loop for f in (seq-take frames kargu-dape-max-frames)
                 for i from 0
                 do (push (format "  #%d %s  (%s:%s)%s"
                                  i
                                  (or (plist-get f :name) "?")
                                  (kargu-dape--frame-path conn f)
                                  (or (plist-get f :line) "?")
                                  (if (eq (plist-get f :id) selected-id)
                                      "  <= selected"
                                    ""))
                          lines)))
      (let ((hidden (- (length frames) kargu-dape-max-frames)))
        (when (> hidden 0)
          (push (format "  ... %d more frames" hidden) lines))))
    (when frame
      (push (format "## Variables in frame \"%s\" (%s:%s)"
                    (or (plist-get frame :name) "?")
                    (kargu-dape--frame-path conn frame)
                    (or (plist-get frame :line) "?"))
            lines)
      (let ((scopes (seq-take
                     (kargu-dape--seq->list
                      (plist-get frame :scopes))
                     kargu-dape-max-scopes)))
        (if (null scopes)
            (push "  (no scopes reported by the adapter)" lines)
          (dolist (scope scopes)
            (let ((variables
                   (kargu-dape--seq->list
                    (plist-get scope :variables))))
              (push (format "  Scope %s:" (or (plist-get scope :name) "?"))
                    lines)
              (if (null variables)
                  (push "    (empty)" lines)
                (dolist (variable
                         (seq-take variables kargu-dape-max-variables))
                  (push (format "    %s = %s%s"
                                (or (plist-get variable :name) "?")
                                (kargu-dape--trunc
                                 (or (plist-get variable :value) "?"))
                                (if (and (numberp
                                          (plist-get variable
                                                     :variablesReference))
                                         (not (zerop
                                               (plist-get variable
                                                          :variablesReference))))
                                    " {...}"
                                  ""))
                        lines)))
              (let ((hidden (- (length variables)
                               kargu-dape-max-variables)))
                (when (> hidden 0)
                  (push (format "    ... %d more variables" hidden)
                        lines)))))
          (let ((hidden (- (length (kargu-dape--seq->list
                                    (plist-get frame :scopes)))
                           kargu-dape-max-scopes)))
            (when (> hidden 0)
              (push (format "  ... %d more scopes" hidden) lines))))))
    (string-join (nreverse lines) "\n")))

;;;; Expression evaluation -------------------------------------------------

(defun kargu-dape-eval-expression (expr &optional context)
  "Evaluate EXPR in the paused debug session; return result text.
CONTEXT is the DAP evaluate context (\"repl\" default, \"hover\"
or \"watch\")."
  (let ((conn (kargu-dape--connection)))
    (if (stringp conn)
        (let* ((active-lang (and (fboundp 'kargu-language-active)
                                 (kargu-language-active)))
               (hint (and active-lang (kargu-language-eval-hint active-lang expr conn))))
          (if hint
              (format "%s\n💡 Language Hint (%s): %s" conn (kargu-language-spec-name active-lang) hint)
            conn))
      (condition-case-unless-debug err
          (let (body err-msg)
            (let ((dape--request-blocking t))
              (dape--evaluate-expression
               conn
               (plist-get (dape--current-stack-frame conn) :id)
               expr
               (or context "repl")
               (lambda (result error)
                 (setq body result
                       err-msg error))))
            (cond
             (err-msg
              (let* ((active-lang (and (fboundp 'kargu-language-active)
                                       (kargu-language-active)))
                     (hint (and active-lang (kargu-language-eval-hint active-lang expr err-msg))))
                (format "ERROR: evaluate '%s' failed: %s%s"
                        expr err-msg
                        (if hint
                            (format "\n💡 Language Hint (%s): %s"
                                    (kargu-language-spec-name active-lang) hint)
                          ""))))
             ((and body (plist-get body :result))
              (format "%s => %s" expr (kargu-dape--trunc (plist-get body :result))))
             (t (format "%s => (evaluated, no result value)" expr))))
        (error
         (let* ((active-lang (and (fboundp 'kargu-language-active)
                                  (kargu-language-active)))
                (hint (and active-lang (kargu-language-eval-hint active-lang expr (error-message-string err)))))
           (format "ERROR: dape eval '%s': %s%s"
                   expr (error-message-string err)
                   (if hint
                       (format "\n💡 Language Hint (%s): %s"
                               (kargu-language-spec-name active-lang) hint)
                     ""))))))))

;;;; Breakpoints -----------------------------------------------------------

(defun kargu-dape--source-line (file-path line)
  "Return trimmed source line content of FILE-PATH at 1-based LINE, or nil."
  (when (and (stringp file-path) (file-readable-p file-path) (integerp line) (> line 0))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file-path)
          (goto-char (point-min))
          (forward-line (1- line))
          (string-trim (buffer-substring-no-properties (point) (line-end-position))))
      (error nil))))

(defun kargu-dape--source-snippet (file-path line &optional context-lines)
  "Return formatted source lines around LINE in FILE-PATH with `=>' marker."
  (let ((ctx (or context-lines 4)))
    (when (and (stringp file-path) (file-readable-p file-path) (integerp line) (> line 0))
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file-path)
            (let* ((start-line (max 1 (- line ctx)))
                   (end-line (+ line ctx))
                   (cur-line 1)
                   (lines nil))
              (goto-char (point-min))
              (while (and (not (eobp)) (<= cur-line end-line))
                (when (>= cur-line start-line)
                  (let ((prefix (if (= cur-line line) "=>" "  "))
                        (line-str (buffer-substring-no-properties
                                   (point) (line-end-position))))
                    (push (format "%s %4d: %s" prefix cur-line line-str) lines)))
                (forward-line 1)
                (setq cur-line (1+ cur-line)))
              (when lines
                (string-join (nreverse lines) "\n"))))
        (error nil)))))

(defun kargu-dape--breakpoints ()
  "Return dape source breakpoints as ((PATH LINE) ...)."
  (when (and (boundp 'dape--breakpoints)
             (fboundp 'dape--breakpoint-file-name)
             (fboundp 'dape--breakpoint-line))
    (delq nil
          (mapcar (lambda (bp)
                    (let ((file (dape--breakpoint-file-name bp))
                          (line (dape--breakpoint-line bp)))
                      (when (and file line) (list file line))))
                  dape--breakpoints))))

(defun kargu-dape-list-breakpoints ()
  "Return a structured text list of all source breakpoints."
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

(defun kargu-dape--resolve (path)
  "Resolve PATH with the shared resolver when available."
  (if (fboundp 'kargu--resolve-path)
      (kargu--resolve-path path)
    (expand-file-name path)))

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
       (let* ((path (kargu-dape--resolve file-path))
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
    (let* ((resolved (kargu-dape--resolve file-path))
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
    (let* ((resolved (kargu-dape--resolve file-path))
           (abs-path (expand-file-name resolved)))
      (if (not (kargu-dape--breakpoint-at-p abs-path line))
          (format "[BREAKPOINT NOT FOUND]\nNo breakpoint exists at %s:%d to remove.\nActive breakpoints: %d"
                  abs-path line (length (kargu-dape--breakpoints)))
        (kargu-dape-toggle-breakpoint abs-path line)
        (format "[BREAKPOINT REMOVED]\nFile: %s\nLine: %d\nRemaining active breakpoints: %d"
                abs-path line (length (kargu-dape--breakpoints))))))))

;;;; Stepping & execution control ------------------------------------------

(defun kargu-dape--action-and-wait (action-fn action-name &optional callback timeout)
  "Execute ACTION-FN on connection and wait for stopped state.
If CALLBACK is provided, operates asynchronously.
Otherwise, blocks with `accept-process-output' until stopped or TIMEOUT.
Returns a rich structured debugging report containing:
- Execution status & action name
- Source code context snippet around paused line (with `=>')
- Full call stack frames
- In-scope variables (locals, arguments, globals)
- Next available actions guidance."
  (let ((conn (kargu-dape--connection)))
    (if (stringp conn)
        (if callback (funcall callback conn) conn)
      (let* ((timeout (or timeout 10.0))
             (done nil)
             (result nil)
             (timer nil)
             (hook-stop nil)
             (hook-exit nil)
             (cleanup nil)
             (format-stopped-report
              (lambda ()
                (let* ((ctx (kargu-dape-get-context))
                       (live-conn (kargu-dape--raw-connection))
                       (thread (and live-conn (or (dape--current-thread live-conn)
                                                  (car (dape--stopped-threads live-conn)))))
                       (top-frame (and live-conn (or (dape--current-stack-frame live-conn)
                                                     (car (plist-get thread :stackFrames)))))
                       (file (and live-conn top-frame (kargu-dape--frame-path live-conn top-frame)))
                       (line (and top-frame (plist-get top-frame :line)))
                       (fn-name (and top-frame (plist-get top-frame :name)))
                       (src-snippet (when (and file (not (equal file "?")) (numberp line))
                                      (kargu-dape--source-snippet file line 4))))
                  (concat
                   (format "[DEBUGGER PAUSED: Action '%s' completed]\n" action-name)
                   (format "Location: %s:%s%s\n"
                           (or file "?") (or line "?")
                           (if fn-name (format " in `%s`" fn-name) ""))
                   (if src-snippet
                       (format "\n### Source Context (%s:%s):\n```\n%s\n```\n\n"
                               file line src-snippet)
                     "\n")
                   ctx
                   "\n\nAvailable Next Actions:\n"
                   "  - Inspect Variables: Review in-scope variables above. For struct/vector fields, use `debug_scope` (or `debug_inspect_variable`).\n"
                   "  - Custom Evaluation: Use `debug_eval` (Note: for Rust/C++, do not invoke runtime methods like .len(); inspect fields directly).\n"
                   "  - Stack Navigation: `debug_up` (caller), `debug_down` (callee), `debug_stack` (all frames), `debug_threads`.\n"
                   "  - Step & Continue: `debug_step_over` (next), `debug_step_in` (step), `debug_step_out` (out), or `debug_continue`.\n"
                   "  - Breakpoints: `debug_set_breakpoint`, `debug_clear_breakpoint`, `debug_list_breakpoints`.\n"
                   "  - Lifecycle: `debug_watch`, `debug_restart`, `debug_kill`, `debug_disconnect`, `debug_quit`.")))))
        (setq cleanup
              (lambda ()
                (when timer (cancel-timer timer))
                (when (boundp 'dape-stopped-hook)
                  (remove-hook 'dape-stopped-hook hook-stop))
                (when (boundp 'dape-active-mode-off-hook)
                  (remove-hook 'dape-active-mode-off-hook hook-exit))))
        (setq hook-stop
              (lambda (&rest _)
                (unless done
                  (setq done t)
                  (funcall cleanup)
                  (let ((msg (funcall format-stopped-report)))
                    (setq result msg)
                    (when callback (funcall callback msg))))))
        (setq hook-exit
              (lambda (&rest _)
                (unless done
                  (setq done t)
                  (funcall cleanup)
                  (let ((msg (format "[DEBUGGER PROGRAM EXITED]\nAction '%s' completed: program finished execution / session terminated." action-name)))
                    (setq result msg)
                    (when callback (funcall callback msg))))))
        ;; Global hooks
        (when (boundp 'dape-stopped-hook)
          (add-hook 'dape-stopped-hook hook-stop))
        (when (boundp 'dape-active-mode-off-hook)
          (add-hook 'dape-active-mode-off-hook hook-exit))
        (condition-case err
            (funcall action-fn conn)
          (error
           (funcall cleanup)
           (let ((err-msg (format "ERROR during %s: %s" action-name (error-message-string err))))
             (if callback (funcall callback err-msg) err-msg))))
        (if callback
            (setq timer
                  (run-at-time
                   timeout nil
                   (lambda ()
                     (unless done
                       (setq done t)
                       (funcall cleanup)
                       (funcall callback
                                (format "[DEBUGGER STILL RUNNING]\nAction '%s' initiated, but program did not pause within %ds timeout (still running or waiting for input).\nUse `debug_pause` to pause execution."
                                        action-name (round timeout)))))))
          ;; Synchronous wait
          (let ((start (float-time)))
            (while (and (not done) (< (- (float-time) start) timeout))
              (accept-process-output nil 0.05))
            (unless done
              (funcall cleanup)
              (setq result
                    (format "[DEBUGGER STILL RUNNING]\nAction '%s' initiated, but program did not pause within %ds timeout.\nUse `debug_pause` to pause execution."
                            action-name (round timeout)))))
          result)))))

(defun kargu-dape-step-over (&optional callback)
  "Step to the next line in the current frame (skip calls)."
  (interactive)
  (kargu-dape--action-and-wait #'dape-next "step_over" callback 10.0))

(defun kargu-dape-step-in (&optional callback)
  "Step into the function call at the current line."
  (interactive)
  (kargu-dape--action-and-wait #'dape-step-in "step_in" callback 10.0))

(defun kargu-dape-step-out (&optional callback)
  "Step out of the current function back to its caller."
  (interactive)
  (kargu-dape--action-and-wait #'dape-step-out "step_out" callback 10.0))

(defun kargu-dape-continue (&optional callback)
  "Resume program execution until the next breakpoint or termination."
  (interactive)
  (kargu-dape--action-and-wait #'dape-continue "continue" callback 30.0))

(defun kargu-dape-pause (&optional callback)
  "Pause a currently running debuggee and wait for paused state snapshot."
  (interactive)
  (kargu-dape--action-and-wait #'dape-pause "pause" callback 10.0))

(defun kargu-dape-restart ()
  "Restart the active debugging session."
  (interactive)
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "ERROR: no live dape session to restart"
      (condition-case err
          (progn
            (dape-restart conn)
            "Restart signal sent to debug session.")
        (error (format "ERROR: restart failed: %s" (error-message-string err)))))))

(defun kargu-dape--validate-bp-args (args tool-name)
  "Validate ARGS for breakpoint TOOL-NAME, returning an error string or nil."
  (let ((path (kargu--tool-file-path args))
        (line (kargu--tool-arg args "line")))
    (cond
     ((and (not (kargu--nonempty path)) (null line))
      (format "ERROR: %s requires 'file_path' (string) and 'line' (1-based positive integer).\nExample: {\"file_path\": \"src/main.rs\", \"line\": 42}\nGot keys: %s"
              tool-name (kargu--tool-arg-keys args)))
     ((not (kargu--nonempty path))
      (format "ERROR: %s requires 'file_path'. Example: {\"file_path\": \"src/main.rs\", \"line\": %s}"
              tool-name (or line 42)))
     ((or (null line) (not (and (integerp line) (> line 0))))
      (format "ERROR: %s requires 1-based positive integer 'line'. Example: {\"file_path\": \"%s\", \"line\": 42}"
              tool-name path))
     (t nil))))

(defun kargu-dape-start (&optional config-name)
  "Start or attach a Dape debugging session with CONFIG-NAME."
  (condition-case err
      (if (not (fboundp 'dape))
          "ERROR: dape is not installed or loaded"
        (if (kargu-dape-live-p)
            "Debug session is already running. Use `debug_restart` to restart or `debug_pause` to pause."
          (let* ((spec (and (fboundp 'kargu-language-active) (kargu-language-active)))
                 (dbg (and spec (kargu-language-spec-debugger spec)))
                 (detected-adapter (and dbg (plist-get dbg :adapter)))
                 (chosen (or (and config-name (not (string-empty-p config-name)) (intern config-name))
                             detected-adapter)))
            (if chosen
                (progn
                  (dape chosen)
                  (format "Debug session started with configuration '%s'." chosen))
              (with-current-buffer (kargu-dape--target-buffer)
                (call-interactively #'dape))
              "Debug session launched."))))
    (error (format "ERROR: debug start failed: %s" (error-message-string err)))))

(defun kargu-dape-up (&optional count)
  "Select COUNT (default 1) stack frames up towards caller.
Returns the newly selected frame info and location."
  (let ((conn (kargu-dape--raw-connection))
        (n (or count 1)))
    (if (null conn)
        "ERROR: no live dape session"
      (condition-case err
          (progn
            (if (fboundp 'dape-stack-select-up)
                (dape-stack-select-up conn n)
              (user-error "dape-stack-select-up is not available"))
            (let* ((frame (dape--current-stack-frame conn))
                   (file (and frame (kargu-dape--frame-path conn frame)))
                   (line (and frame (plist-get frame :line)))
                   (name (and frame (plist-get frame :name))))
              (format "[STACK UP %d]: Now at frame `%s` (%s:%s)\n\n%s"
                      n (or name "?") (or file "?") (or line "?")
                      (kargu-dape-get-context))))
        (error (format "ERROR: stack-select-up: %s" (error-message-string err)))))))

(defun kargu-dape-down (&optional count)
  "Select COUNT (default 1) stack frames down towards callee.
Returns the newly selected frame info and location."
  (let ((conn (kargu-dape--raw-connection))
        (n (or count 1)))
    (if (null conn)
        "ERROR: no live dape session"
      (condition-case err
          (progn
            (if (fboundp 'dape-stack-select-down)
                (dape-stack-select-down conn n)
              (user-error "dape-stack-select-down is not available"))
            (let* ((frame (dape--current-stack-frame conn))
                   (file (and frame (kargu-dape--frame-path conn frame)))
                   (line (and frame (plist-get frame :line)))
                   (name (and frame (plist-get frame :name))))
              (format "[STACK DOWN %d]: Now at frame `%s` (%s:%s)\n\n%s"
                      n (or name "?") (or file "?") (or line "?")
                      (kargu-dape-get-context))))
        (error (format "ERROR: stack-select-down: %s" (error-message-string err)))))))

(defun kargu-dape-threads ()
  "List all threads reported by the active debug adapter."
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "ERROR: no live dape session"
      (condition-case err
          (let* ((threads (kargu-dape--seq->list (dape--threads conn)))
                 (cur (dape--current-thread conn))
                 (cur-id (and cur (plist-get cur :id))))
            (if (null threads)
                "[THREADS: 0]\nNo threads reported by adapter."
              (let ((lines (list (format "[THREADS: %d]" (length threads)))))
                (dolist (th threads)
                  (let ((tid (plist-get th :id))
                        (tname (plist-get th :name))
                        (status (plist-get th :status)))
                    (push (format "  Thread #%s: %s (%s)%s"
                                  (or tid "?")
                                  (or tname "unknown")
                                  (or status "running")
                                  (if (equal tid cur-id) "  <= current" ""))
                          lines)))
                (string-join (nreverse lines) "\n"))))
        (error (format "ERROR: threads: %s" (error-message-string err)))))))

(defun kargu-dape-stack (&optional levels)
  "List call stack frames for the current thread up to LEVELS (default 20)."
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "ERROR: no live dape session"
      (condition-case err
          (let* ((thread (or (dape--current-thread conn)
                             (car (dape--stopped-threads conn))))
                 (max-lvls (or levels 20)))
            (when thread
              (let ((dape--request-blocking t))
                (dape--stack-trace conn thread max-lvls (lambda (&rest _)))))
            (let* ((frames (and thread (kargu-dape--seq->list (plist-get thread :stackFrames))))
                   (cur (dape--current-stack-frame conn))
                   (cur-id (and cur (plist-get cur :id))))
              (if (null frames)
                  "[STACK: 0 frames]"
                (let ((lines (list (format "[STACK: %d frames for thread #%s]"
                                           (length frames) (plist-get thread :id)))))
                  (cl-loop for f in (seq-take frames max-lvls)
                           for idx from 0
                           do (push (format "  #%d: %s (%s:%s)%s"
                                            idx
                                            (or (plist-get f :name) "?")
                                            (kargu-dape--frame-path conn f)
                                            (or (plist-get f :line) "?")
                                            (if (eq (plist-get f :id) cur-id) "  <= selected" ""))
                                    lines))
                  (string-join (nreverse lines) "\n")))))
        (error (format "ERROR: stack: %s" (error-message-string err)))))))

(defun kargu-dape-modules ()
  "List loaded modules and libraries in the target process."
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "ERROR: no live dape session"
      (condition-case err
          (let* ((modules (kargu-dape--seq->list (plist-get conn :modules))))
            (if (null modules)
                "[MODULES: 0 loaded or not reported by adapter]"
              (let ((lines (list (format "[MODULES: %d loaded]" (length modules)))))
                (cl-loop for m in (seq-take modules 50)
                         for i from 1
                         do (push (format "  %d. %s (%s)"
                                          i
                                          (or (plist-get m :name) "?")
                                          (or (plist-get m :path) "no path"))
                                  lines))
                (string-join (nreverse lines) "\n"))))
        (error (format "ERROR: modules: %s" (error-message-string err)))))))

(defun kargu-dape-sources ()
  "List known source files reported by the debug adapter."
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "ERROR: no live dape session"
      (condition-case err
          (let* ((sources (kargu-dape--seq->list (plist-get conn :loadedSources))))
            (if (null sources)
                "[SOURCES: not available from adapter]"
              (let ((lines (list (format "[SOURCES: %d loaded]" (length sources)))))
                (cl-loop for s in (seq-take sources 50)
                         for i from 1
                         do (push (format "  %d. %s (%s)"
                                          i
                                          (or (plist-get s :name) "?")
                                          (or (plist-get s :path) "no path"))
                                  lines))
                (string-join (nreverse lines) "\n"))))
        (error (format "ERROR: sources: %s" (error-message-string err)))))))

(defun kargu-dape-scope (&optional var-name-or-scope-idx)
  "Inspect scopes or expand child variables of VAR-NAME-OR-SCOPE-IDX."
  (let ((conn (kargu-dape--connection)))
    (if (stringp conn)
        conn
      (condition-case err
          (let* ((thread (or (dape--current-thread conn)
                             (car (dape--stopped-threads conn))))
                 (frame (or (dape--current-stack-frame conn)
                            (and thread (car (plist-get thread :stackFrames))))))
            (if (null frame)
                "ERROR: no stack frame available to inspect scope"
              (let ((dape--request-blocking t))
                (dape--scopes conn frame (lambda (&rest _)))
                (dolist (sc (kargu-dape--seq->list (plist-get frame :scopes)))
                  (unless (eq (plist-get sc :expensive) t)
                    (dape--variables conn sc (lambda (&rest _))))))
              (let ((scopes (kargu-dape--seq->list (plist-get frame :scopes))))
                (cond
                 ;; Variable expansion branch
                 ((and (stringp var-name-or-scope-idx)
                       (not (string-empty-p var-name-or-scope-idx))
                       (not (string-match-p "\\`[0-9]+\\'" var-name-or-scope-idx)))
                  (let* ((target-name var-name-or-scope-idx)
                         (target-var nil))
                    (cl-dolist (sc scopes)
                      (cl-dolist (v (kargu-dape--seq->list (plist-get sc :variables)))
                        (when (equal (plist-get v :name) target-name)
                          (setq target-var v)
                          (cl-return))))
                    (if (null target-var)
                        (format "ERROR: variable '%s' not found in current frame scopes. Available: %s"
                                target-name
                                (mapconcat (lambda (sc)
                                             (mapconcat (lambda (v) (or (plist-get v :name) "?"))
                                                        (kargu-dape--seq->list (plist-get sc :variables))
                                                        ", "))
                                           scopes "; "))
                      (let ((vref (plist-get target-var :variablesReference)))
                        (if (or (null vref) (zerop vref))
                            (format "Variable '%s' = %s (primitive value, no child properties)"
                                    target-name
                                    (kargu-dape--trunc (or (plist-get target-var :value) "?")))
                          (let ((dape--request-blocking t))
                            (dape--variables conn target-var (lambda (&rest _))))
                          (let ((children (kargu-dape--seq->list (plist-get target-var :variables)))
                                (lines (list (format "Variable '%s' = %s (expanded child fields):"
                                                     target-name
                                                     (kargu-dape--trunc (or (plist-get target-var :value) "?"))))))
                            (if (null children)
                                (push "  (no child fields reported)" lines)
                              (dolist (ch (seq-take children 60))
                                (push (format "  %s = %s%s"
                                              (or (plist-get ch :name) "?")
                                              (kargu-dape--trunc (or (plist-get ch :value) "?"))
                                              (if (and (numberp (plist-get ch :variablesReference))
                                                       (not (zerop (plist-get ch :variablesReference))))
                                                  " {...}"
                                                ""))
                                      lines)))
                            (string-join (nreverse lines) "\n")))))))
                 ;; Numeric scope index branch
                 ((and var-name-or-scope-idx
                       (or (numberp var-name-or-scope-idx)
                           (and (stringp var-name-or-scope-idx)
                                (string-match-p "\\`[0-9]+\\'" var-name-or-scope-idx))))
                  (let* ((idx (if (numberp var-name-or-scope-idx)
                                  var-name-or-scope-idx
                                (string-to-number var-name-or-scope-idx)))
                         (sc (nth idx scopes)))
                    (if (null sc)
                        (format "ERROR: scope index %d out of range (available: 0 to %d)"
                                idx (1- (length scopes)))
                      (let ((lines (list (format "Scope #%d (%s):" idx (or (plist-get sc :name) "?")))))
                        (dolist (v (seq-take (kargu-dape--seq->list (plist-get sc :variables)) 60))
                          (push (format "  %s = %s%s"
                                        (or (plist-get v :name) "?")
                                        (kargu-dape--trunc (or (plist-get v :value) "?"))
                                        (if (and (numberp (plist-get v :variablesReference))
                                                 (not (zerop (plist-get v :variablesReference))))
                                            " {...}"
                                          ""))
                                lines))
                        (string-join (nreverse lines) "\n")))))
                 ;; All scopes overview branch
                 (t
                  (let ((lines (list (format "[SCOPES: %d in frame '%s']"
                                             (length scopes) (or (plist-get frame :name) "?")))))
                    (cl-loop for sc in scopes
                             for i from 0
                             do (push (format "Scope #%d: %s" i (or (plist-get sc :name) "?")) lines)
                                (dolist (v (seq-take (kargu-dape--seq->list (plist-get sc :variables)) 30))
                                  (push (format "    %s = %s%s"
                                                (or (plist-get v :name) "?")
                                                (kargu-dape--trunc (or (plist-get v :value) "?"))
                                                (if (and (numberp (plist-get v :variablesReference))
                                                         (not (zerop (plist-get v :variablesReference))))
                                                    " {...}"
                                                  ""))
                                        lines)))
                    (string-join (nreverse lines) "\n")))))))
        (error (format "ERROR: scope: %s" (error-message-string err)))))))

(defun kargu-dape-watch (&optional expr remove-p)
  "List, add, or remove watch expressions in Dape.
If EXPR is provided and REMOVE-P is nil, adds EXPR to watch.
If EXPR is provided and REMOVE-P is non-nil, removes EXPR from watch.
Always returns the current watch list."
  (let ((conn (kargu-dape--raw-connection)))
    (condition-case err
        (progn
          (when (and (stringp expr) (not (string-empty-p expr)))
            (when (fboundp 'dape-watch-dwim)
              (dape-watch-dwim expr remove-p (not remove-p))))
          (if (and (boundp 'dape--watched) dape--watched)
              (let ((lines (list (format "[WATCH LIST: %d expressions]" (length dape--watched)))))
                (dolist (w dape--watched)
                  (let* ((w-expr (or (plist-get w :expression) (and (stringp w) w) "?"))
                         (w-val (and conn (kargu-dape-eval-expression w-expr "watch"))))
                    (push (format "  * %s => %s" w-expr (or w-val "not evaluated")) lines)))
                (string-join (nreverse lines) "\n"))
            "[WATCH LIST: 0]\nNo watch expressions active."))
      (error (format "ERROR: watch: %s" (error-message-string err))))))

(defun kargu-dape-kill ()
  "Terminate the active debuggee process."
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "No live dape session to kill."
      (condition-case err
          (progn
            (if (fboundp 'dape-kill)
                (dape-kill conn)
              (user-error "dape-kill not available"))
            "Debuggee process killed.")
        (error (format "ERROR: kill failed: %s" (error-message-string err)))))))

(defun kargu-dape-disconnect ()
  "Disconnect from the active debug adapter."
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "No live dape session to disconnect."
      (condition-case err
          (progn
            (if (fboundp 'dape-disconnect-quit)
                (dape-disconnect-quit conn)
              (user-error "dape-disconnect-quit not available"))
            "Disconnected from debug adapter.")
        (error (format "ERROR: disconnect failed: %s" (error-message-string err)))))))

(defun kargu-dape-quit ()
  "Quit the debugging session and cleanup dape buffers."
  (condition-case err
      (progn
        (if (fboundp 'dape-quit)
            (dape-quit)
          (user-error "dape-quit not available"))
        "Debug session quit and cleaned up.")
    (error (format "ERROR: quit failed: %s" (error-message-string err)))))

;;;; Tool registration -----------------------------------------------------

(defun kargu-dape-register-tools ()
  "Register the complete suite of 20 Dape debugger tools and aliases."
  ;; 1. debug / debug_start
  (kargu-register-tool
   "debug_start"
   "Start or attach a Dape debugging session with optional config_name."
   '(("type" . "object")
     ("properties" . (("config_name" . (("type" . "string")
                                        ("description" . "Optional dape configuration name (e.g. 'lldb-vscode', 'dlv', 'debugpy')."))))))
   (lambda (args)
     (kargu-dape-start (kargu--tool-arg args "config_name"))))

  ;; 2. debug_get_context
  (kargu-register-tool
   "debug_get_context"
   "Inspect the live debug session: the paused thread's call-stack and all in-scope variables."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-get-context)))

  ;; 3. eval / debug_eval
  (kargu-register-tool
   "debug_eval"
   "Evaluate an expression in the paused frame and return its value. (Note: In Rust/C++, avoid runtime method calls like .len())."
   '(("type" . "object")
     ("properties" . (("expression" . (("type" . "string")
                                       ("description" . "Expression to evaluate.")))
                       ("context" . (("type" . "string")
                                     ("description" . "Evaluation context: 'repl' (default), 'hover', or 'watch'.")))))
     ("required" . ["expression"]))
   (lambda (args)
     (let ((expr (kargu--aget args "expression")))
       (if (or (null expr) (string-empty-p expr))
           "ERROR: expression is required"
         (kargu-dape-eval-expression expr (kargu--aget args "context"))))))

  ;; 4. breakpoints / debug_list_breakpoints
  (kargu-register-tool
   "debug_list_breakpoints"
   "List all source breakpoints (file and line) known to the debugger."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-list-breakpoints)))

  ;; 5. set_breakpoint / debug_set_breakpoint
  (kargu-register-tool
   "debug_set_breakpoint"
   "Set a source breakpoint at a file_path and 1-based line number. Requires both parameters."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "Absolute or project-relative path of the source file.")))
                       ("line" . (("type" . "integer")
                                  ("description" . "1-based line number to set breakpoint on.")))))
     ("required" . ["file_path" "line"]))
   (lambda (args)
     (let ((err (kargu-dape--validate-bp-args args "debug_set_breakpoint")))
       (if err err
         (kargu-dape-set-breakpoint
          (kargu--tool-file-path args)
          (kargu--tool-arg args "line"))))))

  ;; 6. clear_breakpoint / debug_clear_breakpoint
  (kargu-register-tool
   "debug_clear_breakpoint"
   "Remove a source breakpoint at a specific file_path and line number."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "Absolute or project-relative path of the source file.")))
                       ("line" . (("type" . "integer")
                                  ("description" . "1-based line number to clear breakpoint from.")))))
     ("required" . ["file_path" "line"]))
   (lambda (args)
     (let ((err (kargu-dape--validate-bp-args args "debug_clear_breakpoint")))
       (if err err
         (kargu-dape-clear-breakpoint
          (kargu--tool-file-path args)
          (kargu--tool-arg args "line"))))))

  ;; 7. toggle_breakpoint / debug_toggle_breakpoint
  (kargu-register-tool
   "debug_toggle_breakpoint"
   "Toggle a breakpoint at file_path and line number."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "Absolute or project-relative path of the source file.")))
                       ("line" . (("type" . "integer")
                                  ("description" . "1-based line number.")))))
     ("required" . ["file_path" "line"]))
   (lambda (args)
     (let ((err (kargu-dape--validate-bp-args args "debug_toggle_breakpoint")))
       (if err err
         (kargu-dape-toggle-breakpoint
          (kargu--tool-file-path args)
          (kargu--tool-arg args "line"))))))

  ;; 8. next / debug_step_over
  (kargu-register-tool
   "debug_step_over"
   "Step to the next source line in current function (does not step into calls)."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args &optional callback) (kargu-dape-step-over callback)))

  ;; 9. step / debug_step_in
  (kargu-register-tool
   "debug_step_in"
   "Step into the function call on the current line."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args &optional callback) (kargu-dape-step-in callback)))

  ;; 10. out / debug_step_out
  (kargu-register-tool
   "debug_step_out"
   "Step out of current function back to caller."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args &optional callback) (kargu-dape-step-out callback)))

  ;; 11. continue / debug_continue
  (kargu-register-tool
   "debug_continue"
   "Resume execution until next breakpoint or termination."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args &optional callback) (kargu-dape-continue callback)))

  ;; 12. pause / debug_pause
  (kargu-register-tool
   "debug_pause"
   "Pause execution of running debuggee and return paused location, stack, and variables."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args &optional callback) (kargu-dape-pause callback)))

  ;; 13. up / debug_up
  (kargu-register-tool
   "debug_up"
   "Select stack frame up towards caller. Optional count (default 1)."
   '(("type" . "object")
     ("properties" . (("count" . (("type" . "integer")
                                  ("description" . "Number of stack frames to navigate up (default 1)."))))))
   (lambda (args)
     (kargu-dape-up (kargu--tool-arg args "count"))))

  ;; 14. down / debug_down
  (kargu-register-tool
   "debug_down"
   "Select stack frame down towards callee. Optional count (default 1)."
   '(("type" . "object")
     ("properties" . (("count" . (("type" . "integer")
                                  ("description" . "Number of stack frames to navigate down (default 1)."))))))
   (lambda (args)
     (kargu-dape-down (kargu--tool-arg args "count"))))

  ;; 15. threads / debug_threads
  (kargu-register-tool
   "debug_threads"
   "List all threads reported by the active debugger adapter."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-threads)))

  ;; 16. stack / debug_stack
  (kargu-register-tool
   "debug_stack"
   "List call stack frames for the current thread."
   '(("type" . "object")
     ("properties" . (("levels" . (("type" . "integer")
                                   ("description" . "Maximum frame depth to report (default 20)."))))))
   (lambda (args)
     (kargu-dape-stack (kargu--tool-arg args "levels"))))

  ;; 17. modules / debug_modules
  (kargu-register-tool
   "debug_modules"
   "List loaded modules and shared libraries in target process."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-modules)))

  ;; 18. sources / debug_sources
  (kargu-register-tool
   "debug_sources"
   "List known source files reported by the debug adapter."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-sources)))

  ;; 19. scope / debug_scope
  (kargu-register-tool
   "debug_scope"
   "Inspect scopes or expand child variables of a struct/vector by name."
   '(("type" . "object")
     ("properties" . (("variable_name" . (("type" . "string")
                                          ("description" . "Name of variable to expand child fields for (e.g. 'frame', 'landmarks_2d').")))
                       ("scope_index" . (("type" . "integer")
                                         ("description" . "Index of scope to list (0-based)."))))))
   (lambda (args)
     (let ((var (kargu--aget args "variable_name"))
           (idx (kargu--tool-arg args "scope_index")))
       (kargu-dape-scope (or var idx)))))

  ;; 20. watch / debug_watch
  (kargu-register-tool
   "debug_watch"
   "List or update watch expressions in Dape."
   '(("type" . "object")
     ("properties" . (("expression" . (("type" . "string")
                                       ("description" . "Expression to add or remove from watch list.")))
                       ("remove" . (("type" . "boolean")
                                    ("description" . "Set true to remove expression instead of adding."))))))
   (lambda (args)
     (kargu-dape-watch (kargu--aget args "expression")
                       (kargu--tool-arg args "remove"))))

  ;; 21. restart / debug_restart
  (kargu-register-tool
   "debug_restart"
   "Restart the debugging session with current configuration."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-restart)))

  ;; 22. kill / debug_kill
  (kargu-register-tool
   "debug_kill"
   "Terminate the debuggee process."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-kill)))

  ;; 23. disconnect / debug_disconnect
  (kargu-register-tool
   "debug_disconnect"
   "Disconnect from the debug adapter."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-disconnect)))

  ;; 24. quit / debug_quit
  (kargu-register-tool
   "debug_quit"
   "Quit debug session and clean up dape buffers."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-quit)))

  ;; Aliases for ergonomic Dape command mapping
  (kargu-register-tool-alias "debug" "debug_start")
  (kargu-register-tool-alias "next" "debug_step_over")
  (kargu-register-tool-alias "step_over" "debug_step_over")
  (kargu-register-tool-alias "continue" "debug_continue")
  (kargu-register-tool-alias "pause" "debug_pause")
  (kargu-register-tool-alias "step" "debug_step_in")
  (kargu-register-tool-alias "step_in" "debug_step_in")
  (kargu-register-tool-alias "out" "debug_step_out")
  (kargu-register-tool-alias "step_out" "debug_step_out")
  (kargu-register-tool-alias "finish" "debug_step_out")
  (kargu-register-tool-alias "up" "debug_up")
  (kargu-register-tool-alias "down" "debug_down")
  (kargu-register-tool-alias "threads" "debug_threads")
  (kargu-register-tool-alias "stack" "debug_stack")
  (kargu-register-tool-alias "modules" "debug_modules")
  (kargu-register-tool-alias "sources" "debug_sources")
  (kargu-register-tool-alias "breakpoints" "debug_list_breakpoints")
  (kargu-register-tool-alias "debug_breakpoints" "debug_list_breakpoints")
  (kargu-register-tool-alias "set_breakpoint" "debug_set_breakpoint")
  (kargu-register-tool-alias "clear_breakpoint" "debug_clear_breakpoint")
  (kargu-register-tool-alias "toggle_breakpoint" "debug_toggle_breakpoint")
  (kargu-register-tool-alias "scope" "debug_scope")
  (kargu-register-tool-alias "debug_variables" "debug_scope")
  (kargu-register-tool-alias "debug_inspect_variable" "debug_scope")
  (kargu-register-tool-alias "watch" "debug_watch")
  (kargu-register-tool-alias "eval" "debug_eval")
  (kargu-register-tool-alias "restart" "debug_restart")
  (kargu-register-tool-alias "kill" "debug_kill")
  (kargu-register-tool-alias "disconnect" "debug_disconnect")
  (kargu-register-tool-alias "quit" "debug_quit"))

(kargu-dape-register-tools)

(provide 'kargu/tools/dape)

;;; kargu/tools/dape.el ends here
