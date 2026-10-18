;;; register.el --- Debug tool registration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Expose debugger commands through the agent tool registry.

;;; Code:

(require 'kargu/api/tools)
(require 'kargu/tools/dape/commands)
(require 'kargu/tools/dape/preflight)

;;;; Tool registration -----------------------------------------------------

(defconst kargu-dape--tool-specs
  (list
   (list
    "debug_start"
    "Start or attach a Dape debugging session with optional config_name."
    '(("type" . "object")
      ("properties" . (("config_name" . (("type" . "string")
                                         ("description" . "Optional dape configuration name (e.g. 'lldb-vscode', 'dlv', 'debugpy')."))))))
    (lambda (args &optional callback)
      (kargu-dape-start (kargu--tool-arg args "config_name") callback)))
   (list
    "debug_get_context"
    "Inspect the live debug session: the paused thread's call-stack and all in-scope variables."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args &optional callback) (kargu-dape-get-context callback)))
   (list
    "debug_eval"
    "Evaluate an expression in the paused frame and return its value. (what the adapter can evaluate depends on the language; see the language profile)."
    '(("type" . "object")
      ("properties" . (("expression" . (("type" . "string")
                                        ("description" . "Expression to evaluate.")))
                       ("context" . (("type" . "string")
                                     ("description" . "Evaluation context: 'repl' (default), 'hover', or 'watch'.")))))
      ("required" . ["expression"]))
    (lambda (args &optional callback)
      (let ((expr (kargu-aget args "expression")))
        (if (or (null expr) (string-empty-p expr))
            (kargu-dape--deliver callback "ERROR: expression is required" nil)
          (kargu-dape-eval-expression expr (kargu-aget args "context") callback)))))
   (list
    "debug_list_breakpoints"
    "List all source breakpoints (file and line) known to the debugger."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args) (kargu-dape-list-breakpoints)))
   (list
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
   (list
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
   (list
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
   (list
    "debug_step_over"
    "Step to the next source line in current function (does not step into calls)."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args &optional callback) (kargu-dape-step-over callback)))
   (list
    "debug_step_in"
    "Step into the function call on the current line."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args &optional callback) (kargu-dape-step-in callback)))
   (list
    "debug_step_out"
    "Step out of current function back to caller."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args &optional callback) (kargu-dape-step-out callback)))
   (list
    "debug_continue"
    "Resume execution until next breakpoint or termination."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args &optional callback) (kargu-dape-continue callback)))
   (list
    "debug_pause"
    "Pause execution of running debuggee and return paused location, stack, and variables."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args &optional callback) (kargu-dape-pause callback)))
   (list
    "debug_up"
    "Select stack frame up towards caller. Optional count (default 1)."
    '(("type" . "object")
      ("properties" . (("count" . (("type" . "integer")
                                   ("description" . "Number of stack frames to navigate up (default 1)."))))))
    (lambda (args &optional callback)
      (kargu-dape-up (kargu--tool-arg args "count") callback)))
   (list
    "debug_down"
    "Select stack frame down towards callee. Optional count (default 1)."
    '(("type" . "object")
      ("properties" . (("count" . (("type" . "integer")
                                   ("description" . "Number of stack frames to navigate down (default 1)."))))))
    (lambda (args &optional callback)
      (kargu-dape-down (kargu--tool-arg args "count") callback)))
   (list
    "debug_threads"
    "List all threads reported by the active debugger adapter."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args &optional callback) (kargu-dape-threads callback)))
   (list
    "debug_stack"
    "List call stack frames for the current thread."
    '(("type" . "object")
      ("properties" . (("levels" . (("type" . "integer")
                                    ("description" . "Maximum frame depth to report (default 20)."))))))
    (lambda (args &optional callback)
      (kargu-dape-stack (kargu--tool-arg args "levels") callback)))
   (list
    "debug_modules"
    "List loaded modules and shared libraries in target process."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args) (kargu-dape-modules)))
   (list
    "debug_sources"
    "List known source files reported by the debug adapter."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args) (kargu-dape-sources)))
   (list
    "debug_scope"
    "Inspect scopes or expand child variables of a struct/vector by name."
    '(("type" . "object")
      ("properties" . (("variable_name" . (("type" . "string")
                                           ("description" . "Name of variable to expand child fields for (e.g. 'frame', 'landmarks_2d').")))
                       ("scope_index" . (("type" . "integer")
                                         ("description" . "Index of scope to list (0-based)."))))))
    (lambda (args &optional callback)
      (let ((var (kargu-aget args "variable_name"))
            (idx (kargu--tool-arg args "scope_index")))
        (kargu-dape-scope (or var idx) callback))))
   (list
    "debug_watch"
    "List or update watch expressions in Dape."
    '(("type" . "object")
      ("properties" . (("expression" . (("type" . "string")
                                        ("description" . "Expression to add or remove from watch list.")))
                       ("remove" . (("type" . "boolean")
                                    ("description" . "Set true to remove expression instead of adding."))))))
    (lambda (args &optional callback)
      (kargu-dape-watch (kargu-aget args "expression")
                        (kargu--tool-flag args "remove")
                        callback)))
   (list
    "debug_restart"
    "Restart the debugging session with current configuration."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args) (kargu-dape-restart)))
   (list
    "debug_kill"
    "Terminate the debuggee process."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args) (kargu-dape-kill)))
   (list
    "debug_disconnect"
    "Disconnect from the debug adapter."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args) (kargu-dape-disconnect)))
   (list
    "debug_quit"
    "Quit debug session and clean up dape buffers."
    '(("type" . "object")
      ("properties" . :json-empty-object))
    (lambda (_args) (kargu-dape-quit))))
  "Tool schemas and executors exposed by the DAPE adapter.")

(defconst kargu-dape--tool-aliases
  '(("debug" . "debug_start")
    ("next" . "debug_step_over")
    ("step_over" . "debug_step_over")
    ("continue" . "debug_continue")
    ("pause" . "debug_pause")
    ("step" . "debug_step_in")
    ("step_in" . "debug_step_in")
    ("out" . "debug_step_out")
    ("step_out" . "debug_step_out")
    ("finish" . "debug_step_out")
    ("up" . "debug_up")
    ("down" . "debug_down")
    ("threads" . "debug_threads")
    ("stack" . "debug_stack")
    ("modules" . "debug_modules")
    ("sources" . "debug_sources")
    ("breakpoints" . "debug_list_breakpoints")
    ("debug_breakpoints" . "debug_list_breakpoints")
    ("set_breakpoint" . "debug_set_breakpoint")
    ("clear_breakpoint" . "debug_clear_breakpoint")
    ("toggle_breakpoint" . "debug_toggle_breakpoint")
    ("scope" . "debug_scope")
    ("debug_variables" . "debug_scope")
    ("debug_inspect_variable" . "debug_scope")
    ("watch" . "debug_watch")
    ("eval" . "debug_eval")
    ("restart" . "debug_restart")
    ("kill" . "debug_kill")
    ("disconnect" . "debug_disconnect")
    ("quit" . "debug_quit"))
  "Aliases for the DAPE adapter tools.")

(defun kargu-dape-register-tools ()
  "Register the DAPE tools and their aliases."
  (kargu-register-tools kargu-dape--tool-specs kargu-dape--tool-aliases))

(kargu-dape-register-tools)

(provide 'kargu/tools/dape/register)

;;; register.el ends here
