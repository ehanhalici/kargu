;;; kargu/chat/tune.el --- Transient menu for model and session parameters -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Transient modal interface for tuning LLM parameters (context length,
;; reasoning/thinking effort, thinking budget, temperature, streaming,
;; and review mode) and selecting connected providers and live models.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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
(require 'kargu/config)
(require 'kargu/api)
(require 'kargu/providers)
(require 'kargu/chat/tune-params)

(eval-and-compile
  (require 'transient nil t))

(declare-function kargu-test-connection "kargu/api")
(declare-function kargu-chat-select-provider "kargu/api")
(declare-function kargu-set-model "kargu/api")

;;;; Dynamic descriptions for transient -----------------------------------

(defun kargu-tune--provider-desc ()
  "Formatted description for active provider."
  (let* ((p (kargu--provider-name))
         (auth (kargu-provider-authenticated-p p)))
    (format "Provider: %s %s"
            (propertize p 'face 'bold)
            (if auth
                (propertize "[ready]" 'face 'font-lock-doc-face)
              (propertize "[no key]" 'face 'font-lock-warning-face)))))

(defun kargu-tune--model-desc ()
  "Formatted description for active model."
  (format "Model:    %s" (propertize (kargu--model) 'face 'bold)))

(defun kargu-tune--temperature-desc ()
  "Formatted description for temperature."
  (format "Temperature:     %s"
          (propertize (if kargu-temperature
                          (format "%.2f" kargu-temperature)
                        "nil (omit)")
                      'face 'bold)))

(defun kargu-tune--max-tokens-desc ()
  "Formatted description for max tokens / context length."
  (format "Max Tokens (ctx): %s"
          (propertize (if kargu-max-tokens
                          (format "%d" kargu-max-tokens)
                        "nil (provider default)")
                      'face 'bold)))

(defun kargu-tune--reasoning-effort-desc ()
  "Formatted description for thinking / reasoning effort."
  (format "Thinking Effort:  %s"
          (if kargu-reasoning-effort
              (propertize (upcase (format "%s" kargu-reasoning-effort))
                          'face 'font-lock-keyword-face)
            (propertize "OFF" 'face 'font-lock-comment-face))))

(defun kargu-tune--thinking-budget-desc ()
  "Formatted description for thinking token budget."
  (format "Thinking Budget:  %s"
          (propertize (if kargu-thinking-budget
                          (format "%d tokens" kargu-thinking-budget)
                        "nil (default)")
                      'face 'bold)))

(defun kargu-tune--stream-desc ()
  "Formatted description for streaming toggle."
  (format "Streaming (SSE):  %s"
          (if kargu-stream
              (propertize "ON" 'face 'font-lock-doc-face)
            (propertize "OFF" 'face 'font-lock-comment-face))))

(defun kargu-tune--review-mode-desc ()
  "Formatted description for diff review mode."
  (format "Review Mode:      %s"
          (propertize (format "%s" (if (boundp 'kargu-diff-review-mode)
                                       kargu-diff-review-mode
                                     'auto))
                      'face 'bold)))

;;;; Interactive setters --------------------------------------------------

(defun kargu-tune-set-temperature ()
  "Prompt for sampling temperature (0.0 to 2.0 or nil)."
  (interactive)
  (let* ((input (completing-read
                 "Temperature (0.0=deterministic, 0.2=code, 0.7=creative, nil=omit): "
                 '("0.0" "0.2" "0.5" "0.7" "1.0" "nil")
                 nil nil nil nil
                 (if kargu-temperature (format "%.2f" kargu-temperature) "nil")))
         (val (string-trim input)))
    (setq kargu-temperature
          (if (or (string-empty-p val) (equal val "nil"))
              nil
            (string-to-number val)))
    (message "kargu temperature set to: %S" kargu-temperature)))

(defun kargu-tune-set-max-tokens ()
  "Prompt for maximum completion tokens limit."
  (interactive)
  (let* ((input (completing-read
                 "Max completion tokens (context limit, nil=provider default): "
                 '("1024" "2048" "4096" "8192" "16384" "32768" "65536" "nil")
                 nil nil nil nil
                 (if kargu-max-tokens (number-to-string kargu-max-tokens) "nil")))
         (val (string-trim input)))
    (setq kargu-max-tokens
          (if (or (string-empty-p val) (equal val "nil"))
              nil
            (string-to-number val)))
    (message "kargu max-tokens set to: %S" kargu-max-tokens)))

(declare-function kargu-model-reasoning-efforts "kargu/api")
(declare-function kargu-chat-refresh-footer "kargu/chat/prompt")

(defun kargu-tune-cycle-reasoning-effort ()
  "Cycle reasoning / thinking effort level for the active model."
  (interactive)
  (let* ((supported (if (fboundp 'kargu-model-reasoning-efforts)
                        (kargu-model-reasoning-efforts)
                      '("low" "medium" "high")))
         (levels (mapcar #'intern
                         (cl-remove-if (lambda (e) (member (downcase e) '("off" "none")))
                                       (or supported '("low" "medium" "high"))))))
    (if (null levels)
        (progn
          (setq kargu-reasoning-effort nil)
          (when (fboundp 'kargu-chat-refresh-footer)
            (kargu-chat-refresh-footer))
          (force-mode-line-update t)
          (message "kargu thinking effort: OFF (reasoning effort is not supported by this model)"))
      (let* ((curr (and (boundp 'kargu-reasoning-effort) kargu-reasoning-effort))
             (next (cond
                    ((null curr) (car levels))
                    ((member curr levels)
                     (let ((tail (cdr (member curr levels))))
                       (if tail (car tail) nil)))
                    (t (car levels)))))
        (setq kargu-reasoning-effort next)
        (when (fboundp 'kargu-chat-refresh-footer)
          (kargu-chat-refresh-footer))
        (force-mode-line-update t)
        (message "kargu thinking effort: %s"
                 (if kargu-reasoning-effort
                     (upcase (symbol-name kargu-reasoning-effort))
                   "OFF"))))))

(defun kargu-tune-set-thinking-budget ()
  "Prompt for thinking token budget limit."
  (interactive)
  (let* ((input (completing-read
                 "Thinking token budget (nil=default): "
                 '("1024" "2048" "4096" "8192" "16384" "32768" "nil")
                 nil nil nil nil
                 (if kargu-thinking-budget (number-to-string kargu-thinking-budget) "nil")))
         (val (string-trim input)))
    (setq kargu-thinking-budget
          (if (or (string-empty-p val) (equal val "nil"))
              nil
            (string-to-number val)))
    (message "kargu thinking budget set to: %S" kargu-thinking-budget)))

(defun kargu-tune-toggle-stream ()
  "Toggle SSE streaming on or off."
  (interactive)
  (setq kargu-stream (not kargu-stream))
  (message "kargu streaming: %s" (if kargu-stream "ON" "OFF")))

(defun kargu-tune-toggle-review-mode ()
  "Toggle diff review mode between auto and blocking."
  (interactive)
  (when (boundp 'kargu-diff-review-mode)
    (setq kargu-diff-review-mode
          (if (eq kargu-diff-review-mode 'auto) 'blocking 'auto))
    (message "kargu review mode: %s" kargu-diff-review-mode)))

(defun kargu-tune-reset-defaults ()
  "Reset model and session tuning parameters to defaults."
  (interactive)
  (setq kargu-temperature 0.2
        kargu-max-tokens nil
        kargu-reasoning-effort nil
        kargu-thinking-budget nil
        kargu-stream t)
  (message "kargu tuning parameters reset to defaults"))

;;;; Transient Prefix Definition ------------------------------------------

(when (fboundp 'transient-define-prefix)

  (transient-define-prefix kargu-tune-menu ()
    "Transient control panel for LLM provider, live models, and parameters."
    [:description "Provider & Live Models"
     ("p" kargu-chat-select-provider :description kargu-tune--provider-desc :transient t)
     ("m" kargu-set-model :description kargu-tune--model-desc :transient t)
     ("f" "Fetch / Refresh live models from provider"
      (lambda () (interactive) (kargu-set-model t)) :transient t)]
    [:description "Model Parameters"
     ("t" kargu-tune-set-temperature :description kargu-tune--temperature-desc :transient t)
     ("c" kargu-tune-set-max-tokens :description kargu-tune--max-tokens-desc :transient t)
     ("e" kargu-tune-cycle-reasoning-effort :description kargu-tune--reasoning-effort-desc :transient t)
     ("b" kargu-tune-set-thinking-budget :description kargu-tune--thinking-budget-desc :transient t)
     (">" kargu-tune-provider-params-menu :description kargu-tune--provider-params-summary-desc)]
    [:description "Session Flags & Toggles"
     ("s" kargu-tune-toggle-stream :description kargu-tune--stream-desc :transient t)
     ("r" kargu-tune-toggle-review-mode :description kargu-tune--review-mode-desc :transient t)]
    [:description "Actions"
     ("T" "Test Connection (Ping active provider)" kargu-test-connection :transient t)
     ("R" "Reset parameters to defaults" kargu-tune-reset-defaults :transient t)
     ("q" "Quit menu" transient-quit-one)]))

(provide 'kargu/chat/tune)

;;; tune.el ends here
