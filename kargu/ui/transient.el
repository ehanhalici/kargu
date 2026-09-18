;;; kargu/ui/transient.el --- Transient menu definitions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Transient menu control panel for Kargu.

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
(require 'kargu/chat)
(require 'kargu/api)
(require 'kargu/tools/lsp)
(require 'kargu/tools/dape)
(require 'kargu/tools/diff)
(require 'kargu/loop)
(eval-and-compile
  (require 'transient nil t))

(declare-function kargu-menu "kargu/ui/transient")
(declare-function kargu-chat-show "kargu/chat")
(declare-function kargu-chat-toggle "kargu/chat")
(declare-function kargu-chat-send "kargu/chat")
(declare-function kargu-chat-reset "kargu/chat")
(declare-function kargu-tune-menu "kargu/chat/tune")

(defun kargu-ui--show-text (name text)
  "Pop to a read-only buffer *kargu-NAME* showing TEXT."
  (let ((buffer (get-buffer-create (format "*kargu-%s*" name))))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or text ""))
        (goto-char (point-min))))
    (pop-to-buffer buffer))
  text)

(defun kargu-ui--report (text)
  "Show TEXT in the echo area, or in a buffer when it is multiline."
  (if (and (stringp text) (null (string-search "\n" text)))
      (message "%s" text)
    (kargu-ui--show-text "report" text))
  text)

(defun kargu-ui--dispatch (command)
  "Run the interactive COMMAND when its module is loaded."
  (if (fboundp command)
      (call-interactively command)
    (message "kargu: `%s' is unavailable (its module is not loaded)" command)))

(defun kargu-ui-open-skeleton ()
  "Build and show the zero-token LSP project skeleton index."
  (interactive)
  (kargu-ui--dispatch 'kargu-lsp-build-skeleton))

(defun kargu-ui-find-symbol ()
  "Find the definition sites of a workspace symbol."
  (interactive)
  (kargu-ui--dispatch 'kargu-lsp-find-definition))

(defun kargu-ui-diagnostics ()
  "Show LSP diagnostics for a file."
  (interactive)
  (kargu-ui--dispatch 'kargu-lsp-get-diagnostics))

(defun kargu-ui-set-context ()
  "Set the context buffer used to route LSP requests."
  (interactive)
  (kargu-ui--dispatch 'kargu-set-context-buffer))

(defun kargu-ui-debug-context ()
  "Show the live debug context (dape: stack, scopes, variables)."
  (interactive)
  (if (fboundp 'kargu-dape-get-context)
      (let ((text (kargu-dape-get-context)))
        (if (and (stringp text) (string-prefix-p "ERROR:" text))
            (message "%s" text)
          (kargu-ui--show-text "debug-context" text)))
    (message "kargu: dape module not loaded (debug tools unavailable)")))

(defun kargu-ui-debug-eval (expr)
  "Evaluate EXPR in the paused debug session (dape) and show the result."
  (interactive "skargu debug expression: ")
  (if (fboundp 'kargu-dape-eval-expression)
      (kargu-ui--report (kargu-dape-eval-expression expr))
    (message "kargu: dape module not loaded (debug tools unavailable)")))

(defun kargu-ui-breakpoints ()
  "List all source breakpoints known to dape."
  (interactive)
  (if (fboundp 'kargu-dape-list-breakpoints)
      (kargu-ui--report (kargu-dape-list-breakpoints))
    (message "kargu: dape module not loaded (debug tools unavailable)")))

(defun kargu-ui-rollback ()
  "Roll a file back to its initial state before agent edits in this series."
  (interactive)
  (kargu-ui--dispatch 'kargu-diff-rollback))

(defun kargu-ui-rollback-all ()
  "Roll all modified files back to their initial states."
  (interactive)
  (kargu-ui--dispatch 'kargu-diff-rollback-all))

(defun kargu-ui-review-diff ()
  "Review changes in ediff against the pre-agent snapshot."
  (interactive)
  (kargu-ui--dispatch 'kargu-diff-review))

(declare-function kargu-tune-toggle-review-mode "kargu/chat/tune" ())
(defalias 'kargu-ui-toggle-review-mode #'kargu-tune-toggle-review-mode)

(defun kargu-ui-snapshots ()
  "List files that currently have rollback snapshots."
  (interactive)
  (kargu-ui--dispatch 'kargu-diff-list-snapshots))

(defun kargu-ui-pending-reviews ()
  "List agent edits still awaiting their ediff review."
  (interactive)
  (kargu-ui--dispatch 'kargu-diff-pending-reviews))

(defun kargu-ui-choose-model ()
  "Pick the model for the active provider."
  (interactive)
  (kargu-ui--dispatch 'kargu-set-model))

(defun kargu-ui-choose-provider ()
  "Pick the active TOML provider."
  (interactive)
  (kargu-ui--dispatch 'kargu-set-provider))

(defun kargu-ui-test-connection ()
  "Ping the active provider with a minimal request."
  (interactive)
  (kargu-ui--dispatch 'kargu-test-connection))

(defun kargu-ui-stop ()
  "Stop the agent run in progress."
  (interactive)
  (kargu-ui--dispatch 'kargu-loop-stop))

(defun kargu-ui-status ()
  "Report the agent loop status (iterations, healing, request)."
  (interactive)
  (kargu-ui--dispatch 'kargu-loop-status))

(defun kargu-ui-history ()
  "Dump the protocol view of the history into the log buffer."
  (interactive)
  (kargu-ui--dispatch 'kargu-history-inspect)
  (kargu-show-log))

(when (fboundp 'transient-define-prefix)

  (defun kargu-menu--ask ()
    "Switch kargu to ask mode and keep the menu open."
    (interactive)
    (kargu-set-mode 'ask)
    (message "kargu mode: ask (read-only answers)")
    (call-interactively #'kargu-menu))

  (defun kargu-menu--plan ()
    "Switch kargu to plan mode and keep the menu open."
    (interactive)
    (kargu-set-mode 'plan)
    (message "kargu mode: plan (implementation plan, no edits)")
    (call-interactively #'kargu-menu))

  (defun kargu-menu--debug ()
    "Switch kargu to debug mode and keep the menu open."
    (interactive)
    (kargu-set-mode 'debug)
    (message "kargu mode: debug (live dape context, no edits)")
    (call-interactively #'kargu-menu))

  (defun kargu-menu--agent ()
    "Switch kargu to agent mode and keep the menu open."
    (interactive)
    (kargu-set-mode 'agent)
    (message "kargu mode: agent (autonomous, ediff-confirmed edits)")
    (call-interactively #'kargu-menu))

  (transient-define-prefix kargu-menu ()
    "kargu control panel.

The mode keys (a, p, d, x) switch `kargu-active-mode'
and keep this menu open; the choice applies from the next request
on.  Every other key performs one action and closes the menu.
The chat sidebar (c) is where agent runs stream their output."
    ["Mode"
     ("a" "ask: read-only answers" kargu-menu--ask)
     ("p" "plan: implementation plan, no edits" kargu-menu--plan)
     ("d" "debug: live dape context, no edits" kargu-menu--debug)
     ("x" "agent: autonomous, ediff-confirmed edits" kargu-menu--agent)]
    ["Chat & run"
     ("c" "chat sidebar" kargu-chat-toggle)
     ("s" "send prompt (C-c C-c in chat)" kargu-chat-send)
     ("S" "stop the running agent" kargu-ui-stop)
     ("t" "run status" kargu-ui-status)]
    ["Project context"
     ("i" "LSP project skeleton (zero-token index)" kargu-ui-open-skeleton)
     ("f" "find symbol definition" kargu-ui-find-symbol)
     ("g" "diagnostics for a file" kargu-ui-diagnostics)
     ("C" "set context buffer" kargu-ui-set-context)]
    ["Debugger"
     ("v" "live debug context" kargu-ui-debug-context)
     ("e" "evaluate in debuggee" kargu-ui-debug-eval)
     ("B" "breakpoints" kargu-ui-breakpoints)]
    ["Edits & review"
     ("D" "review changes (ediff)" kargu-ui-review-diff)
     ("r" "roll back a file" kargu-ui-rollback)
     ("l" "rollback snapshots" kargu-ui-snapshots)
     ("M" "toggle review mode (auto/blocking)" kargu-ui-toggle-review-mode)
     ("R" "pending ediff reviews" kargu-ui-pending-reviews)]
    ["Session & setup"
     ("O" "tune model & parameters" kargu-tune-menu)
     ("m" "choose model" kargu-ui-choose-model)
     ("P" "choose provider" kargu-ui-choose-provider)
     ("o" "edit local TOML config" kargu-edit-config)
     ("k" "check setup" kargu-check-setup)
     ("T" "test connection" kargu-ui-test-connection)
     ("u" "session usage" kargu-session-usage)
     ("z" "reset session" kargu-chat-reset)
     ("L" "log buffer" kargu-show-log)
     ("W" "wire log (full I/O)" kargu-toggle-wire-log)
     ("H" "protocol history" kargu-ui-history)])

  (kargu-log 'info "ui module loaded (menu)"))

(provide 'kargu/ui/transient)

;;; kargu/ui/transient.el ends here
