;;; selection.el --- Owned provider, model and effort transitions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The native application publishes one immutable selection per session.
;; Configuration remains a fallback, not another writable selection store.

;;; Code:

(require 'gv)
(require 'kargu/core/session)
(require 'kargu/contract/selection)
(require 'kargu/state/hooks)

(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-busy-p "kargu/api/http" ())

(defun kargu-selection-context (&optional session)
  "Return SESSION's immutable selection, defaulting to the current owner."
  (let ((session (or session (kargu-session-context))))
    (kargu-contract-assert #'kargu-session-p session)
    (kargu-session-selection-value session)))

(defun kargu-selection-provider (&optional session)
  "Return SESSION's explicit provider string, or nil without a choice."
  (kargu-selection-provider-value (kargu-selection-context session)))

(defun kargu-selection-model (&optional session)
  "Return SESSION's explicit model string, or nil without a choice."
  (kargu-selection-model-value (kargu-selection-context session)))

(defun kargu-selection-effort (&optional session)
  "Return SESSION's effective effort, respecting explicit reasoning-off."
  (let ((value (kargu-selection-effort-value (kargu-selection-context session))))
    (if (eq value kargu-selection-default-effort) kargu-reasoning-effort value)))

(defun kargu-selection-require-idle ()
  "Reject a selection update while application work owns its settings."
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "Kargu: stop active work before changing its selection")))

(defun kargu-selection--admit-owner (session)
  "Reject SESSION if work is active or the current boundary owner changed."
  (kargu-selection-require-idle)
  (unless (eq session (kargu-session-context))
    (user-error "Kargu: selection owner changed; reopen the selector")))

(defun kargu-selection--notify (session before after)
  "Publish SESSION's changed fields from BEFORE to AFTER, stopping if replaced."
  (let ((origin (current-buffer)))
    (dolist (field '(:provider :model :reasoning-effort))
      (when (and (buffer-live-p origin) (eq session (kargu-session-context origin))
                 (eq after (kargu-selection-context session)))
        (let* ((getter (pcase field
                         (:provider #'kargu-selection-provider-value)
                         (:model #'kargu-selection-model-value)
                         (_ #'kargu-selection-effort-value)))
               (old (funcall getter before)) (new (funcall getter after)))
          (unless (equal old new)
            (kargu-state-notify
             field (pcase field
                     (:provider (and new (intern new)))
                     (:reasoning-effort (kargu-selection-effort session))
                     (_ new)))))))))

(cl-defun kargu-selection-update
    (&key (provider nil provider-p) (model nil model-p) (effort nil effort-p) session)
  "Commit supplied PROVIDER, MODEL and EFFORT together to SESSION.
Unspecified fields retain their values.  Validate before mutation; listeners
see the entire committed selection, never half of a provider/model change.
Return its immutable receipt only while still current after notification."
  (let* ((origin (current-buffer))
         (session (or session (kargu-session-context)))
         (before (kargu-selection-context session))
         (after (kargu-selection-create
                 :provider (if provider-p provider (kargu-selection-provider-value before))
                 :model (if model-p model (kargu-selection-model-value before))
                 :effort (if effort-p effort (kargu-selection-effort-value before)))))
    (kargu-selection--admit-owner session)
    (setf (kargu-session-selection-value session) after)
    (kargu-selection--notify session before after)
    (when (and (buffer-live-p origin) (eq session (kargu-session-context origin))
               (eq after (kargu-selection-context session)))
      after)))

(defun kargu-selection-publish (session before)
  "Publish SESSION's already committed selection relative to BEFORE.
This is the notification half of a coordinated session/view transaction."
  (kargu-contract-assert #'kargu-session-p session)
  (kargu-contract-assert #'kargu-selection-p before)
  (when (eq session (kargu-session-context))
    (kargu-selection--notify session before (kargu-selection-context session))))

(defun kargu-selection-reset (&optional session)
  "Clear SESSION's choices during an admitted reset; default to current owner."
  (let ((session (or session (kargu-session-context))))
    (kargu-contract-assert #'kargu-session-p session)
    (kargu-selection--admit-owner session)
    (setf (kargu-session-selection-value session) (kargu-selection-create))))

(gv-define-setter kargu-selection-provider (value &optional session)
  `(kargu-selection-update :provider ,value :session ,session))
(gv-define-setter kargu-selection-model (value &optional session)
  `(kargu-selection-update :model ,value :session ,session))
(gv-define-setter kargu-selection-effort (value &optional session)
  `(kargu-selection-update :effort ,value :session ,session))

(provide 'kargu/selection)
;;; selection.el ends here
