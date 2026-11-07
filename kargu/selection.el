;;; selection.el --- Owned provider, model and effort transitions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Rust commits one immutable selection per native conversation.  This
;; module validates and queues intents, then publishes only acknowledgements.
;; Configuration remains a fallback, not another writable selection store.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gv)
(require 'kargu/core/session)
(require 'kargu/application/coordinator)
(require 'kargu/models/service)
(require 'kargu/contract/selection)
(require 'kargu/state/hooks)

(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-busy-p "kargu/api/http" ())
(declare-function kargu-connected-providers "kargu/providers/registry" ())
(declare-function kargu--config-providers "kargu/config/schema" ())
(declare-function kargu-bridge-selection-commit "kargu/bridge/selection" (session desired callback))

(defvar kargu--live-models-cache)

(defconst kargu-selection-modes '("ask" "plan" "debug" "agent")
  "Canonical execution mode names selectable by sessions.")

(defvar kargu-selection-busy-predicate #'kargu-application-work-active-p
  "Zero-arg predicate returning non-nil when active work owns selection.")

(defun kargu-selection-busy-p ()
  "Return non-nil when application work currently locks the selection."
  (if (functionp kargu-selection-busy-predicate)
      (funcall kargu-selection-busy-predicate)
    (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
        (and (fboundp 'kargu-busy-p) (kargu-busy-p)))))

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
  (when (kargu-selection-busy-p)
    (user-error "Kargu: stop active work before changing its selection")))

(defun kargu-selection-normalize-candidates (candidates)
  "Return CANDIDATES as a list of non-empty strings."
  (delq nil
        (mapcar (lambda (c)
                  (let ((s (if (stringp c) c (format "%s" c))))
                    (unless (string-empty-p s) s)))
                candidates)))

(defun kargu-selection-plain-choice (value)
  "Return VALUE without text properties, or nil when it is blank."
  (and (stringp value)
       (let ((s (string-trim (substring-no-properties value))))
         (unless (string-empty-p s) s))))

(defun kargu-selection-validate-member (chosen candidates field)
  "Return plain CHOSEN when it is a member of CANDIDATES for FIELD, or signal."
  (let ((plain (kargu-selection-plain-choice chosen)))
    (if (member plain candidates)
        plain
      (user-error "Kargu: %s is not a valid %s" (or plain "") field))))

(defun kargu-selection-effort-candidates (supported)
  "Return effort choices from API SUPPORTED list, always starting with \"off\"."
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

(defun kargu-selection-models-known-p (pname-str &optional live-ids cache-table)
  "Return non-nil if LIVE-IDS or PNAME-STR in CACHE-TABLE is known."
  (let ((table (or cache-table (and (boundp 'kargu--live-models-cache)
                                    (kargu-metadata-table :catalog kargu--live-models-cache)))))
    (or live-ids
        (and (hash-table-p table)
             (not (eq (gethash pname-str table :unknown) :unknown))))))

(defun kargu-selection-model-candidates (pname-str &optional live-ids catalog-ids cache-table)
  "Return model IDs for PNAME-STR from CACHE-TABLE, LIVE-IDS or CATALOG-IDS."
  (let* ((table (or cache-table (and (boundp 'kargu--live-models-cache)
                                     (kargu-metadata-table :catalog kargu--live-models-cache))))
         (cached (if (hash-table-p table)
                     (gethash pname-str table :unknown)
                   :unknown))
         (models (if (eq cached :unknown) (or live-ids catalog-ids) cached)))
    (delete-dups (copy-sequence models))))

(defun kargu-selection-provider-candidates (&optional interactive-p)
  "Return authenticated providers, or configured ones when INTERACTIVE-P."
  (let* ((all (and (fboundp 'kargu-connected-providers)
                   (kargu-connected-providers)))
         (cfg (and (fboundp 'kargu--config-providers)
                   (mapcar #'car (kargu--config-providers))))
         (in-config (and cfg (cl-remove-if-not (lambda (p) (member p cfg)) all))))
    (or (and interactive-p in-config) all)))

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

(defvar kargu-selection-port #'kargu-selection--native-port
  "Function (SESSION DESIRED CALLBACK) committing DESIRED for SESSION.
It runs in the requesting owner buffer and delivers CALLBACK (SELECTION
FAILURE) once.  SELECTION is the native acknowledgement, never DESIRED
echoed by the editor.  The default is the Rust conversation; there is no
local fallback.")

(defun kargu-selection--native-port (session desired callback)
  "Commit DESIRED for SESSION through its Rust conversation; see CALLBACK."
  (require 'kargu/bridge/selection)
  (kargu-bridge-selection-commit session desired callback))

(defun kargu-selection--merge (before changes)
  "Return one selection value derived from BEFORE.
Only fields present in the CHANGES plist differ from BEFORE."
  (kargu-selection-create
   :provider (if (plist-member changes :provider) (plist-get changes :provider)
               (kargu-selection-provider-value before))
   :model (if (plist-member changes :model) (plist-get changes :model)
            (kargu-selection-model-value before))
   :effort (if (plist-member changes :effort) (plist-get changes :effort)
             (kargu-selection-effort-value before))))

(defun kargu-selection--deliver (callback selection failure)
  "Call CALLBACK with SELECTION or FAILURE, reporting an unobserved failure."
  (if callback
      (funcall callback selection failure)
    (when failure
      (message "Kargu: selection change failed (%s)"
               (or (and (hash-table-p failure)
                        (let ((data (gethash "data" failure)))
                          (and (hash-table-p data) (gethash "status" data))))
                   failure)))))

(defun kargu-selection--acknowledged (session item selection failure)
  "Adopt SESSION's native SELECTION for queued ITEM, or report FAILURE."
  (setf (kargu-session-selection-pending session) nil)
  (let ((origin (plist-get item :origin)) (callback (plist-get item :callback)))
    (if (or failure (not (kargu-selection-p selection)))
        (kargu-selection--deliver callback nil
                                  (or failure "Invalid native selection acknowledgement"))
      (let ((before (kargu-session-selection-value session)))
        (setf (kargu-session-selection-value session) selection)
        (if (buffer-live-p origin)
            (with-current-buffer origin
              (kargu-selection--notify session before selection))))
      (kargu-selection--deliver
       callback
       (and (buffer-live-p origin) (eq session (kargu-session-context origin))
            (eq selection (kargu-session-selection-value session))
            selection)
       nil)))
  (kargu-selection--pump session))

(defun kargu-selection--pump (session)
  "Issue SESSION's next queued intent from its latest committed value."
  (unless (kargu-session-selection-pending session)
    (when-let* ((item (pop (kargu-session-selection-queue session))))
      (let ((origin (plist-get item :origin)) (delivered nil))
        (if (not (buffer-live-p origin))
            (progn (kargu-selection--deliver (plist-get item :callback) nil "Selection owner closed")
                   (kargu-selection--pump session))
          (setf (kargu-session-selection-pending session) item)
          (condition-case err
              (with-current-buffer origin
                (funcall kargu-selection-port session
                         (kargu-selection--merge (kargu-session-selection-value session)
                                                 (plist-get item :changes))
                         (lambda (selection failure)
                           (unless delivered
                             (setq delivered t)
                             (kargu-selection--acknowledged session item selection failure)))))
            (error
             (unless delivered
               (setq delivered t)
               (kargu-selection--acknowledged session item nil (error-message-string err))))))))))

(cl-defun kargu-selection-update
    (&key (provider nil provider-p) (model nil model-p) (effort nil effort-p) session callback)
  "Request PROVIDER, MODEL and EFFORT together for SESSION's native commit.
Unspecified fields keep the value committed when the intent is issued.
Intents are validated, then issued one at a time; listeners see the entire
acknowledged selection, never half of a provider/model change.  CALLBACK
receives (SELECTION FAILURE) once.  Return the committed selection when the
port acknowledged before returning and it is still current, otherwise nil."
  (let* ((origin (current-buffer))
         (session (or session (kargu-session-context)))
         (changes (append (and provider-p (list :provider provider))
                          (and model-p (list :model model))
                          (and effort-p (list :effort effort))))
         result)
    (kargu-selection--merge (kargu-session-selection-value session) changes)
    (kargu-selection--admit-owner session)
    (when (>= (length (kargu-session-selection-queue session)) 16)
      (user-error "Kargu: too many pending selection changes"))
    (setf (kargu-session-selection-queue session)
          (nconc (kargu-session-selection-queue session)
                 (list (list :origin origin :changes changes
                             :callback (lambda (selection failure)
                                         (setq result selection)
                                         (kargu-selection--deliver callback selection failure))))))
    (kargu-selection--pump session)
    result))

(defun kargu-selection-seed (session selection origin callback)
  "Commit SELECTION for unpublished SESSION from ORIGIN's buffer.
This is for a prepared replacement that no view owns yet, so no owner
admission or notification occurs.  CALLBACK receives (SELECTION FAILURE)
with the native acknowledgement, which then becomes SESSION's value."
  (kargu-contract-assert #'kargu-session-p session)
  (kargu-contract-assert #'kargu-selection-p selection)
  (kargu-contract-assert #'buffer-live-p origin)
  (let (delivered)
    (with-current-buffer origin
      (funcall kargu-selection-port session selection
               (lambda (ack failure)
                 (unless delivered
                   (setq delivered t)
                   (when (and (null failure) (kargu-selection-p ack))
                     (setf (kargu-session-selection-value session) ack))
                   (funcall callback (and (null failure) ack)
                            (or failure (unless (kargu-selection-p ack)
                                          "Invalid native selection acknowledgement")))))))))

(defun kargu-selection-publish (session before)
  "Publish SESSION's already committed selection relative to BEFORE.
This is the notification half of a coordinated session/view transaction."
  (kargu-contract-assert #'kargu-session-p session)
  (kargu-contract-assert #'kargu-selection-p before)
  (when (eq session (kargu-session-context))
    (kargu-selection--notify session before (kargu-selection-context session))))

(cl-defun kargu-selection-reset (&optional session &key callback)
  "Request clearing SESSION's choices during an admitted reset.
SESSION defaults to the current owner; CALLBACK observes the native commit."
  (let ((session (or session (kargu-session-context))))
    (kargu-contract-assert #'kargu-session-p session)
    (kargu-selection-update :provider nil :model nil
                            :effort kargu-selection-default-effort
                            :session session :callback callback)))

(gv-define-setter kargu-selection-provider (value &optional session)
  `(kargu-selection-update :provider ,value :session ,session))
(gv-define-setter kargu-selection-model (value &optional session)
  `(kargu-selection-update :model ,value :session ,session))
(gv-define-setter kargu-selection-effort (value &optional session)
  `(kargu-selection-update :effort ,value :session ,session))

(provide 'kargu/selection)
;;; selection.el ends here
