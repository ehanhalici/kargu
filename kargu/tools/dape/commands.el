;;; commands.el --- Debug inspection commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Navigate stacks, inspect variables and manage the debug session.

;;; Code:

(require 'kargu/tools/dape/execution)

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
            (unless (kargu-permission-approve
                     (format "start debug adapter %s" (or chosen "(interactive)"))
                     (kargu-permission-project-root))
              (error "Starting the debugger was not approved by the user"))
            (if chosen
                (progn
                  (dape chosen)
                  (format "Debug session started with configuration '%s'." chosen))
              (with-current-buffer (kargu-dape--target-buffer)
                (call-interactively #'dape))
              "Debug session launched."))))
    (error (format "ERROR: debug start failed: %s" (error-message-string err)))))

(defun kargu-dape--after-stack-select (conn n label callback)
  "Report frame N of CONN under LABEL, then the refreshed context, to CALLBACK."
  (let* ((interactive (called-interactively-p 'any))
         (frame (dape--current-stack-frame conn))
         (file (and frame (kargu-dape--frame-path conn frame)))
         (line (and frame (plist-get frame :line)))
         (name (and frame (plist-get frame :name)))
         (head (format "[%s %d]: Now at frame `%s` (%s:%s)\n\n"
                       label n (or name "?") (or file "?") (or line "?"))))
    (kargu-dape-get-context
     (lambda (ctx)
       (kargu-dape--deliver callback (concat head ctx) interactive)))))

(defun kargu-dape-up (&optional count callback)
  "Select COUNT (default 1) stack frames up towards caller.
The new frame and context are passed to CALLBACK."
  (let ((conn (kargu-dape--raw-connection))
        (n (or count 1))
        (interactive (called-interactively-p 'any)))
    (if (null conn)
        (kargu-dape--deliver callback "ERROR: no live dape session" interactive)
      (condition-case err
          (progn
            (if (fboundp 'dape-stack-select-up)
                (dape-stack-select-up conn n)
              (user-error "Dape-stack-select-up is not available"))
            (kargu-dape--after-stack-select conn n "STACK UP" callback))
        (error (kargu-dape--deliver
                callback
                (format "ERROR: stack-select-up: %s" (error-message-string err))
                interactive))))))

(defun kargu-dape-down (&optional count callback)
  "Select COUNT (default 1) stack frames down towards callee.
The new frame and context are passed to CALLBACK."
  (let ((conn (kargu-dape--raw-connection))
        (n (or count 1))
        (interactive (called-interactively-p 'any)))
    (if (null conn)
        (kargu-dape--deliver callback "ERROR: no live dape session" interactive)
      (condition-case err
          (progn
            (if (fboundp 'dape-stack-select-down)
                (dape-stack-select-down conn n)
              (user-error "Dape-stack-select-down is not available"))
            (kargu-dape--after-stack-select conn n "STACK DOWN" callback))
        (error (kargu-dape--deliver
                callback
                (format "ERROR: stack-select-down: %s" (error-message-string err))
                interactive))))))

(defun kargu-dape-threads (&optional callback)
  "List all threads reported by the active debug adapter.
The text is passed to CALLBACK when given, and returned otherwise."
  (let* ((interactive (called-interactively-p 'any))
         (conn (kargu-dape--raw-connection))
         (text
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
    (kargu-dape--deliver callback text interactive)))

(defun kargu-dape--stack-text (conn thread frames max-lvls)
  "Render FRAMES of THREAD on CONN, at most MAX-LVLS of them."
  (if (null frames)
      "[STACK: 0 frames]"
    (let* ((cur (dape--current-stack-frame conn))
           (cur-id (and cur (plist-get cur :id)))
           (lines (list (format "[STACK: %d frames for thread #%s]"
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
      (string-join (nreverse lines) "\n"))))

(defun kargu-dape-stack (&optional levels callback)
  "List call stack frames for the current thread up to LEVELS (default 20).
The text is passed to CALLBACK."
  (let ((conn (kargu-dape--raw-connection))
        (interactive (called-interactively-p 'any))
        (max-lvls (or levels 20)))
    (if (null conn)
        (kargu-dape--deliver callback "ERROR: no live dape session" interactive)
      (condition-case err
          (let ((thread (or (dape--current-thread conn)
                            (car (dape--stopped-threads conn)))))
            (if (null thread)
                (kargu-dape--deliver callback "[STACK: 0 frames]" interactive)
              (dape--stack-trace
               conn thread max-lvls
               (lambda (&rest _)
                 (kargu-dape--deliver
                  callback
                  (kargu-dape--stack-text
                   conn thread
                   (kargu-dape--seq->list (plist-get thread :stackFrames))
                   max-lvls)
                  interactive)))))
        (error (kargu-dape--deliver
                callback
                (format "ERROR: stack: %s" (error-message-string err))
                interactive))))))

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

(defun kargu-dape--scope-names (scopes)
  "Comma-separated variable names available in SCOPES."
  (mapconcat (lambda (sc)
               (mapconcat (lambda (v) (or (plist-get v :name) "?"))
                          (kargu-dape--seq->list (plist-get sc :variables))
                          ", "))
             scopes "; "))

(defun kargu-dape--find-scope-var (scopes target-name)
  "Variable named TARGET-NAME in SCOPES, or nil."
  (catch 'found
    (dolist (sc scopes)
      (dolist (v (kargu-dape--seq->list (plist-get sc :variables)))
        (when (equal (plist-get v :name) target-name)
          (throw 'found v))))
    nil))

(defun kargu-dape--expanded-var-text (target-name target-var)
  "Text of TARGET-VAR named TARGET-NAME after its children have been fetched."
  (let ((children (kargu-dape--seq->list (plist-get target-var :variables)))
        (lines (list (format "Variable '%s' = %s (expanded child fields):"
                             target-name
                             (kargu-dape--trunc (or (plist-get target-var :value) "?"))))))
    (if (null children)
        (push "  (no child fields reported)" lines)
      (dolist (ch (seq-take children 60))
        (push (kargu-dape--format-var-line ch "  ") lines)))
    (string-join (nreverse lines) "\n")))

(defun kargu-dape--scope-expand-var (conn scopes target-name callback)
  "Expand TARGET-NAME in SCOPES on CONN, reporting to CALLBACK."
  (let ((target-var (kargu-dape--find-scope-var scopes target-name)))
    (if (null target-var)
        (funcall callback
                 (format "ERROR: variable '%s' not found in current frame scopes. Available: %s"
                         target-name (kargu-dape--scope-names scopes)))
      (let ((vref (plist-get target-var :variablesReference)))
        (if (or (null vref) (zerop vref))
            (funcall callback
                     (format "Variable '%s' = %s (primitive value, no child properties)"
                             target-name
                             (kargu-dape--trunc (or (plist-get target-var :value) "?"))))
          (dape--variables
           conn target-var
           (lambda (&rest _)
             (funcall callback
                      (kargu-dape--expanded-var-text target-name target-var)))))))))

(defun kargu-dape--scope-inspect-index (scopes idx)
  "Inspect scope at IDX in SCOPES."
  (let ((sc (nth idx scopes)))
    (if (null sc)
        (format "ERROR: scope index %d out of range (available: 0 to %d)"
                idx (1- (length scopes)))
      (let ((lines (list (format "Scope #%d (%s):" idx (or (plist-get sc :name) "?")))))
        (dolist (v (seq-take (kargu-dape--seq->list (plist-get sc :variables)) 60))
          (push (kargu-dape--format-var-line v "  ") lines))
        (string-join (nreverse lines) "\n")))))

(defun kargu-dape--scope-overview (scopes frame)
  "Overview of all SCOPES in FRAME."
  (let ((lines (list (format "[SCOPES: %d in frame '%s']"
                             (length scopes) (or (plist-get frame :name) "?")))))
    (cl-loop for sc in scopes
             for i from 0
             do (push (format "Scope #%d: %s" i (or (plist-get sc :name) "?")) lines)
             (dolist (v (seq-take (kargu-dape--seq->list (plist-get sc :variables)) 30))
               (push (kargu-dape--format-var-line v "    ") lines)))
    (string-join (nreverse lines) "\n")))

(defun kargu-dape--scope-answer (conn scopes frame which callback interactive)
  "Report WHICH variable in SCOPES for FRAME on CONN.
Deliver the result to CALLBACK and display it when INTERACTIVE is non-nil."
  (cond
   ((and (stringp which) (not (string-empty-p which))
         (not (string-match-p "\\`[0-9]+\\'" which)))
    (kargu-dape--scope-expand-var
     conn scopes which
     (lambda (text) (kargu-dape--deliver callback text interactive))))
   ((and which (or (numberp which)
                   (and (stringp which) (string-match-p "\\`[0-9]+\\'" which))))
    (kargu-dape--deliver
     callback
     (kargu-dape--scope-inspect-index
      scopes (if (numberp which) which (string-to-number which)))
     interactive))
   (t (kargu-dape--deliver callback (kargu-dape--scope-overview scopes frame) interactive))))

(defun kargu-dape-scope (&optional var-name-or-scope-idx callback)
  "Inspect scopes or expand child variables of VAR-NAME-OR-SCOPE-IDX.
The text is passed to CALLBACK."
  (let ((conn (kargu-dape--connection))
        (interactive (called-interactively-p 'any)))
    (if (stringp conn)
        (kargu-dape--deliver callback conn interactive)
      (condition-case err
          (let* ((thread (or (dape--current-thread conn)
                             (car (dape--stopped-threads conn))))
                 (frame (or (dape--current-stack-frame conn)
                            (and thread (car (plist-get thread :stackFrames))))))
            (if (null frame)
                (kargu-dape--deliver
                 callback "ERROR: no stack frame available to inspect scope" interactive)
              (dape--scopes
               conn frame
               (lambda (&rest _)
                 (kargu-dape--fetch-variables
                  conn (kargu-dape--seq->list (plist-get frame :scopes))
                  (lambda ()
                    (kargu-dape--scope-answer
                     conn
                     (kargu-dape--seq->list (plist-get frame :scopes))
                     frame var-name-or-scope-idx callback interactive)))))))
        (error (kargu-dape--deliver
                callback
                (format "ERROR: scope: %s" (error-message-string err))
                interactive))))))

(defun kargu-dape--watch-lines (watched callback)
  "Evaluate WATCHED expressions in order and pass the rendered lines to CALLBACK."
  (let ((rest (copy-sequence watched))
        (lines (list (format "[WATCH LIST: %d expressions]" (length watched)))))
    (cl-labels ((next ()
                  (if (null rest)
                      (funcall callback (string-join (nreverse lines) "\n"))
                    (let* ((w (pop rest))
                           (w-expr (or (plist-get w :expression) (and (stringp w) w) "?")))
                      (kargu-dape-eval-expression
                       w-expr "watch"
                       (lambda (val)
                         (push (format "  * %s => %s" w-expr (or val "not evaluated")) lines)
                         (next)))))))
      (next))))

(defun kargu-dape-watch (&optional expr remove-p callback)
  "List, add, or remove watch expressions in Dape.
If EXPR is provided and REMOVE-P is nil, adds EXPR to watch.
If EXPR is provided and REMOVE-P is non-nil, removes EXPR from watch.
The current watch list is passed to CALLBACK."
  (let ((interactive (called-interactively-p 'any)))
    (condition-case err
        (progn
          (when (and (stringp expr) (not (string-empty-p expr)))
            (when (fboundp 'dape-watch-dwim)
              (dape-watch-dwim expr remove-p (not remove-p))))
          (if (and (boundp 'dape--watched) dape--watched)
              (kargu-dape--watch-lines
               dape--watched
               (lambda (text) (kargu-dape--deliver callback text interactive)))
            (kargu-dape--deliver callback
                                 "[WATCH LIST: 0]\nNo watch expressions active."
                                 interactive)))
      (error (kargu-dape--deliver
              callback
              (format "ERROR: watch: %s" (error-message-string err))
              interactive)))))

(defun kargu-dape-kill ()
  "Terminate the active debuggee process."
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "No live dape session to kill."
      (condition-case err
          (progn
            (if (fboundp 'dape-kill)
                (dape-kill conn)
              (user-error "Dape-kill not available"))
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
              (user-error "Dape-disconnect-quit not available"))
            "Disconnected from debug adapter.")
        (error (format "ERROR: disconnect failed: %s" (error-message-string err)))))))

(defun kargu-dape-quit ()
  "Quit the debugging session and cleanup dape buffers."
  (condition-case err
      (progn
        (if (fboundp 'dape-quit)
            (dape-quit)
          (user-error "Dape-quit not available"))
        "Debug session quit and cleaned up.")
    (error (format "ERROR: quit failed: %s" (error-message-string err)))))

(provide 'kargu/tools/dape/commands)

;;; commands.el ends here
