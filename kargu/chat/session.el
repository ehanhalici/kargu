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
(require 'kargu/chat/session/restore)

(declare-function kargu-state-mode "kargu/state/selectors" ())
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

(defun kargu-chat-session-id (&optional buffer)
  "Return the session identity belonging to BUFFER, defaulting to current."
  (buffer-local-value 'kargu-chat--session-id (or buffer (current-buffer))))

(defun kargu-chat--explicit-selection (value)
  "Return VALUE when it is a non-blank string, otherwise nil."
  (and (stringp value)
       (let ((s (string-trim value)))
         (unless (string-empty-p s) s))))

(defun kargu-chat-session-reset ()
  "Clear the current chat's session view after application reset completes."
  (when (derived-mode-p 'kargu-chat-mode)
    (setq kargu-chat--session-id nil)))

(defun kargu/chat/session-unload-function ()
  "Detach this adapter's reset notification before unloading it."
  (remove-hook 'kargu-session-reset-hook #'kargu-chat-session-reset)
  nil)

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
    (save-restriction
      (widen)
      (let ((end (if (and (boundp 'kargu-chat--output-marker)
                        (markerp kargu-chat--output-marker)
                        (eq (marker-buffer kargu-chat--output-marker) buf))
                   (marker-position kargu-chat--output-marker)
                 (point-max))))
      (if (> end (point-min))
          (buffer-substring-no-properties (point-min) end)
        "")))))

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

(cl-defun kargu-session--build-data
    (&key sid root title usage mode provider model effort transcript messages)
  "Build SID's record under ROOT with TITLE, USAGE, MODE and choices.
Store PROVIDER, MODEL, EFFORT, TRANSCRIPT and native MESSAGES."
  `(("schema_version" . ,kargu-session-schema-version)
    ("effort" . ,(kargu-session-encode-effort effort))
    ("id" . ,sid)
    ("project_root" . ,root)
    ("project_name" . ,(file-name-nondirectory (directory-file-name root)))
    ("title" . ,title)
    ("created_at" . ,(or (plist-get usage :started)
                         (format-time-string "%Y-%m-%d %H:%M:%S")))
    ("updated_at" . ,(format-time-string "%Y-%m-%d %H:%M:%S"))
    ("mode" . ,(symbol-name mode))
    ("provider" . ,(or provider ""))
    ("model" . ,(or model ""))
    ("requests" . ,(or (plist-get usage :requests) 0))
    ("tokens_in" . ,(or (plist-get usage :tokens-in) 0))
    ("tokens_out" . ,(or (plist-get usage :tokens-out) 0))
    ("transcript" . ,transcript)
    ("messages" . ,(vconcat (or messages '())))))

(defun kargu-session-save (&optional buffer)
  "Save chat session from BUFFER (defaults to current buffer) to JSON.
Returns the file path written, or nil if no content to save.
Read provider and model directly from BUFFER's owned selection.  A chat
that has not chosen either stores empty strings, not the config fallback."
  (let ((buf (or buffer (current-buffer))))
    (when (and (bufferp buf) (buffer-live-p buf))
      (with-current-buffer buf
        (let* ((root (kargu-session-project-root buf))
               (sid (or kargu-chat--session-id
                        (and (fboundp 'kargu-session-id) (kargu-session-id))
                        (format "kargu-%s" (format-time-string "%Y%m%d%H%M%S"))))
               (messages (kargu-history-snapshot))
               (transcript (kargu-session--extract-transcript buf))
               (title (or kargu-chat--session-title
                          (kargu-session--derive-title messages (buffer-name buf))))
               (mode-val (if (fboundp 'kargu-state-mode)
                             (kargu-state-mode)
                           'agent))
               (prov (or (kargu-selection-provider) ""))
               (mod (or (kargu-selection-model) ""))
               (usage (kargu-session-snapshot)))
          ;; Avoid creating files for completely empty untouched sessions
          (when (or (and messages (> (length messages) 0))
                    (> (length (string-trim transcript)) 30))
            (setq kargu-chat--session-id sid
                  kargu-chat--project-root root
                  kargu-chat--session-title title)
            (let ((data (kargu-session--build-data
                         :sid sid :root root :title title :usage usage :mode mode-val
                         :provider prov :model mod
                         :effort (kargu-selection-effort-value (kargu-selection-context))
                         :transcript transcript :messages messages)))
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

(cl-defun kargu-session-load (session-or-id &optional target-buffer root &key callback)
  "Restore SESSION-OR-ID into TARGET-BUFFER for project ROOT.
SESSION-OR-ID may be a session alist or a session id string.
ROOT is authoritative; metadata cannot switch projects.  An active run
must finish before loading another session.  CALLBACK receives (BUFFER ERROR).
Return the buffer on immediate success, or an owned task while preparing."
  (when callback (kargu-contract-assert #'functionp callback))
  (kargu-selection-require-idle)
  (let* ((root (kargu-session-project-root (or root target-buffer)))
         (raw (kargu-session--read-data session-or-id root))
         (data (and raw (kargu-session-validate raw)))
         (_validated (when data (kargu-session-storage-file (kargu-aget data "id") root)))
         (buf (and data (kargu-chat-restore-target root target-buffer))))
    (when data
      (kargu-session-restore :data data :target buf :root root :callback callback))))

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
          (when (and (derived-mode-p 'kargu-chat-mode)
                     (equal proj-root (kargu-session-project-root (current-buffer))))
            (kargu-session-save (current-buffer)))
          (kargu-session-load
           selected nil proj-root
           :callback (lambda (buffer error)
                       (if error (message "Kargu: %s" error)
                         (pop-to-buffer-same-window buffer)
                         (message "kargu: loaded session '%s'"
                                  (kargu-aget selected "title"))))))))))

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
