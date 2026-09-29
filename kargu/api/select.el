;;; kargu/api/select.el --- Footer Company selection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Pick a mode, provider, model, or reasoning effort inside the chat footer.
;; Company filters the API list with flex matching.  The confirmed value is
;; always an exact member of that list.  Batch and tests use `completing-read'.

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
(require 'kargu/state)
(require 'kargu/config/key)
(require 'kargu/api/catalog)

(declare-function company-mode "company" (&optional arg))
(declare-function company-manual-begin "company" ())
(declare-function company-abort "company" ())
(declare-function company--match-from-capf-face "company" (match))
(declare-function kargu-chat-refresh-footer "kargu/chat/prompt" ())
(declare-function kargu-connected-providers "kargu/providers/registry" ())
(declare-function kargu-provider-env "kargu/providers/registry" (provider))
(declare-function kargu-provider-local-p "kargu/providers/registry" (provider))
(declare-function kargu-set-provider "kargu/providers" (provider))
(declare-function kargu--config-providers "kargu/config" ())
(declare-function kargu-chat--goto-footer-field "kargu/chat/prompt" (field))
(declare-function kargu-chat--goto-prompt "kargu/chat/prompt" ())
(declare-function kargu-state-clear-model "kargu/state/transitions" ())
(declare-function kargu-history-compact-threshold "kargu/history-compact" ())
(declare-function kargu-chat-note-selection "kargu/chat/session" (&optional buffer))

(defvar company-backends)
(defvar company-minimum-prefix-length)
(defvar company-idle-delay)
(defvar company-candidates)
(defvar kargu-chat-buffer-name)
(defvar kargu-chat--output-marker)

;;;; List helpers ---------------------------------------------------------

(defun kargu-api--fuzzy-filter (query candidates)
  "Return CANDIDATES that flex-match QUERY, in completion order.
An empty QUERY returns CANDIDATES unchanged."
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

(defun kargu-api-select--strings (candidates)
  "Return CANDIDATES as a list of non-empty strings."
  (delq nil
        (mapcar (lambda (c)
                  (let ((s (if (stringp c) c (format "%s" c))))
                    (unless (string-empty-p s) s)))
                candidates)))

(defun kargu-api-select--plain (value)
  "Return VALUE without text properties, or nil when it is blank."
  (and (stringp value)
       (let ((s (string-trim (substring-no-properties value))))
         (unless (string-empty-p s) s))))

;;;; Company backend ------------------------------------------------------

(defun kargu-api-select--backend (candidates annotations start)
  "Company backend for CANDIDATES, annotated by ANNOTATIONS.
The prefix is the text from START to point.  `require-match' is t, so
Company only confirms a listed candidate.  Fuzzy matching only filters."
  (lambda (cmd &optional arg &rest _ignored)
    (cl-case cmd
      (prefix
       (when (and (markerp start)
                  (eq (marker-buffer start) (current-buffer))
                  (marker-position start)
                  (>= (point) (marker-position start)))
         (cons (buffer-substring-no-properties (marker-position start) (point))
               t)))
      (candidates
       (kargu-api--fuzzy-filter (or arg "") candidates))
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
      (no-cache t)
      (post-completion nil))))

(defun kargu-api-select--open-field (field)
  "Clear the footer FIELD between brackets and return a start marker.
Insertion at point is writable.  `inhibit-read-only' is not set locally."
  (unless (and (fboundp 'kargu-chat--goto-footer-field)
               (kargu-chat--goto-footer-field field))
    (user-error "kargu: chat footer field not found: %s" field))
  (let* ((inner-start (point))
         (inner-end (save-excursion
                      (if (search-forward "]" (line-end-position) t)
                          (1- (point))
                        (point)))))
    (let ((inhibit-read-only t))
      (when (> inner-end inner-start)
        (delete-region inner-start inner-end))
      (when (> inner-start (point-min))
        (put-text-property (1- inner-start) inner-start
                           'rear-nonsticky
                           '(read-only field front-sticky face mouse-face
                                       help-echo keymap action)))
      (when (< inner-start (point-max))
        (put-text-property inner-start (1+ inner-start) 'front-sticky nil)))
    (goto-char inner-start)
    (copy-marker inner-start nil)))

(defun kargu-api-select--cleanup (start)
  "Drop START, restore chat completion, and redraw the footer."
  (when (markerp start)
    (set-marker start nil))
  (setq-local company-backends '(kargu-chat-company))
  (setq-local company-minimum-prefix-length 1)
  (setq-local company-idle-delay 0.15)
  (when (fboundp 'kargu-chat-refresh-footer)
    (kargu-chat-refresh-footer)))

(defun kargu--completing-read-with-company (prompt candidates &optional default _annotations)
  "Read one of CANDIDATES for PROMPT.  `require-match' is t.
DEFAULT is the initial selection.  This is the batch reader; the
interactive UI is footer Company and does not use this function."
  (let* ((cand-strings (kargu-api-select--strings candidates))
         (def (or default (car cand-strings))))
    (completing-read prompt cand-strings nil t nil nil def)))

