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
(require 'kargu/tools/lsp)         ; for kargu--resolve-path
(require 'dape nil t)

(defvar dape--request-blocking)

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
        conn
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
             (err-msg (format "ERROR: evaluate failed: %s" err-msg))
             ((and body (plist-get body :result))
              (kargu-dape--trunc (plist-get body :result)))
             (t "(evaluated, no result value)")))
        (error
         (format "ERROR: dape eval: %s" (error-message-string err)))))))

;;;; Breakpoints -----------------------------------------------------------

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
  "Return a text list of all source breakpoints."
  (let ((bps (kargu-dape--breakpoints)))
    (cond
     ((null (fboundp 'dape--breakpoint-file-name))
      "ERROR: dape is not installed or not loaded")
     ((null bps) "No source breakpoints set.")
     (t
      (concat
       (format "%d breakpoint(s):\n" (length bps))
       (mapconcat (lambda (bp)
                    (format "  %s:%d" (nth 0 bp) (nth 1 bp)))
                  bps "\n"))))))

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

;;;; Tool registration -----------------------------------------------------

(defun kargu-dape-register-tools ()
  "Register the debugger tools with the kargu tool registry."
  (kargu-register-tool
   "debug_get_context"
   "Inspect the live debug session: the paused thread's call-stack (function, file, line per frame) and all in-scope variables of the selected frame. Only useful while the program is paused at a breakpoint. Read actual runtime values instead of guessing."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-get-context)))
  (kargu-register-tool
   "debug_eval"
   "Evaluate an expression in the paused debug session (selected stack frame) and return its value. Use it to check hypotheses about runtime state."
   '(("type" . "object")
     ("properties" . (("expression" . (("type" . "string")
                                       ("description" . "Expression in the debuggee's language, e.g. a variable, a call, or an arithmetic combination.")))
                       ("context" . (("type" . "string")
                                     ("description" . "Evaluation context: \"repl\" (default), \"hover\" or \"watch\".")))))
     ("required" . ["expression"]))
   (lambda (args)
     (let ((expr (kargu--aget args "expression")))
       (if (or (null expr) (string-empty-p expr))
           "ERROR: expression is required"
         (kargu-dape-eval-expression
          expr (kargu--aget args "context"))))))
  (kargu-register-tool
   "debug_list_breakpoints"
   "List all source breakpoints (file and line) known to the debugger."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-dape-list-breakpoints)))
  (kargu-register-tool
   "debug_toggle_breakpoint"
   "Set or remove a source breakpoint at a file and line (1-based). Setting a breakpoint before running/restarting lets the program pause there for inspection."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "Absolute or project-relative path of the source file.")))
                       ("line" . (("type" . "integer")
                                  ("description" . "1-based line number.")))))
     ("required" . ["file_path" "line"]))
   (lambda (args)
     (let ((path (kargu--tool-file-path args)))
       (if (not (kargu--nonempty path))
           (kargu--tool-missing-file-path args)
         (kargu-dape-toggle-breakpoint
          path
          (kargu--tool-arg args "line")))))))

(kargu-dape-register-tools)

(provide 'kargu/tools/dape)

;;; kargu/tools/dape.el ends here
