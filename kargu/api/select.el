;;; kargu/api/select.el --- Interactive selection popups -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Interactive selection popups at point using Company-mode or completing-read.
;; Handles mode switching, provider selection, dynamic model picking, and reasoning effort.

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
(require 'kargu/state)
(require 'kargu/config/key)
(require 'kargu/api/catalog)

(declare-function company-mode "company")
(declare-function company-manual-begin "company")
(declare-function company-abort "company")
(declare-function kargu-chat-refresh-footer "kargu/chat/prompt")
(declare-function kargu-connected-providers "kargu/providers/registry")
(declare-function kargu-provider-env "kargu/providers/registry" (provider))
(declare-function kargu-set-provider "kargu/providers" (provider))
(declare-function kargu--config-providers "kargu/config")
(declare-function kargu-chat--goto-footer-field "kargu/chat/prompt")
(declare-function kargu-history-compact-threshold "kargu/history-compact")

(declare-function company--match-from-capf-face "company")

(defvar company-backends)
(defvar company-minimum-prefix-length)
(defvar company-idle-delay)
(defvar company-candidates)
(defvar kargu-chat-buffer-name)
(defvar kargu-chat--output-marker)

(defun kargu-api--fuzzy-filter (query candidates)
  "Filter and sort CANDIDATES matching QUERY using Emacs' built-in flex completion."
  (if (or (null query) (string-empty-p query))
      candidates
    (let* ((completion-styles '(flex basic partial-completion))
           (all (completion-all-completions query candidates nil (length query))))
      (when (consp all)
        (let (res)
          (while (consp (cdr all))
            (push (car all) res)
            (setq all (cdr all)))
          (when (stringp (car all))
            (push (car all) res))
          (nreverse res))))))

(defun kargu--completing-read-with-company (prompt candidates &optional default annotations)
  "Prompt for one of CANDIDATES using Company-mode with strict matching."
  (let* ((cand-strings (mapcar (lambda (c) (if (stringp c) c (format "%s" c))) candidates))
         (backend
          (lambda (command &optional arg &rest _ignored)
            (cl-case command
              (prefix
               (let ((text (minibuffer-contents-no-properties)))
                 (if (string-empty-p text) "" text)))
              (candidates
               (let ((prefix (or arg "")))
                 (kargu-api--fuzzy-filter prefix cand-strings)))
              (annotation
               (when (and arg annotations)
                 (or (cdr (assoc (substring-no-properties arg) annotations)) "")))
              (match
               (if (fboundp 'company--match-from-capf-face)
                   (company--match-from-capf-face arg)
                 0))
              (require-match t)
              (no-cache t)
              (sorted t)
              (duplicates nil)))))
    (minibuffer-with-setup-hook
        (lambda ()
          (setq-local completion-styles '(flex basic partial-completion))
          (when (featurep 'company)
            (setq-local company-backends (list backend))
            (setq-local company-minimum-prefix-length 0)
            (setq-local company-idle-delay 0.01)
            (company-mode 1)
            (run-at-time 0.05 nil
                         (lambda ()
                           (when (fboundp 'company-manual-begin)
                             (ignore-errors (company-manual-begin)))))))
      (completing-read prompt cand-strings nil t nil nil default))))

(defun kargu--company-prepare-field-region (field)
  "Locate FIELD in footer, clear button text, and return a start marker."
  (unless (and (fboundp 'kargu-chat--goto-footer-field)
               (kargu-chat--goto-footer-field field))
    (user-error "kargu: chat footer field not found: %s" field))
  (let* ((btn-start (1- (point)))
         (btn-end (save-excursion (search-forward "]" nil t))))
    (unless btn-end
      (user-error "kargu: button end delimiter not found"))
    (let ((inhibit-read-only t))
      (delete-region btn-start btn-end)
      (when (> btn-start (point-min))
        (put-text-property (1- btn-start) btn-start
                           'rear-nonsticky '(read-only field front-sticky face)))
      (when (< btn-start (point-max))
        (put-text-property btn-start (1+ btn-start)
                           'front-sticky nil)))
    (copy-marker (point) nil)))

(defun kargu--company-make-ephemeral-backend (cand-strings annotations start-marker)
  "Construct an ephemeral Company completion backend closure."
  (lambda (cmd &optional arg &rest _ignored)
    (cl-case cmd
      (prefix
       (when (and (markerp start-marker)
                  (marker-position start-marker)
                  (>= (point) (marker-position start-marker)))
         (buffer-substring-no-properties
          (marker-position start-marker) (point))))
      (candidates
       (let ((prefix (or arg "")))
         (kargu-api--fuzzy-filter prefix cand-strings)))
      (annotation
       (when (and arg annotations)
         (or (cdr (assoc (substring-no-properties arg) annotations)) "")))
      (match
       (if (fboundp 'company--match-from-capf-face)
           (company--match-from-capf-face arg)
         0))
      (require-match t)
      (sorted t)
      (duplicates nil)
      (post-completion nil)
      (otherwise nil))))

(defun kargu--company-bind-completion-hooks (callback on-cancel cleanup-fn)
  "Bind Company finish and cancel hooks with CLEANUP-FN and callbacks."
  (let* ((done nil)
         (finish-hook nil)
         (cancel-hook nil))
    (setq finish-hook
          (lambda (result)
            (remove-hook 'company-completion-finished-hook finish-hook t)
            (remove-hook 'company-completion-cancelled-hook cancel-hook t)
            (unless done
              (setq done t)
              (funcall cleanup-fn)
              (when (functionp callback)
                (let ((chosen result))
                  (if noninteractive
                      (funcall callback chosen)
                    (run-at-time 0 nil
                                 (lambda ()
                                   (with-current-buffer (or (get-buffer kargu-chat-buffer-name)
                                                            (current-buffer))
                                     (funcall callback chosen))))))))))
    (setq cancel-hook
          (lambda (&optional _aborted)
            (remove-hook 'company-completion-finished-hook finish-hook t)
            (remove-hook 'company-completion-cancelled-hook cancel-hook t)
            (unless done
              (setq done t)
              (funcall cleanup-fn)
              (if (functionp on-cancel)
                  (funcall on-cancel)
                (when (fboundp 'kargu-chat-refresh-footer)
                  (kargu-chat-refresh-footer))))))
    (add-hook 'company-completion-finished-hook finish-hook nil t)
    (add-hook 'company-completion-cancelled-hook cancel-hook nil t)
    (unless (ignore-errors (company-manual-begin))
      (funcall cancel-hook))))

(defun kargu--company-select-at-point (field candidates annotations callback &optional on-cancel)
  "Select a candidate from CANDIDATES at FIELD using in-buffer Company popup.
FIELD is \\='provider, \\='model, or \\='effort."
  (let ((cand-strings (mapcar (lambda (c) (if (stringp c) c (format "%s" c))) candidates))
        (chat-buf (or (and (markerp kargu-chat--output-marker)
                           (marker-position kargu-chat--output-marker)
                           (current-buffer))
                      (get-buffer kargu-chat-buffer-name))))
    (if (or noninteractive
            (not (featurep 'company))
            (not chat-buf))
        (let* ((prompt (format "kargu %s: " field))
               (res (kargu--completing-read-with-company
                     prompt cand-strings (car cand-strings) annotations)))
          (funcall callback res))
      (with-current-buffer chat-buf
        (let ((win (get-buffer-window (current-buffer))))
          (if win
              (select-window win)
            (pop-to-buffer (current-buffer))))
        (when (bound-and-true-p company-candidates)
          (ignore-errors (company-abort)))
        (let* ((start-marker (kargu--company-prepare-field-region field))
               (orig-backends (and (boundp 'company-backends) company-backends))
               (cleanup
                (lambda ()
                  (when (markerp start-marker)
                    (set-marker start-marker nil))
                  (setq-local company-backends (or orig-backends '(kargu-chat-company)))
                  (setq-local company-minimum-prefix-length 1)
                  (setq-local company-idle-delay 0.15)))
               (backend (kargu--company-make-ephemeral-backend
                         cand-strings annotations start-marker)))
          (setq-local company-backends (list backend))
          (setq-local company-minimum-prefix-length 0)
          (setq-local company-idle-delay 0.01)
          (company-mode 1)
          (kargu--company-bind-completion-hooks callback on-cancel cleanup))))))

(defun kargu-chat-select-mode-company (&optional _event)
  "Interactively select an execution mode using Company at point."
  (interactive (list last-input-event))
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "kargu: cannot change mode while agent is running or thinking (stop with C-c C-k first)"))
  (let* ((modes '("ask" "plan" "debug" "agent"))
         (annotations '(("ask" . "  [Read-only answers; no file edits]")
                        ("plan" . "  [Read-only architecture & implementation planning]")
                        ("debug" . "  [Debugging mode; uses dape and diagnostic tools]")
                        ("agent" . "  [Full agentic mode; can edit files and run commands]"))))
    (kargu--company-select-at-point
     'mode
     modes
     annotations
     (lambda (chosen)
       (unless (and (stringp chosen) (member chosen modes))
         (when (fboundp 'kargu-chat-refresh-footer)
           (kargu-chat-refresh-footer))
         (user-error "kargu: invalid mode selection: %s" chosen))
       (kargu-set-mode (intern chosen))))))

(defun kargu-chat-select-effort-company (&optional _event)
  "Interactively select reasoning effort using Company completion at point."
  (interactive (list last-input-event))
  (let* ((mid (kargu--model))
         (pname (kargu--provider-name))
         (supported (kargu-model-reasoning-efforts mid pname)))
    (if (null supported)
        (let ((efforts '("off"))
              (annotations '(("off" . " [reasoning not supported by this model]"))))
          (kargu--company-select-at-point
           'effort
           efforts
           annotations
           (lambda (_chosen)
             (setq kargu-reasoning-effort nil)
             (kargu-state-set-reasoning-effort nil)
             (when (fboundp 'kargu-chat-refresh-footer)
               (kargu-chat-refresh-footer))
             (force-mode-line-update t)
             (message "kargu: model '%s' does not support reasoning effort." mid))))
      (let* ((filtered (cl-remove-if (lambda (e) (member (downcase e) '("off" "none")))
                                     supported))
             (efforts (cons "off" filtered))
             (annotations (mapcar (lambda (e)
                                    (cons e (kargu--reasoning-effort-annotation e)))
                                  efforts)))
        (kargu--company-select-at-point
         'effort
         efforts
         annotations
         (lambda (chosen)
           (unless (and (stringp chosen) (member chosen efforts))
             (when (fboundp 'kargu-chat-refresh-footer)
               (kargu-chat-refresh-footer))
             (user-error "kargu: invalid reasoning effort: %s" chosen))
           (let ((eff (if (member (downcase chosen) '("off" "none")) nil (intern chosen))))
             (setq kargu-reasoning-effort eff)
             (kargu-state-set-reasoning-effort eff))
           (when (fboundp 'kargu-chat-refresh-footer)
             (kargu-chat-refresh-footer))
           (force-mode-line-update t)
           (message "kargu: reasoning effort set to '%s'." chosen)))))))

(defun kargu-chat--collect-model-candidates (pname-str live-ids catalog-ids)
  "Collect available model IDs for PNAME-STR from LIVE-IDS, cache, and CATALOG-IDS."
  (let* ((cached (and (null live-ids) (gethash pname-str kargu--live-models-cache)))
         (sync-models (and (null live-ids) (null cached)
                           (progn
                             (message "kargu: querying live model catalog from %s (%s)..."
                                      pname-str (kargu--api-base pname-str))
                             (kargu-api-fetch-models-sync pname-str))))
         (live (or live-ids cached sync-models))
         (catalog catalog-ids)
         (curr (kargu--model)))
    (delete-dups (delq nil (append (and live (copy-sequence live))
                                   (and catalog (copy-sequence catalog))
                                   (and (kargu--nonempty curr) (list curr)))))))

(defun kargu-chat--apply-chosen-model (chosen pname-str all-models)
  "Resolve and activate CHOSEN model for PNAME-STR among ALL-MODELS."
  (let* ((raw (and (stringp chosen) (string-trim (substring-no-properties chosen))))
         (resolved (cond
                    ((or (null raw) (string-empty-p raw)) nil)
                    ((member raw all-models) raw)
                    (t (let ((matches (kargu-api--fuzzy-filter raw all-models)))
                         (and matches (substring-no-properties (car matches))))))))
    (unless (and (stringp resolved) (member resolved all-models))
      (when (fboundp 'kargu-chat-refresh-footer)
        (kargu-chat-refresh-footer))
      (user-error "kargu: model '%s' is not in available template models" (or raw "")))
    (setq chosen resolved))
  (setq kargu--session-model chosen)
  (kargu-state-set-model chosen)
  (let* ((ctx (kargu-model-context-window chosen))
         (thresh (and (fboundp 'kargu-history-compact-threshold)
                      (kargu-history-compact-threshold)))
         (meta (kargu-model-get-metadata chosen))
         (desc (and meta (plist-get meta :description))))
    (when (fboundp 'kargu-chat-refresh-footer)
      (kargu-chat-refresh-footer))
    (force-mode-line-update t)
    (message "kargu: model '%s' selected (Context: %d tokens, Compaction Threshold: %d chars)%s"
             chosen ctx (or thresh 0) (if desc (format " · %s" desc) "")))
  (if (kargu-model-reasoning-efforts chosen pname-str)
      (if noninteractive
          (kargu-chat-select-effort-company)
        (run-at-time 0.05 nil #'kargu-chat-select-effort-company))
    (setq kargu-reasoning-effort nil)
    (kargu-state-set-reasoning-effort nil)
    (when (fboundp 'kargu-chat-refresh-footer)
      (kargu-chat-refresh-footer))
    (force-mode-line-update t)))

(defun kargu-chat-select-model-company (&optional live-ids catalog-ids provider-name _event)
  "Interactively select a model for PROVIDER-NAME using Company at point."
  (interactive (list nil nil nil last-input-event))
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "kargu: cannot change model while agent is running or thinking (stop with C-c C-k first)"))
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname "default"))))
         (curr (kargu--model))
         (all-models (kargu-chat--collect-model-candidates pname-str live-ids catalog-ids)))
    (if (null all-models)
        (let ((chosen (read-string (format "kargu model for %s: " pname-str) (or curr ""))))
          (when (and (stringp chosen) (not (string-empty-p chosen)))
            (setq kargu--session-model chosen)
            (kargu-state-set-model chosen)
            (when (fboundp 'kargu-chat-refresh-footer)
              (kargu-chat-refresh-footer))
            (force-mode-line-update t)
            (message "kargu: model set to '%s'" chosen)
            chosen))
      (let ((annotations
             (mapcar (lambda (m)
                       (cons m (kargu-model-annotation-string m pname-str)))
                     all-models)))
        (kargu--company-select-at-point
         'model
         all-models
         annotations
         (lambda (chosen)
           (kargu-chat--apply-chosen-model chosen pname-str all-models)))))))

(defun kargu-chat-select-provider-company (&optional _event)
  "Interactively select an authenticated provider using Company at point."
  (interactive (list last-input-event))
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "kargu: cannot change provider while agent is running or thinking (stop with C-c C-k first)"))
  (let* ((all-connected (kargu-connected-providers))
         (cfg-list (and (fboundp 'kargu--config-providers)
                        (mapcar #'car (kargu--config-providers))))
         (cfg-connected (and cfg-list (cl-remove-if-not (lambda (p) (member p cfg-list)) all-connected)))
         (connected (or (and (not noninteractive) cfg-connected)
                        all-connected)))
    (unless connected
      (user-error "kargu: no providers with API keys found. Add keys with M-x kargu-edit-config"))
    (let ((annotations
           (mapcar (lambda (p)
                     (cons p (cond
                              ((member p '("ollama" "lmstudio" "llamacpp")) " [local]")
                              ((cl-some (lambda (v) (kargu--nonempty (getenv v)))
                                        (kargu-provider-env p))
                               " [env key]")
                              (t " [configured]"))))
                   connected)))
      (kargu--company-select-at-point
       'provider
       connected
       annotations
       (lambda (chosen)
         (unless (and (stringp chosen) (member chosen connected))
           (when (fboundp 'kargu-chat-refresh-footer)
             (kargu-chat-refresh-footer))
           (user-error "kargu: invalid provider selection: %s" chosen))
         (kargu-set-provider chosen)
         (kargu-state-set-provider (intern chosen))
         (when (fboundp 'kargu-chat-refresh-footer)
           (kargu-chat-refresh-footer))
         (if noninteractive
             (kargu-chat-select-model-company nil nil chosen)
           (run-at-time 0.05 nil
                        (lambda ()
                          (kargu-chat-select-model-company nil nil chosen)))))))))

(defun kargu-set-model (&optional refresh-or-model)
  "Set session model for the active provider.
If REFRESH-OR-MODEL is a string, set model to it directly.
If called interactively or with prefix, queries provider and prompts."
  (interactive "P")
  (if (and (stringp refresh-or-model) (not (string-empty-p refresh-or-model)))
      (progn
        (setq kargu--session-model refresh-or-model)
        (kargu-state-set-model refresh-or-model)
        (when (fboundp 'kargu-chat-refresh-footer)
          (kargu-chat-refresh-footer))
        (force-mode-line-update t)
        (message "kargu: model set to %s" refresh-or-model)
        refresh-or-model)
    (let ((pname (kargu--provider-name)))
      (kargu-chat-select-model-company nil nil pname))))

(defun kargu-switch-provider-and-model ()
  "Interactively switch provider, model, and reasoning effort."
  (interactive)
  (kargu-chat-select-provider-company))

(defun kargu-chat-select-provider ()
  "Select an active LLM provider, prioritizing authenticated providers."
  (interactive)
  (kargu-chat-select-provider-company))

(provide 'kargu/api/select)

;;; kargu/api/select.el ends here