(defun kargu-api-select--accept (chosen candidates apply field)
  "Call APPLY with CHOSEN when it is an exact member of CANDIDATES."
  (let ((plain (kargu-api-select--plain chosen)))
    (if (member plain candidates)
        (funcall apply plain)
      (when (fboundp 'kargu-chat-refresh-footer)
        (kargu-chat-refresh-footer))
      (user-error "kargu: %s is not a valid %s" (or plain "") field))))

(defun kargu-api-select--continue (fn)
  "Run FN after the current selection returns.
Batch and minibuffer selection run FN immediately.  Footer Company
runs FN on a timer so the next list is not opened inside Company's
finished hook."
  (if (and (not noninteractive)
           (featurep 'company)
           (kargu-api-select--chat-buffer))
      (let ((buf (kargu-api-select--chat-buffer)))
        (run-with-timer
         0 nil
         (lambda ()
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (funcall fn))))))
    (funcall fn)))

(defun kargu-api-select--stay-on-field (field)
  "After a cancelled selection, leave point on footer FIELD."
  (when (fboundp 'kargu-chat--goto-footer-field)
    (kargu-chat--goto-footer-field field)))

(defun kargu-api-select--listen (start candidates apply field)
  "On Company finish, accept the candidate.  On cancel, stay on FIELD."
  (let ((done nil)
        (finish nil)
        (cancel nil))
    (setq finish
          (lambda (result)
            (unless done
              (setq done t)
              (remove-hook 'company-completion-finished-hook finish t)
              (remove-hook 'company-completion-cancelled-hook cancel t)
              (kargu-api-select--cleanup start)
              (kargu-api-select--accept result candidates apply field))))
    (setq cancel
          (lambda (&rest _)
            (unless done
              (setq done t)
              (remove-hook 'company-completion-finished-hook finish t)
              (remove-hook 'company-completion-cancelled-hook cancel t)
              (kargu-api-select--cleanup start)
              (kargu-api-select--stay-on-field field))))
    (add-hook 'company-completion-finished-hook finish nil t)
    (add-hook 'company-completion-cancelled-hook cancel nil t)
    (unless (ignore-errors (company-manual-begin))
      (funcall cancel))))

(defun kargu-api-select--chat-buffer ()
  "Return the live chat buffer, or nil."
  (or (and (markerp kargu-chat--output-marker)
           (marker-position kargu-chat--output-marker)
           (current-buffer))
      (get-buffer kargu-chat-buffer-name)))

(defun kargu-api-select--in-footer (field candidates annotations apply)
  "Start Company for CANDIDATES inside footer FIELD, then call APPLY."
  (let ((chat-buf (kargu-api-select--chat-buffer)))
    (unless chat-buf
      (user-error "kargu: chat buffer not found"))
    (with-current-buffer chat-buf
      (let ((win (get-buffer-window (current-buffer))))
        (if win (select-window win) (pop-to-buffer (current-buffer))))
      (when (bound-and-true-p company-candidates)
        (ignore-errors (company-abort)))
      (let ((start (kargu-api-select--open-field field)))
        (setq-local company-backends
                    (list (kargu-api-select--backend candidates annotations start)))
        (setq-local company-minimum-prefix-length 0)
        (setq-local company-idle-delay 0.01)
        (company-mode 1)
        (kargu-api-select--listen start candidates apply field)))))

(defun kargu-api-select (field candidates annotations apply)
  "Select one of CANDIDATES for footer FIELD and call APPLY with it.
ANNOTATIONS is an alist of (CANDIDATE . NOTE).  APPLY receives a string
that is a member of CANDIDATES.  Without a display, read in the minibuffer."
  (let ((cands (kargu-api-select--strings candidates)))
    (unless cands
      (user-error "kargu: no %s choices" field))
    (if (and (not noninteractive)
             (featurep 'company)
             (kargu-api-select--chat-buffer))
        (kargu-api-select--in-footer field cands annotations apply)
      (condition-case nil
          (kargu-api-select--accept
           (kargu--completing-read-with-company
            (format "kargu %s: " field) cands (car cands) annotations)
           cands apply field)
        (quit nil)))))

(defun kargu-api-select--guard ()
  "Signal an error when the agent is running or thinking."
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "kargu: cannot change this while the agent is running or thinking (stop with C-c C-k first)")))

;;;; Mode -----------------------------------------------------------------

(defconst kargu-api-select--modes '("ask" "plan" "debug" "agent")
  "Execution modes the footer can select.")

(defconst kargu-api-select--mode-notes
  '(("ask" . "  [Read-only answers; no file edits]")
    ("plan" . "  [Read-only architecture & implementation planning]")
    ("debug" . "  [Debugging mode; uses dape and diagnostic tools]")
    ("agent" . "  [Full agentic mode; can edit files and run commands]"))
  "Annotation alist for `kargu-api-select--modes'.")

(defun kargu-api-select--apply-mode (chosen)
  "Set the execution mode to CHOSEN."
  (kargu-set-mode (intern chosen))
  (message "kargu: mode set to '%s'." (upcase chosen)))

(defun kargu-chat-select-mode-company (&optional _event)
  "Select an execution mode with Company in the footer."
  (interactive (list last-input-event))
  (kargu-api-select--guard)
  (kargu-api-select 'mode kargu-api-select--modes kargu-api-select--mode-notes
                    #'kargu-api-select--apply-mode))

;;;; Reasoning effort -----------------------------------------------------

(defun kargu-api-select--effort-candidates (supported)
  "Return effort choices.  SUPPORTED is the model's API list, or nil.
\"off\" is the local choice that clears reasoning.  Names from the API,
including \"none\", stay in the list."
  (if (null supported)
      '("off")
    (cons "off"
          (delete-dups
           (delq nil
                 (mapcar (lambda (e)
                           (let ((s (and e (format "%s" e))))
                             (when (and (stringp s)
                                        (not (string-empty-p s))
                                        (not (equal (downcase s) "off")))
                               s)))
                         supported))))))

(defun kargu-api-select--apply-effort (chosen &optional note)
  "Set reasoning effort to CHOSEN.  \"off\" clears it.
NOTE replaces the confirmation message."
  (let ((eff (if (equal (downcase chosen) "off") nil (intern chosen))))
    (setq kargu-reasoning-effort eff)
    (kargu-state-set-reasoning-effort eff)
    (when (fboundp 'kargu-chat-refresh-footer)
      (kargu-chat-refresh-footer))
    (force-mode-line-update t)
    (message "%s"
             (or note
                 (format "kargu: reasoning effort set to '%s'."
                         (if eff chosen "off"))))
    (kargu-api-select--continue #'kargu-chat--goto-prompt)))

(defun kargu-chat-select-effort-company (&optional _event)
  "Select a reasoning effort with Company in the footer."
  (interactive (list last-input-event))
  (let* ((mid (kargu--model))
         (supported (kargu-model-reasoning-efforts mid (kargu--provider-name)))
         (efforts (kargu-api-select--effort-candidates supported))
         (note (unless supported
                 (format "kargu: model '%s' does not support reasoning effort."
                         (or mid "current")))))
    (kargu-api-select 'effort efforts nil
                      (lambda (chosen)
                        (kargu-api-select--apply-effort chosen note)))))

;;;; Model ----------------------------------------------------------------

(defun kargu-chat--collect-model-candidates (pname-str live-ids catalog-ids)
  "Collect model ids for PNAME-STR from LIVE-IDS, the cache, and CATALOG-IDS."
  (let* ((cached (and (null live-ids) (gethash pname-str kargu--live-models-cache)))
         (sync-models (and (null live-ids) (null cached)
                           (progn
                             (message "kargu: querying live model catalog from %s (%s)..."
                                      pname-str (kargu--api-base pname-str))
                             (kargu-api-fetch-models-sync pname-str))))
         (live (or live-ids cached sync-models))
         (curr (kargu--model)))
    (delete-dups
     (delq nil
           (append (and live (copy-sequence live))
                   (and catalog-ids (copy-sequence catalog-ids))
                   (and (kargu--nonempty curr) (list curr)))))))

(defun kargu-api-select--apply-model (chosen pname-str)
  "Activate model CHOSEN for PNAME-STR, then ask for effort when it exists."
  (setq kargu--session-model chosen)
  (kargu-state-set-model chosen)
  (when (fboundp 'kargu-chat-note-selection)
    (kargu-chat-note-selection))
  (let* ((ctx (kargu-model-context-window chosen))
         (thresh (and (fboundp 'kargu-history-compact-threshold)
                      (kargu-history-compact-threshold)))
         (desc (and (fboundp 'kargu-model-get-prop)
                    (kargu-model-get-prop chosen "description"))))
    (when (fboundp 'kargu-chat-refresh-footer)
      (kargu-chat-refresh-footer))
    (force-mode-line-update t)
    (message "kargu: model '%s' selected (Context: %s tokens, Compaction Threshold: %s chars)%s"
             chosen
             (if (numberp ctx) (format "%d" ctx) "unknown")
             (if (numberp thresh) (format "%d" thresh) "0")
             (if desc (format " · %s" desc) "")))
  (if (kargu-model-reasoning-efforts chosen pname-str)
      (kargu-api-select--continue #'kargu-chat-select-effort-company)
    (setq kargu-reasoning-effort nil)
    (kargu-state-set-reasoning-effort nil)
    (when (fboundp 'kargu-chat-refresh-footer)
      (kargu-chat-refresh-footer))
    (force-mode-line-update t)
    (kargu-api-select--continue #'kargu-chat--goto-prompt)))

(defun kargu-chat-select-model-company (&optional live-ids catalog-ids provider-name _event)
  "Select a model for PROVIDER-NAME with Company in the footer.
LIVE-IDS and CATALOG-IDS are optional id lists already fetched by the caller."
  (interactive (list nil nil nil last-input-event))
  (kargu-api-select--guard)
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname "default"))))
         (models (kargu-chat--collect-model-candidates pname-str live-ids catalog-ids)))
    (unless models
      (user-error "kargu: no models returned for %s" pname-str))
    (kargu-api-select
     'model models
     (mapcar (lambda (m) (cons m (kargu-model-annotation-string m pname-str)))
             models)
     (lambda (chosen) (kargu-api-select--apply-model chosen pname-str)))))

;;;; Provider -------------------------------------------------------------

(defun kargu-api-select--provider-candidates ()
  "Return authenticated provider ids the footer can select."
  (let* ((all (kargu-connected-providers))
         (cfg (and (fboundp 'kargu--config-providers)
                   (mapcar #'car (kargu--config-providers))))
         (in-config (and cfg (cl-remove-if-not (lambda (p) (member p cfg)) all))))
    (or (and (not noninteractive) in-config) all)))

(defun kargu-api-select--provider-note (provider)
  "Return the Company note for PROVIDER."
  (cond
   ((and (fboundp 'kargu-provider-local-p) (kargu-provider-local-p provider))
    " [local]")
   ((and (fboundp 'kargu-provider-env)
         (cl-some (lambda (v) (kargu--nonempty (getenv v)))
                  (kargu-provider-env provider)))
    " [env key]")
   (t " [configured]")))

(defun kargu-api-select--apply-provider (chosen)
  "Switch to provider CHOSEN, then select one of its models.
The model stays empty until that next list confirms one."
  (kargu-set-provider chosen)
  (setq kargu--session-model nil)
  (when (fboundp 'kargu-state-clear-model)
    (kargu-state-clear-model))
  (when (fboundp 'kargu-chat-note-selection)
    (kargu-chat-note-selection))
  (when (fboundp 'kargu-chat-refresh-footer)
    (kargu-chat-refresh-footer))
  (kargu-api-select--continue
   (lambda ()
     (kargu-chat-select-model-company nil nil chosen))))

(defun kargu-chat-select-provider-company (&optional _event)
  "Select an authenticated provider with Company in the footer."
  (interactive (list last-input-event))
  (kargu-api-select--guard)
  (let ((providers (kargu-api-select--provider-candidates)))
    (unless providers
      (user-error "kargu: no providers with API keys found. Add keys with M-x kargu-edit-config"))
    (kargu-api-select
     'provider providers
     (mapcar (lambda (p) (cons p (kargu-api-select--provider-note p))) providers)
     #'kargu-api-select--apply-provider)))

;;;; Public commands ------------------------------------------------------

(defun kargu-set-model (&optional refresh-or-model)
  "Set the session model for the active provider.
A string REFRESH-OR-MODEL is stored directly.  An interactive call
asks with the footer Company list."
  (interactive "P")
  (if (and (stringp refresh-or-model) (not (string-empty-p refresh-or-model)))
      (progn
        (setq kargu--session-model refresh-or-model)
        (kargu-state-set-model refresh-or-model)
        (when (fboundp 'kargu-chat-note-selection)
          (kargu-chat-note-selection))
        (when (fboundp 'kargu-chat-refresh-footer)
          (kargu-chat-refresh-footer))
        (force-mode-line-update t)
        (message "kargu: model set to %s" refresh-or-model)
        refresh-or-model)
    (kargu-chat-select-model-company nil nil (kargu--provider-name))))

(defun kargu-switch-provider-and-model ()
  "Switch provider, then model, then reasoning effort."
  (interactive)
  (kargu-chat-select-provider-company))

(defun kargu-chat-select-provider ()
  "Select an authenticated provider, then one of its models."
  (interactive)
  (kargu-chat-select-provider-company))

(provide 'kargu/api/select)

;;; kargu/api/select.el ends here
