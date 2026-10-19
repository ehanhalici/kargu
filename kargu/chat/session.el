;;; session.el --- Persistent project-scoped chat sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Project-scoped persistent chat sessions across Emacs and Kargu restarts.
;; Saves conversation history, metadata, token usage, and transcripts as JSON.
;; Automatically restores the latest chat session when reopening a project.
;; Public: `kargu-session-save', `kargu-session-load', `kargu-session-list',
;; `kargu-session-delete', `kargu-chat-sessions', `kargu-session-auto-save-all'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/permission/guards)
(require 'kargu/chat/routing)
(require 'kargu/chat/session/storage)
(require 'kargu/chat/session/validate)

(declare-function kargu-state-mode "kargu/state/selectors" ())
(declare-function kargu-state-set-provider "kargu/state/transitions" (provider))
(declare-function kargu-state-set-model "kargu/state/transitions" (model))
(declare-function kargu-state-clear-model "kargu/state/transitions" ())
(declare-function kargu-set-mode "kargu/core" (mode))
(declare-function kargu--provider-name "kargu/config/key" ())
(declare-function kargu--model "kargu/config/key" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())
(declare-function kargu-chat-list-buffers "kargu/chat" ())
(declare-function kargu-loop-running-p "kargu/loop" ())

(defcustom kargu-session-auto-save t
  "When non-nil, chat sessions are automatically saved after each turn."
  :type 'boolean
  :group 'kargu-session)

(defcustom kargu-session-auto-restore t
  "When non-nil, opening chat in a project restores its latest saved session."
  :type 'boolean
  :group 'kargu-session)

;;;; Buffer-local session state -------------------------------------------

(defvar-local kargu-chat--session-id nil
  "Session identifier associated with this chat buffer.")

(defvar-local kargu-chat--session-title nil
  "Human-readable title of this chat session.")

(defvar-local kargu-chat--session-provider nil
  "Provider name associated with this chat session.")

(defvar-local kargu-chat--session-model nil
  "Model identifier associated with this chat session.")

(defun kargu-chat-session-id (&optional buffer)
  "Return the session identity belonging to BUFFER, defaulting to current."
  (buffer-local-value 'kargu-chat--session-id (or buffer (current-buffer))))

(defun kargu-chat--explicit-selection (value)
  "Return VALUE when it is a non-blank string, otherwise nil."
  (and (stringp value)
       (let ((s (string-trim value)))
         (unless (string-empty-p s) s))))

(defun kargu-chat-note-selection (&optional buffer)
  "Remember the explicit provider and model on chat BUFFER.
Only `kargu--session-provider' and `kargu--session-model' are copied.
Config fallbacks are not.  A nil live value clears that buffer-local slot.
The session file reads this buffer-local copy when the chat closes."
  (let ((buf (or buffer (current-buffer)))
        (prov (and (boundp 'kargu--session-provider)
                   (kargu-chat--explicit-selection kargu--session-provider)))
        (mod (and (boundp 'kargu--session-model)
                  (kargu-chat--explicit-selection kargu--session-model))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'kargu-chat-mode)
          (setq kargu-chat--session-provider prov
                kargu-chat--session-model mod))))))

(defun kargu-chat--apply-saved-selection (provider model)
  "Make PROVIDER and MODEL the live selection.
A blank value clears that part of the live selection."
  (let ((prov (kargu-chat--explicit-selection provider))
        (mod (kargu-chat--explicit-selection model)))
    (setq kargu--session-provider prov
          kargu--session-model mod)
    (if prov
        (when (fboundp 'kargu-state-set-provider)
          (kargu-state-set-provider (intern prov)))
      (when (fboundp 'kargu-state-set-provider)
        (kargu-state-set-provider nil)))
    (if mod
        (when (fboundp 'kargu-state-set-model)
          (kargu-state-set-model mod))
      (when (fboundp 'kargu-state-clear-model)
        (kargu-state-clear-model)))))

(defun kargu-chat-activate-selection (&optional buffer)
  "Apply BUFFER's saved provider and model to the live selection."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'kargu-chat-mode)
          (kargu-chat--apply-saved-selection
           kargu-chat--session-provider
           kargu-chat--session-model))))))

(defvar-local kargu-chat--messages nil
  "Buffer-local snapshot of protocol messages for this session.")

;;;; Project paths & storage helpers --------------------------------------

(defun kargu-session-project-root (&optional buffer-or-dir)
  "Return the canonical project root for BUFFER-OR-DIR.
An explicit directory or a buffer's saved project root takes precedence
over the current workspace."
  (let* ((buffer (and (buffer-live-p buffer-or-dir) buffer-or-dir))
         (root (cond
                ((stringp buffer-or-dir) buffer-or-dir)
                ((and buffer
                      (buffer-local-value 'kargu-chat--project-root buffer)))
                (t (kargu-permission-project-root buffer)))))
    (file-name-as-directory (file-truename (expand-file-name root)))))

;;;; Serialization & Storage ---------------------------------------------

(defvar kargu-chat--output-marker)

(defun kargu-session--extract-transcript (buf)
  "Extract the read-only transcript text from BUF up to the output marker."
  (with-current-buffer buf
    (let ((end (if (and (boundp 'kargu-chat--output-marker)
                        (markerp kargu-chat--output-marker)
                        (eq (marker-buffer kargu-chat--output-marker) buf))
                   (marker-position kargu-chat--output-marker)
                 (point-max))))
      (if (> end (point-min))
          (buffer-substring-no-properties (point-min) end)
        ""))))

(defun kargu-session--derive-title (messages fallback)
  "Derive a short descriptive session title from MESSAGES or FALLBACK."
  (or (cl-some (lambda (m)
                 (when (equal (kargu-aget m "role") "user")
                   (let ((c (kargu-aget m "content")))
                     (when (and (stringp c) (not (string-empty-p (string-trim c))))
                       (truncate-string-to-width
                        (replace-regexp-in-string "[\r\n\t]+" " " (string-trim c))
                        60)))))
               messages)
      fallback
      "New Session"))

(defun kargu-session--build-data (sid root title usage mode-val prov mod transcript messages)
  "Build session data for SID under ROOT, with TITLE and USAGE.
Store MODE-VAL, provider PROV, model MOD, TRANSCRIPT and MESSAGES."
  `(("id" . ,sid)
    ("project_root" . ,root)
    ("project_name" . ,(file-name-nondirectory (directory-file-name root)))
    ("title" . ,title)
    ("created_at" . ,(or (plist-get usage :started)
                         (format-time-string "%Y-%m-%d %H:%M:%S")))
    ("updated_at" . ,(format-time-string "%Y-%m-%d %H:%M:%S"))
    ("mode" . ,(symbol-name mode-val))
    ("provider" . ,(or prov ""))
    ("model" . ,(or mod ""))
    ("requests" . ,(or (plist-get usage :requests) 0))
    ("tokens_in" . ,(or (plist-get usage :tokens-in) 0))
    ("tokens_out" . ,(or (plist-get usage :tokens-out) 0))
    ("transcript" . ,transcript)
    ("messages" . ,(vconcat (or messages '())))))

(defun kargu-session--messages-for-save ()
  "Messages to persist from the current buffer.
Live history wins when this buffer is the active session, so a
snapshot taken on the first save cannot freeze later turns.
Another buffer keeps its own snapshot."
  (let ((live (and (boundp 'kargu--message-history) kargu--message-history))
        (same (or (null kargu-chat--session-id)
                  (and (boundp 'kargu--session-id)
                       (equal kargu-chat--session-id kargu--session-id)))))
    (cond
     ((and same live) live)
     (kargu-chat--messages kargu-chat--messages)
     (t live))))

(defun kargu-session-save (&optional buffer)
  "Save chat session from BUFFER (defaults to current buffer) to JSON.
Returns the file path written, or nil if no content to save.
Saving the current chat first copies the explicit live provider and
model onto that buffer.  A chat that has not chosen either stores
empty strings, not the config fallback."
  (let ((buf (or buffer (current-buffer))))
    (when (and (bufferp buf) (buffer-live-p buf) (eq buf (current-buffer)))
      (kargu-chat-note-selection buf))
    (when (and (bufferp buf) (buffer-live-p buf))
      (with-current-buffer buf
        (let* ((root (kargu-session-project-root buf))
               (sid (or kargu-chat--session-id
                        (and (fboundp 'kargu-session-id) (kargu-session-id))
                        (format "kargu-%s" (format-time-string "%Y%m%d%H%M%S"))))
               (messages (kargu-session--messages-for-save))
               (transcript (kargu-session--extract-transcript buf))
               (title (or kargu-chat--session-title
                          (kargu-session--derive-title messages (buffer-name buf))))
               (mode-val (if (fboundp 'kargu-state-mode)
                             (kargu-state-mode)
                           'agent))
               (prov (or (kargu-chat--explicit-selection kargu-chat--session-provider) ""))
               (mod (or (kargu-chat--explicit-selection kargu-chat--session-model) ""))
               (usage (if (boundp 'kargu--session) kargu--session nil)))
          ;; Avoid creating files for completely empty untouched sessions
          (when (or (and messages (> (length messages) 0))
                    (> (length (string-trim transcript)) 30))
            (setq kargu-chat--session-id sid
                  kargu-chat--project-root root
                  kargu-chat--session-title title
                  kargu-chat--session-provider prov
                  kargu-chat--session-model mod
                  kargu-chat--messages messages)
            (let ((data (kargu-session--build-data
                         sid root title usage mode-val prov mod transcript messages)))
              (prog1 (kargu-session-storage-write sid root data)
                (kargu-log 'info "session saved: %s" sid)))))))))

(defun kargu-session-list (&optional root)
  "Return list of saved session metadata alists for project ROOT, newest first."
  (let* ((root (kargu-session-project-root root))
         (dir (kargu-session-storage-directory root))
         (files (and (file-directory-p dir)
                     (directory-files dir t "\\.json$")))
         (sessions nil))
    (dolist (file files)
      (condition-case-unless-debug err
          (when (and (file-readable-p file)
                     (kargu-permission-within-project-p file dir))
            (let ((decoded (kargu-session-storage-read (file-name-base file) root)))
              (when (and decoded (kargu-aget decoded "id"))
                (push decoded sessions))))
        (error
         (kargu-log 'warn "failed to read session file %s: %s"
                    file (error-message-string err)))))
    (sort sessions
          (lambda (a b)
            (string> (or (kargu-aget a "updated_at") "")
                     (or (kargu-aget b "updated_at") ""))))))

;;;; Deserialization & Restoration ---------------------------------------

(defvar kargu-chat-buffer-name)
(declare-function kargu-chat-mode "kargu/chat" ())

(defun kargu-session--restore-variables (data root)
  "Restore buffer-local chat session variables from DATA for project ROOT."
  (let* ((sid (kargu-aget data "id"))
         (title (kargu-aget data "title"))
         (raw-msgs (kargu-aget data "messages"))
         (msg-list (mapcar #'kargu-json-to-record (kargu-seq-to-list raw-msgs)))
         (saved-prov (kargu-aget data "provider"))
         (saved-model (kargu-aget data "model")))
    (setq kargu-chat--session-id sid
          kargu-chat--session-title title
          kargu-chat--project-root (kargu-session-project-root root)
          kargu-chat--messages msg-list)
    (setq-local kargu--session-id sid)
    (setq kargu-chat--session-provider (kargu-chat--explicit-selection saved-prov)
          kargu-chat--session-model (kargu-chat--explicit-selection saved-model))
    (kargu-chat--apply-saved-selection saved-prov saved-model)
    (when (boundp 'kargu--message-history)
      (setq kargu--message-history (copy-sequence msg-list)))))

(defun kargu-session--restore-counters (data updated-at)
  "Restore global session counters from DATA, fallback to UPDATED-AT."
  (when (boundp 'kargu--session)
    (setq kargu--session
          (list :active nil
                :id (kargu-aget data "id")
                :requests (or (kargu-aget data "requests") 0)
                :tokens-in (or (kargu-aget data "tokens_in") 0)
                :tokens-out (or (kargu-aget data "tokens_out") 0)
                :last-prompt-tokens 0
                :started (or (kargu-aget data "created_at") updated-at)))))

(defun kargu-session--render-restored-transcript (transcript updated-at message-count)
  "Render TRANSCRIPT or banner into current buffer.
Uses UPDATED-AT and MESSAGE-COUNT for status banner."
  (if (and transcript (not (string-empty-p transcript)))
      (progn
        (insert (propertize transcript
                            'read-only t
                            'front-sticky t
                            'rear-nonsticky '(read-only face front-sticky)))
        (unless (eq (char-before) ?\n)
          (insert "\n"))
        (insert (propertize (format "— restored session from %s (%d messages) —\n\n"
                                    updated-at
                                    message-count)
                            'face 'font-lock-comment-face
                            'read-only t)))
    (insert (concat "kargu chat — type at the prompt; "
                    "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-b switch chat.\n\n"))))

(defun kargu-session--read-data (session-or-id root)
  "Read SESSION-OR-ID in project ROOT, or return the supplied session data."
  (if (or (consp session-or-id) (hash-table-p session-or-id))
      session-or-id
    (let ((data (kargu-session-storage-read session-or-id root)))
      (when (and data (not (equal (kargu-aget data "id") session-or-id)))
        (user-error "Kargu: session ID does not match its filename"))
      data)))

(defun kargu-session-load (session-or-id &optional target-buffer root)
  "Restore SESSION-OR-ID into TARGET-BUFFER for project ROOT.
SESSION-OR-ID may be a session alist or a session id string.
ROOT is authoritative; metadata cannot switch projects.  An active run
must finish before loading another session.  Return TARGET-BUFFER on success."
  (when (kargu-loop-running-p)
    (user-error "Kargu: stop the active run before loading another session"))
  (let* ((root (kargu-session-project-root (or root target-buffer)))
         (raw (kargu-session--read-data session-or-id root))
         (data (and raw (kargu-session-validate raw)))
         (_validated (when data (kargu-session-storage-file (kargu-aget data "id") root)))
         (buf (or target-buffer
                  (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*"))
                  (get-buffer-create (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*")))))
    (when data
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (sid (kargu-aget data "id"))
              (transcript (or (kargu-aget data "transcript") ""))
              (mode-str (kargu-aget data "mode"))
              (updated-at (or (kargu-aget data "updated_at") "earlier")))
          (unless (derived-mode-p 'kargu-chat-mode)
            (if (fboundp 'kargu-chat-mode)
                (kargu-chat-mode)
              (text-mode)))
          ;; Erase buffer cleanly
          (delete-region (point-min) (point-max))
          ;; Restore message history and local variables
          (kargu-session--restore-variables data root)
          ;; Restore session counters
          (kargu-session--restore-counters data updated-at)
          ;; Switch mode if saved
          (when (and mode-str (fboundp 'kargu-set-mode))
            (condition-case nil
                (kargu-set-mode (intern mode-str))
              (error nil)))
          ;; Insert transcript
          (kargu-session--render-restored-transcript
           transcript updated-at (length (or kargu-chat--messages '())))
          ;; Ensure idle prompt
          (when (fboundp 'kargu-chat--ensure-idle-prompt)
            (kargu-chat--ensure-idle-prompt))
          (goto-char (point-max))
          (kargu-log 'info "restored session %s for project %s" sid root)
          buf)))))

(defun kargu-session-delete (session-id &optional root)
  "Delete saved SESSION-ID from disk for project ROOT."
  (interactive
   (let* ((proj (kargu-session-project-root))
          (sessions (kargu-session-list proj))
          (choices (mapcar (lambda (s)
                             (cons (format "%s (%s - %s)"
                                           (or (kargu-aget s "title") "Untitled")
                                           (or (kargu-aget s "updated_at") "")
                                           (or (kargu-aget s "id") ""))
                                   (kargu-aget s "id")))
                           sessions))
          (choice (completing-read "Delete kargu session: " choices nil t)))
     (list (cdr (assoc choice choices)) proj)))
  (when (and (stringp session-id) (not (string-empty-p session-id)))
    (let ((file (kargu-session-storage-file session-id (kargu-session-project-root root))))
      (when (file-exists-p file)
        (delete-file file)
        (message "kargu: deleted session %s" session-id)))))

(defun kargu-chat-sessions (&optional root)
  "Interactively switch to a saved chat session for project ROOT."
  (interactive)
  (let* ((proj-root (kargu-session-project-root root))
         (sessions (kargu-session-list proj-root)))
    (if (null sessions)
        (message "kargu: no saved sessions for %s" proj-root)
      (let* ((choices
              (mapcar
               (lambda (s)
                 (let* ((title (or (kargu-aget s "title") "Untitled"))
                        (time (or (kargu-aget s "updated_at") ""))
                        (mode (or (kargu-aget s "mode") "agent"))
                        (msgs (kargu-aget s "messages"))
                        (msg-count (if (vectorp msgs) (length msgs) (length (or msgs '()))))
                        (label (format "[%s] (%s, %d msgs) %s"
                                       time mode msg-count title)))
                   (cons label s)))
               sessions))
             (choice (completing-read (format "Select session for %s: "
                                              (file-name-nondirectory (directory-file-name proj-root)))
                                      choices nil t))
             (selected (cdr (assoc choice choices))))
        (when selected
          ;; Save current buffer before loading another session
          (when (derived-mode-p 'kargu-chat-mode)
            (kargu-session-save (current-buffer)))
          (let ((buf (or (and (derived-mode-p 'kargu-chat-mode) (current-buffer))
                         (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*"))
                         (get-buffer-create (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*")))))
            (kargu-session-load selected buf proj-root)
            (pop-to-buffer-same-window buf)
            (message "kargu: loaded session '%s'" (kargu-aget selected "title"))))))))

(defun kargu-session-auto-save-all ()
  "Save all active kargu chat buffers to disk."
  (when kargu-session-auto-save
    (when (fboundp 'kargu-chat-list-buffers)
      (dolist (buf (kargu-chat-list-buffers))
        (when (buffer-live-p buf)
          (ignore-errors
            (kargu-session-save buf)))))))

(defun kargu-session-import-local (session-id &optional root)
  "Copy local SESSION-ID from ROOT to central storage without removing it.
Existing central records are never overwritten.  ROOT defaults to the
current chat's project, not any project named by session metadata."
  (interactive
   (let* ((root (kargu-session-project-root))
          (ids (kargu-session-storage-local-ids root)))
     (unless ids (user-error "Kargu: no safe local session files found"))
     (list (completing-read "Import local session: " ids nil t) root)))
  (let ((target (kargu-session-storage-import-local
                 session-id (kargu-session-project-root root))))
    (message "Kargu: imported %s; the local source was retained" session-id)
    target))

(add-hook 'kill-emacs-hook #'kargu-session-auto-save-all)

(provide 'kargu/chat/session)

;;; session.el ends here
