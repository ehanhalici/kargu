;;; restore.el --- Prepared session and transcript publication -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Decode before entry; prepare history, counters and the complete view away
;; from the target.  Publication checks its captured owner and draft revision.
;; Rollback covers local Emacs state, not arbitrary external mode-hook effects.

;;; Code:

(require 'kargu/core/session)
(require 'kargu/application/mode)
(require 'kargu/async)
(require 'kargu/json)
(require 'kargu/state/transitions)
(require 'kargu/history/store)
(require 'kargu/selection)
(require 'kargu/chat/session/schema)

(declare-function kargu-chat-mode "kargu/chat" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())
(declare-function kargu-session--render-restored-transcript "kargu/chat/session"
                  (transcript updated-at message-count))
(declare-function kargu-chat--explicit-selection "kargu/chat/session" (value))

(defvar kargu-chat--project-root)
(defvar kargu-chat--session-id)
(defvar kargu-chat--session-title)
(defvar kargu-chat--session-revision)
(defvar kargu-chat--output-marker)
(defvar kargu-chat--prompt-marker)

(cl-defstruct (kargu-session-restore-operation (:constructor kargu-session-restore--create))
  "Prepared replacement and its captured target revision."
  target owner selection mode-revision tick directory project data root
  prepared view task)

(cl-defstruct (kargu-session-view (:constructor kargu-session-view--create))
  "Target-local state needed if publication itself fails."
  text locals point minimum maximum modified undo mark mark-active markers)

(defun kargu-session-restore--owner (data)
  "Build an isolated session from validated DATA without publishing hooks."
  (let* ((tokens-in (gethash "tokens_in" data))
         (tokens-out (gethash "tokens_out" data))
         (tokens-unk (or (eq (gethash "tokens_unknown" data) t)
                         (and (null tokens-in) (null tokens-out))))
         (monetary-unk (not (eq (gethash "monetary_unknown" data :missing) :json-false)))
         (session
          (kargu-session-create
           :id-value (gethash "id" data)
           :mode-value (intern (gethash "mode" data "ask"))
           :usage-value (list :active nil
                              :requests (gethash "requests" data 0)
                              :requests-spent (gethash "requests" data 0)
                              :tokens-in (and (numberp tokens-in) tokens-in)
                              :tokens-out (and (numberp tokens-out) tokens-out)
                              :tokens-spent (gethash "tokens_spent" data
                                                     (if (and (numberp tokens-in) (numberp tokens-out))
                                                         (+ tokens-in tokens-out)
                                                       0))
                              :tokens-unknown (and tokens-unk t)
                              :monetary-spent (gethash "monetary_spent" data 0)
                              :monetary-reserved (gethash "monetary_reserved" data 0)
                              :monetary-unknown (and monetary-unk t)
                              :last-prompt-tokens (and (numberp tokens-in) tokens-in)
                              :started (gethash "created_at" data
                                                (gethash "updated_at" data "earlier"))))))
    (kargu-history-replace
     (mapcar #'kargu-json-to-record (append (gethash "messages" data) nil))
     (kargu-session-history-value session))
    session))

(defun kargu-session-restore--selection (data)
  "Return DATA's saved selection as an intent for the native conversation."
  (kargu-selection-create
   :provider (kargu-chat--explicit-selection (gethash "provider" data))
   :model (kargu-chat--explicit-selection (gethash "model" data))
   :effort (kargu-session-decode-effort (gethash "effort" data))))

(defun kargu-session-restore--current-p (operation)
  "Return non-nil when OPERATION still owns the target and its draft."
  (let ((target (kargu-session-restore-operation-target operation))
        (owner (kargu-session-restore-operation-owner operation)))
    (and (buffer-live-p target)
         (eq owner (kargu-session-context target))
         (eq (kargu-session-restore-operation-selection operation)
             (kargu-session-selection-value owner))
         (= (kargu-session-restore-operation-mode-revision operation)
            (kargu-session-mode-revision owner))
         (with-current-buffer target
           (and (= (kargu-session-restore-operation-tick operation) (buffer-modified-tick))
                (equal default-directory (kargu-session-restore-operation-directory operation))
                (equal kargu-chat--project-root
                       (kargu-session-restore-operation-project operation)))))))

(defun kargu-session-restore--render (operation)
  "Render OPERATION's isolated replacement in its offscreen view."
  (with-current-buffer (kargu-session-restore-operation-view operation)
    (let* ((data (kargu-session-restore-operation-data operation))
           (session (kargu-session-restore-operation-prepared operation)))
      ;; Do not run chat-mode hooks, discovery, autosave or optional UI setup.
      (setq major-mode 'kargu-chat-mode
            default-directory (kargu-session-restore-operation-root operation))
      (setq-local kargu-session--context session
                  kargu--session-id (kargu-session-id session))
      (kargu-session--render-restored-transcript
       (gethash "transcript" data "") (gethash "updated_at" data "earlier")
       (length (gethash "messages" data)))
      (kargu-chat--ensure-idle-prompt))))

(defun kargu-session-view-capture ()
  "Capture complete local text, markers and editing state without narrowing."
  (let ((minimum (point-min)) (maximum (point-max)) (position (point)))
    (save-restriction
      (widen)
      (kargu-session-view--create
       :text (buffer-string) :locals (buffer-local-variables)
       :point position :minimum minimum :maximum maximum
       :modified (buffer-modified-p) :undo buffer-undo-list
       :mark (mark t) :mark-active mark-active
       :markers (delq nil (mapcar
                           (lambda (marker)
                             (when (and (markerp marker) (marker-position marker))
                               (list marker (marker-position marker)
                                     (marker-insertion-type marker))))
                           (list kargu-chat--output-marker kargu-chat--prompt-marker)))))))

(defun kargu-session-view-restore (view)
  "Restore local VIEW after a failed, non-yielding publication."
  (let ((inhibit-read-only t) (inhibit-modification-hooks t))
    (widen)
    (erase-buffer)
    (insert (kargu-session-view-text view))
    (dolist (entry (buffer-local-variables))
      (let ((key (if (consp entry) (car entry) entry)))
        (unless (assq key (kargu-session-view-locals view)) (kill-local-variable key))))
    (dolist (entry (kargu-session-view-locals view))
      (when (and (consp entry)
                 (not (and (boundp (car entry)) (eq (symbol-value (car entry)) (cdr entry)))))
        (set (make-local-variable (car entry)) (cdr entry))))
    (dolist (entry (kargu-session-view-markers view))
      (set-marker (car entry) (cadr entry) (current-buffer))
      (set-marker-insertion-type (car entry) (caddr entry)))
    (set-marker (mark-marker) (kargu-session-view-mark view))
    (setq mark-active (kargu-session-view-mark-active view)
          buffer-undo-list (kargu-session-view-undo view))
    (set-buffer-modified-p (kargu-session-view-modified view))
    (narrow-to-region (kargu-session-view-minimum view) (kargu-session-view-maximum view))
    (goto-char (kargu-session-view-point view))))

(defun kargu-session-restore--install (operation)
  "Install OPERATION's prepared owner and rendered view without notifications."
  (let* ((data (kargu-session-restore-operation-data operation))
         (session (kargu-session-restore-operation-prepared operation))
         (view (kargu-session-restore-operation-view operation))
         (inhibit-read-only t) (inhibit-modification-hooks t))
    (unless (derived-mode-p 'kargu-chat-mode) (kargu-chat-mode))
    (kargu-selection-require-idle)
    (widen)
    (erase-buffer)
    (insert-buffer-substring view)
    (setq-local kargu-session--context session kargu--session-id (kargu-session-id session)
                kargu-chat--session-id (kargu-session-id session)
                kargu-chat--session-title (gethash "title" data)
                kargu-chat--session-revision (let ((revision (gethash "revision" data)))
                                               (if (natnump revision) revision 0))
                kargu-chat--project-root (kargu-session-restore-operation-root operation)
                default-directory (kargu-session-restore-operation-root operation))
    (dolist (field '(kargu-chat--output-marker kargu-chat--prompt-marker))
      (let ((marker (buffer-local-value field view)))
        (set (make-local-variable field)
             (and (markerp marker)
                  (copy-marker (marker-position marker) (marker-insertion-type marker))))))
    (set-buffer-modified-p nil)
    (setq buffer-undo-list nil)
    (goto-char (point-max))))

(defun kargu-session-restore--publish (operation)
  "Commit OPERATION's whole view and session, then notify optional observers."
  (unless (kargu-session-restore--current-p operation)
    (user-error "Kargu: restore target changed; its draft was retained"))
  (kargu-selection-require-idle)
  (let ((before (kargu-session-view-capture))
        (session (kargu-session-restore-operation-prepared operation)))
    (condition-case err
        (kargu-session-restore--install operation)
      (error
       (kargu-session-view-restore before)
       (signal (car err) (cdr err))))
    (kargu-selection-publish session (kargu-session-restore-operation-selection operation))
    (when (eq session (kargu-session-context))
      (kargu-state-notify :mode (kargu-session-mode-value session)))
    (current-buffer)))

(defun kargu-session-restore--ready (operation mode error)
  "Finish OPERATION after its MODE preparation, or deliver ERROR unchanged."
  (condition-case failure
      (if error
          (kargu-async-finish (kargu-session-restore-operation-task operation) nil error)
        (kargu-state-check-mode mode)
        (kargu-session-restore--seed operation))
    (error (kargu-async-finish (kargu-session-restore-operation-task operation)
                               nil (error-message-string failure)))))

(defun kargu-session-restore--seed (operation)
  "Commit OPERATION's saved selection natively, then render and publish."
  (let ((task (kargu-session-restore-operation-task operation))
        (prepared (kargu-session-restore-operation-prepared operation)))
    (kargu-selection-seed
     prepared
     (kargu-session-restore--selection (kargu-session-restore-operation-data operation))
     (kargu-session-restore-operation-target operation)
     (lambda (_selection failure)
       (condition-case err
           (cond
            ((not (kargu-async-pending-p task)))
            (failure
             (run-hook-with-args 'kargu-session-before-replace-hook prepared)
             (kargu-async-finish task nil (format "Restored selection was refused: %s"
                                                  (kargu-session-restore--status failure))))
            (t
             (kargu-session-restore--render operation)
             (kargu-async-finish task (kargu-session-restore--publish operation))))
         (error (kargu-async-finish task nil (error-message-string err))))))))

(defun kargu-session-restore--status (failure)
  "Return FAILURE's native status or text for a restore message."
  (or (and (hash-table-p failure)
           (let ((data (gethash "data" failure)))
             (and (hash-table-p data) (gethash "status" data))))
      failure))

(cl-defun kargu-session-restore (&key data target root callback)
  "Prepare validated DATA for TARGET under ROOT, then publish atomically.
CALLBACK receives (BUFFER ERROR); without it immediate failures signal."
  (with-current-buffer target
    (let* ((owner (kargu-session-context)) result failure
           (operation
            (kargu-session-restore--create
             :target target :owner owner :selection (kargu-session-selection-value owner)
             :mode-revision (kargu-session-mode-revision owner) :tick (buffer-modified-tick)
             :directory default-directory :project kargu-chat--project-root :data data
             :root root :prepared (kargu-session-restore--owner data)
             :view (generate-new-buffer " *kargu-session-restore*"))))
      (setf (kargu-session-restore-operation-task operation)
            (kargu-async-start
             (lambda (buffer error)
               (setq result buffer failure error)
               (when callback (funcall callback buffer error)))))
      (kargu-async-add-cleanup
       (kargu-session-restore-operation-task operation)
       (lambda () (when (buffer-live-p (kargu-session-restore-operation-view operation))
                    (kill-buffer (kargu-session-restore-operation-view operation)))))
      (let ((kargu-async--current-task (kargu-session-restore-operation-task operation)))
        (condition-case err
            (kargu-mode-prepare
             (kargu-session-mode-value (kargu-session-restore-operation-prepared operation))
             (lambda (mode error) (kargu-session-restore--ready operation mode error)))
          (error (kargu-async-finish (kargu-session-restore-operation-task operation)
                                     nil (error-message-string err)))))
      (when (and failure (null callback)) (user-error "%s" failure))
      (or result (kargu-session-restore-operation-task operation)))))

(provide 'kargu/chat/session/restore)
;;; restore.el ends here
