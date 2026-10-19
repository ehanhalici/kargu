;;; commands.el --- Debug inspection commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Navigate stacks, inspect variables and manage the debug session.

;;; Code:

(require 'kargu/tools/dape/execution)
(require 'kargu/tools/dape/watch)

(declare-function dape--modules "dape" (conn))
(declare-function dape--sources "dape" (conn))


(cl-defun kargu-dape--after-stack-select (selection callback &key count label)
  "Report SELECTION under LABEL after moving COUNT frames, using CALLBACK."
  (unless (kargu-dape-selection-current-p selection)
    (error "Debug selection changed during navigation"))
  (let* ((interactive (called-interactively-p 'any))
         (conn (kargu-dape-selection-connection selection))
         (frame (kargu-dape-selection-frame selection))
         (file (and frame (kargu-dape--frame-path conn frame)))
         (line (and frame (plist-get frame :line)))
         (name (and frame (plist-get frame :name)))
         (head (format "[%s %d]: Now at frame `%s` (%s:%s)\n\n"
                       label count (or name "?") (or file "?") (or line "?"))))
    (kargu-dape-get-context
     (lambda (ctx)
       (kargu-dape--deliver callback (if (string-prefix-p "ERROR:" ctx) ctx (concat head ctx)) interactive))
     conn)))

(defun kargu-dape--move-frame (delta callback selection)
  "Move by DELTA stack frames using SELECTION and report to CALLBACK."
  (let* ((conn (kargu-dape-selection-connection selection))
         (thread (kargu-dape-selection-thread selection)))
    (unless (kargu-dape-selection-current-p selection)
      (error "Debug selection changed while fetching the navigation stack"))
    (let* ((frames (kargu-dape--seq->list (plist-get thread :stackFrames)))
           (current (kargu-dape-selection-frame-id selection))
           (index (if current
                      (cl-position current frames :key (lambda (frame) (plist-get frame :id)) :test #'equal)
                    0))
           (target (and index (nth (max 0 (+ index delta)) frames))))
      (when (or (null index) (< (+ index delta) 0) (null target))
        (error "Requested frame is outside the available stack"))
      (dape-select-stack conn (plist-get target :id))
      (let ((moved (copy-kargu-dape-selection selection)))
        (setf (kargu-dape-selection-frame-id moved) (plist-get target :id))
        (kargu-dape--after-stack-select moved callback :count (abs delta)
                                        :label (if (> delta 0) "STACK UP" "STACK DOWN"))))))

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

(defun kargu-dape--stack-text (selection frames max-lvls)
  "Render FRAMES for captured SELECTION, at most MAX-LVLS of them."
  (if (null frames)
      "[STACK: 0 frames]"
    (let* ((conn (kargu-dape-selection-connection selection))
           (thread (kargu-dape-selection-thread selection))
           (cur-id (kargu-dape-selection-frame-id selection))
           (lines (list (format "[STACK: %d frames for thread #%s]"
                                (length frames) (plist-get thread :id)))))
      (cl-loop for f in (seq-take frames max-lvls)
               for idx from 0
               do (push (format "  #%d: %s (%s:%s)%s"
                                idx
                                (or (plist-get f :name) "?")
                                (kargu-dape--frame-path conn f)
                                (or (plist-get f :line) "?")
                                (if (equal (plist-get f :id) cur-id) "  <= selected" ""))
                        lines))
      (string-join (nreverse lines) "\n"))))

(defun kargu-dape--stack (levels callback selection)
  "List call stack frames for the current thread up to LEVELS (default 20).
The text from prepared SELECTION is passed to CALLBACK."
  (funcall callback
           (kargu-dape--stack-text selection
                                   (kargu-dape--seq->list
                                    (plist-get (kargu-dape-selection-thread selection) :stackFrames))
                                   (or levels 20))))

(defun kargu-dape-modules ()
  "List loaded modules and libraries in the target process."
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "ERROR: no live dape session"
      (condition-case err
          (let* ((modules (kargu-dape--seq->list (dape--modules conn))))
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
          (let* ((sources (kargu-dape--seq->list (dape--sources conn))))
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
          (kargu-dape--call #'dape--variables
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

(defun kargu-dape--scope (var-name-or-scope-idx callback selection)
  "Inspect scopes or expand child variables of VAR-NAME-OR-SCOPE-IDX.
The text from SELECTION is passed to CALLBACK."
  (let ((conn (kargu-dape-selection-connection selection))
        (interactive (called-interactively-p 'any)))
    (if (stringp conn)
        (kargu-dape--deliver callback conn interactive)
      (condition-case err
          (let ((frame (kargu-dape-selection-frame selection)))
            (if (null frame)
                (kargu-dape--deliver
                 callback "ERROR: no stack frame available to inspect scope" interactive)
              (kargu-dape--call #'dape--scopes
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

(defun kargu-dape--watch-lines (watched callback selection)
  "Evaluate WATCHED in SELECTION and pass the rendered lines to CALLBACK."
  (let ((rest (copy-sequence watched))
        (lines (list (format "[WATCH LIST: %d expressions]" (length watched)))))
    (cl-labels ((next ()
                  (if (null rest)
                      (funcall callback (string-join (nreverse lines) "\n"))
                    (let ((w-expr (pop rest)))
                      (kargu-dape-eval-expression
                       w-expr "watch"
                       (kargu-async-wrap
                        kargu-async--current-task
                        (lambda (val)
                          (push (format "  * %s => %s" w-expr (or val "not evaluated")) lines)
                          (next)))
                       :selection selection)))))
      (next))))

(cl-defun kargu-dape--watch (expr remove-p callback &key selection)
  "List, add, or remove this session's watch expressions.
If EXPR is provided and REMOVE-P is nil, adds EXPR to watch.
If EXPR is provided and REMOVE-P is non-nil, removes EXPR from watch.
The watch list for SELECTION is passed to CALLBACK."
  (let ((interactive (called-interactively-p 'any))
        (conn (kargu-dape-selection-connection selection)))
    (condition-case err
        (if (stringp conn)
            (kargu-dape--deliver callback conn interactive)
          (if-let* ((watched (kargu-dape-watch-expressions conn expr remove-p)))
              (kargu-dape--watch-lines watched
                                       (lambda (text) (kargu-dape--deliver callback text interactive)) selection)
            (kargu-dape--deliver callback "[WATCH LIST: 0]\nNo watch expressions active." interactive)))
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

(defun kargu-dape-stack (&optional levels callback)
  "Collect LEVELS stack frames and deliver one result to CALLBACK."
  (kargu-dape--run-chain callback (lambda (done selected) (kargu-dape--stack levels done selected))
                         :levels (or levels 20)))

(defun kargu-dape-scope (&optional var-name-or-scope-idx callback)
  "Inspect VAR-NAME-OR-SCOPE-IDX and deliver one result to CALLBACK."
  (kargu-dape--run-chain callback
                         (lambda (done selected) (kargu-dape--scope var-name-or-scope-idx done selected))))

(defun kargu-dape-watch (&optional expr remove-p callback)
  "Update EXPR using REMOVE-P and deliver the watch list to CALLBACK."
  (kargu-dape--run-chain callback (lambda (done selected) (kargu-dape--watch expr remove-p done :selection selected))))

(defun kargu-dape-up (&optional count callback)
  "Move COUNT frames toward callers and deliver context to CALLBACK."
  (kargu-dape--run-chain callback (lambda (done selected) (kargu-dape--move-frame (or count 1) done selected))))

(defun kargu-dape-down (&optional count callback)
  "Move COUNT frames toward callees and deliver context to CALLBACK."
  (kargu-dape--run-chain callback (lambda (done selected) (kargu-dape--move-frame (- (or count 1)) done selected))))

(provide 'kargu/tools/dape/commands)

;;; commands.el ends here
