;;; kargu/chat/session.el --- Persistent project-scoped chat sessions -*- lexical-binding: t; -*-

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
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/permission/guards)

(declare-function kargu-state-mode "kargu/state/selectors" ())
(declare-function kargu-set-mode "kargu/core" (mode))
(declare-function kargu--provider-name "kargu/api" ())
(declare-function kargu--model "kargu/api" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())
(declare-function kargu-chat-list-buffers "kargu/chat" ())

(defgroup kargu-session nil
  "Persistent project-scoped chat sessions for kargu."
  :group 'kargu
  :prefix "kargu-session-")

(defcustom kargu-sessions-directory
  (expand-file-name "sessions"
                    (or (and (getenv "XDG_DATA_HOME")
                             (not (string-empty-p (getenv "XDG_DATA_HOME")))
                             (expand-file-name "kargu" (getenv "XDG_DATA_HOME")))
                        (locate-user-emacs-file "kargu")))
  "Directory where chat sessions are stored across restarts."
  :type 'directory
  :group 'kargu-session)

(defcustom kargu-session-auto-save t
  "When non-nil, chat sessions are automatically saved after each turn."
  :type 'boolean
  :group 'kargu-session)

(defcustom kargu-session-auto-restore t
  "When non-nil, opening chat in a project restores its latest saved session."
  :type 'boolean
  :group 'kargu-session)

;;;; Buffer-local session state -------------------------------------------

(defvar-local kargu-chat--project-root nil
  "Canonical project root directory associated with this chat buffer.")

(defvar-local kargu-chat--session-id nil
  "Session identifier associated with this chat buffer.")

(defvar-local kargu-chat--session-title nil
  "Human-readable title of this chat session.")

(defvar-local kargu-chat--session-provider nil
  "Provider name associated with this chat session.")

(defvar-local kargu-chat--session-model nil
  "Model identifier associated with this chat session.")

(defvar-local kargu-chat--messages nil
  "Buffer-local snapshot of protocol messages for this session.")

;;;; Project paths & storage helpers --------------------------------------

(defun kargu-session--project-root (&optional buffer-or-dir)
  "Return canonical project root directory for BUFFER-OR-DIR."
  (let ((buf (and (bufferp buffer-or-dir) (buffer-live-p buffer-or-dir) buffer-or-dir)))
    (if (and buf (buffer-local-value 'kargu-chat--project-root buf))
        (buffer-local-value 'kargu-chat--project-root buf)
      (let ((dir (if (stringp buffer-or-dir)
                     buffer-or-dir
                   (and buf (buffer-local-value 'default-directory buf)))))
        (file-name-as-directory
         (file-truename
          (if dir
              (let ((default-directory dir))
                (kargu-permission-project-root))
            (kargu-permission-project-root))))))))

(defun kargu-session--project-key (root)
  "Return a deterministic, safe filesystem slug for project ROOT."
  (let* ((canonical (file-truename (directory-file-name root)))
         (name (file-name-nondirectory canonical))
         (clean-name (replace-regexp-in-string "[^a-zA-Z0-9._-]" "_" (if (string-empty-p name) "root" name)))
         (hash (substring (secure-hash 'sha1 canonical) 0 8)))
    (format "%s-%s" clean-name hash)))

(defun kargu-session--project-dir (&optional root)
  "Return directory path where sessions for project ROOT are stored.
Prefers existing `<root>/.kargu/sessions/' if present, otherwise
uses `<kargu-sessions-directory>/<project-key>/'."
  (let* ((proj-root (kargu-session--project-root root))
         (local-dir (expand-file-name ".kargu/sessions" proj-root)))
    (if (file-directory-p local-dir)
        (file-name-as-directory local-dir)
      (let ((central-dir (expand-file-name (kargu-session--project-key proj-root)
                                           kargu-sessions-directory)))
        (unless (file-directory-p central-dir)
          (condition-case nil
              (make-directory central-dir t)
            (error nil)))
        (file-name-as-directory central-dir)))))

(defun kargu-session--file-path (session-id &optional root)
  "Return absolute JSON file path for SESSION-ID in project ROOT."
  (expand-file-name (format "%s.json" session-id)
                    (kargu-session--project-dir root)))

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
                 (when (equal (kargu--aget m "role") "user")
                   (let ((c (kargu--aget m "content")))
                     (when (and (stringp c) (not (string-empty-p (string-trim c))))
                       (truncate-string-to-width
                        (replace-regexp-in-string "[\r\n\t]+" " " (string-trim c))
                        60)))))
               messages)
      fallback
      "New Session"))

(defun kargu-session-save (&optional buffer)
  "Save chat session from BUFFER (defaults to current buffer) to JSON.
Returns the file path written, or nil if no content to save."
  (let ((buf (or buffer (current-buffer))))
    (when (and (bufferp buf) (buffer-live-p buf))
      (with-current-buffer buf
        (let* ((root (kargu-session--project-root buf))
               (sid (or kargu-chat--session-id
                        (and (fboundp 'kargu-session-id) (kargu-session-id))
                        (format "kargu-%s" (format-time-string "%Y%m%d%H%M%S"))))
               (messages (or kargu-chat--messages
                             (and (boundp 'kargu--message-history) kargu--message-history)
                             nil))
               (transcript (kargu-session--extract-transcript buf))
               (title (or kargu-chat--session-title
                          (kargu-session--derive-title messages (buffer-name buf))))
               (mode-val (if (fboundp 'kargu-state-mode)
                             (kargu-state-mode)
                           'agent))
               (prov (or kargu-chat--session-provider
                         (and (boundp 'kargu--session-provider) kargu--session-provider)
                         (if (fboundp 'kargu--provider-name) (kargu--provider-name) "")))
               (mod (or kargu-chat--session-model
                        (and (boundp 'kargu--session-model) kargu--session-model)
                        (if (fboundp 'kargu--model) (kargu--model) "")))
               (usage (if (boundp 'kargu--session) kargu--session nil))
               (dir (kargu-session--project-dir root))
               (file (kargu-session--file-path sid root)))
          ;; Avoid creating files for completely empty untouched sessions
          (when (or (and messages (> (length messages) 0))
                    (> (length (string-trim transcript)) 30))
            (setq kargu-chat--session-id sid
                  kargu-chat--project-root root
                  kargu-chat--session-title title
                  kargu-chat--session-provider prov
                  kargu-chat--session-model mod
                  kargu-chat--messages messages)
            (let* ((data
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
                   (json-str (kargu--json-encode data)))
              (unless (file-directory-p dir)
                (make-directory dir t))
              (with-temp-file file
                (insert json-str))
              (kargu-log 'info "session saved: %s (%s)" sid file)
              file)))))))

(defun kargu-session-list (&optional root)
  "Return list of saved session metadata alists for project ROOT, newest first."
  (let* ((dir (kargu-session--project-dir root))
         (files (and (file-directory-p dir)
                     (directory-files dir t "\\.json$")))
         (sessions nil))
    (dolist (file files)
      (condition-case-unless-debug err
          (when (file-readable-p file)
            (let* ((content (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string)))
                   (decoded (kargu--json-decode-safe content)))
              (when (and decoded (kargu--aget decoded "id"))
                (push decoded sessions))))
        (error
         (kargu-log 'warn "failed to read session file %s: %s"
                    file (error-message-string err)))))
    (sort sessions
          (lambda (a b)
            (string> (or (kargu--aget a "updated_at") "")
                     (or (kargu--aget b "updated_at") ""))))))

;;;; Deserialization & Restoration ---------------------------------------

(defvar kargu-chat-buffer-name)
(declare-function kargu-chat-mode "kargu/chat" ())

(defun kargu-session-load (session-or-id &optional target-buffer root)
  "Restore SESSION-OR-ID into TARGET-BUFFER for project ROOT.
SESSION-OR-ID may be a session alist or a session id string.
Returns TARGET-BUFFER on success."
  (let* ((data (if (consp session-or-id)
                   session-or-id
                 (let ((f (kargu-session--file-path session-or-id root)))
                   (when (file-readable-p f)
                     (with-temp-buffer
                       (insert-file-contents f)
                       (kargu--json-decode-safe (buffer-string)))))))
         (buf (or target-buffer
                  (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*"))
                  (get-buffer-create (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*")))))
    (when data
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (sid (kargu--aget data "id"))
              (title (kargu--aget data "title"))
              (saved-root (kargu--aget data "project_root"))
              (raw-msgs (kargu--aget data "messages"))
              (transcript (or (kargu--aget data "transcript") ""))
              (mode-str (kargu--aget data "mode"))
              (updated-at (or (kargu--aget data "updated_at") "earlier")))
          (unless (derived-mode-p 'kargu-chat-mode)
            (if (fboundp 'kargu-chat-mode)
                (kargu-chat-mode)
              (text-mode)))
          ;; Erase buffer cleanly
          (delete-region (point-min) (point-max))
          ;; Restore message history
          (let ((msg-list (if (vectorp raw-msgs) (append raw-msgs nil) raw-msgs))
                (saved-prov (kargu--aget data "provider"))
                (saved-model (kargu--aget data "model")))
            (setq kargu-chat--session-id sid
                  kargu-chat--session-title title
                  kargu-chat--project-root (or saved-root (kargu-session--project-root root))
                  kargu-chat--messages msg-list)
            (setq-local kargu--session-id sid)
            (when (and (stringp saved-prov) (not (string-empty-p (string-trim saved-prov))))
              (setq kargu-chat--session-provider saved-prov)
              (when (boundp 'kargu--session-provider)
                (setq kargu--session-provider saved-prov)))
            (when (and (stringp saved-model) (not (string-empty-p (string-trim saved-model))))
              (setq kargu-chat--session-model saved-model)
              (when (boundp 'kargu--session-model)
                (setq kargu--session-model saved-model)))
            (when (boundp 'kargu--message-history)
              (setq kargu--message-history (copy-sequence msg-list))))
          ;; Restore session counters
          (when (boundp 'kargu--session)
            (setq kargu--session
                  (list :active nil
                        :id sid
                        :requests (or (kargu--aget data "requests") 0)
                        :tokens-in (or (kargu--aget data "tokens_in") 0)
                        :tokens-out (or (kargu--aget data "tokens_out") 0)
                        :last-prompt-tokens 0
                        :started (or (kargu--aget data "created_at") updated-at))))
          ;; Switch mode if saved
          (when (and mode-str (fboundp 'kargu-set-mode))
            (condition-case nil
                (kargu-set-mode (intern mode-str))
              (error nil)))
          ;; Insert transcript
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
                                            (length (or kargu-chat--messages '())))
                                    'face 'font-lock-comment-face
                                    'read-only t)))
            (insert (concat "kargu chat — type at the prompt; "
                            "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-b switch chat.\n\n")))
          ;; Ensure idle prompt
          (when (fboundp 'kargu-chat--ensure-idle-prompt)
            (kargu-chat--ensure-idle-prompt))
          (goto-char (point-max))
          (kargu-log 'info "restored session %s for project %s" sid saved-root)
          buf)))))

(defun kargu-session-delete (session-id &optional root)
  "Delete saved SESSION-ID from disk for project ROOT."
  (interactive
   (let* ((proj (kargu-session--project-root))
          (sessions (kargu-session-list proj))
          (choices (mapcar (lambda (s)
                             (cons (format "%s (%s - %s)"
                                           (or (kargu--aget s "title") "Untitled")
                                           (or (kargu--aget s "updated_at") "")
                                           (or (kargu--aget s "id") ""))
                                   (kargu--aget s "id")))
                           sessions))
          (choice (completing-read "Delete kargu session: " choices nil t)))
     (list (cdr (assoc choice choices)) proj)))
  (when (and (stringp session-id) (not (string-empty-p session-id)))
    (let ((file (kargu-session--file-path session-id root)))
      (when (file-exists-p file)
        (delete-file file)
        (message "kargu: deleted session %s" session-id)))))

(defun kargu-chat-sessions (&optional root)
  "Interactively switch to a saved chat session for project ROOT."
  (interactive)
  (let* ((proj-root (kargu-session--project-root root))
         (sessions (kargu-session-list proj-root)))
    (if (null sessions)
        (message "kargu: no saved sessions for %s" proj-root)
      (let* ((choices
              (mapcar
               (lambda (s)
                 (let* ((title (or (kargu--aget s "title") "Untitled"))
                        (time (or (kargu--aget s "updated_at") ""))
                        (mode (or (kargu--aget s "mode") "agent"))
                        (msgs (kargu--aget s "messages"))
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
            (message "kargu: loaded session '%s'" (kargu--aget selected "title"))))))))

(defun kargu-session-auto-save-all ()
  "Save all active kargu chat buffers to disk."
  (when kargu-session-auto-save
    (when (fboundp 'kargu-chat-list-buffers)
      (dolist (buf (kargu-chat-list-buffers))
        (when (buffer-live-p buf)
          (ignore-errors
            (kargu-session-save buf)))))))

(add-hook 'kill-emacs-hook #'kargu-session-auto-save-all)

(provide 'kargu/chat/session)

;;; kargu/chat/session.el ends here
